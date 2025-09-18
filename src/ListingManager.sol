// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { ERC721 } from "@solmate/src/tokens/ERC721.sol";
import { LibClone } from "@solady/utils/LibClone.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Market } from "src/libraries/Market.sol";
import { Error } from "src/libraries/Error.sol";
import { LiquidityHelper } from "src/libraries/LiquidityHelper.sol";
import { BalanceDeltaSettler } from "src/libraries/BalanceDeltaSettler.sol";
import { TickHelper } from "src/libraries/TickHelper.sol";
import { BaseToken } from "src/template/BaseToken.sol";
import { IListingManager } from "src/interfaces/IListingManager.sol";
import { IMarketManager } from "src/interfaces/IMarketManager.sol";
import { ILiquidityManager } from "src/interfaces/ILiquidityManager.sol";
import { Types } from "src/Types.sol";
import { TokenHelper } from "src/libraries/TokenHelper.sol";

contract ListingManager is ERC721, IListingManager, TokenHelper {
    using Market for Types.ListingRequest;
    using Market for Types.NewTokenSchema;
    using Market for PoolKey;
    using Market for Currency;
    using CurrencyLibrary for Currency;
    using CurrencyLibraryExt for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickHelper for int24;
    using BalanceDeltaSettler for Currency;
    using TickHelper for int24[3];
    using TickMath for int24;

    uint256 public currentTokenId = 1;
    IBase public base;
    Types.ListingManagerConfig public config;
    Types.NewTokenSchema public newTokenSchema;

    mapping(Currency baseToken => Types.Market market) internal markets;
    mapping(uint256 tokenId => string tokenURI) internal tokenURIs;
    mapping(Currency baseToken => PoolKey poolKey) public poolKeys;
    mapping(Currency baseToken => Types.LiquidityPositions[2] liquidityPositions) public preMarketPositions;

    event NewBaseToken(Currency baseToken);
    event PremarketCreated(
        PoolKey poolKey, Types.ListingRequest params, Types.Market market, string name, string symbol
    );
    event PremarketEnded(Types.Market market, ModifyLiquidityParams modifyLiquidityParams);
    event Purchase(
        address indexed buyer, Types.Market market, uint256 azUsdAmount, uint256 tokensOut, uint256 feeAmount
    );
    event ListingManagerConfigUpdated(Types.ListingManagerConfig config);
    event NewTokenSchemaUpdated(Types.NewTokenSchema newTokenSchema);

    receive() external payable { }

    modifier onlyMarketManager() {
        if (msg.sender != address(base.marketManager())) {
            revert Error.CallerIsNotMarketManager();
        }
        _;
    }

    constructor(
        IBase _base,
        string memory _nativeTokenName,
        string memory _nativeTokenSymbol,
        Types.ListingManagerConfig memory _config,
        Types.NewTokenSchema memory _newTokenSchema
    ) ERC721("AZEx Markets", "Market") TokenHelper(_nativeTokenName, _nativeTokenSymbol) {
        base = _base;
        config = _config;
        newTokenSchema = _newTokenSchema;
        emit ListingManagerConfigUpdated(config);
        emit NewTokenSchemaUpdated(newTokenSchema);
    }

    function list(
        Types.ListingRequest memory _params
    ) external payable returns (Currency baseToken_) {
        string memory name = _params.name;
        string memory symbol = _params.symbol;
        bool isNewToken = _params.baseToken == Types.NEW_TOKEN_FLAG;
        uint256 listingFeeAmount;

        baseToken_ = _params.baseToken;
        _params.validateListing(config, newTokenSchema, isNewToken);
        if (isNewToken) {
            address baseTokenAddress = LibClone.clone(base.baseTokenImpl());
            BaseToken(baseTokenAddress).initialize(name, symbol, address(this), newTokenSchema.totalSupply);
            baseToken_ = Currency.wrap(baseTokenAddress);
            listingFeeAmount = config.newTokenListingFee;
            emit NewBaseToken(baseToken_);
        } else {
            _params.initialLiquidityBurned = false;
            if (isMarketExist(baseToken_)) {
                revert Error.MarketAlreadyExists(baseToken_);
            }
            if (!baseToken_.isAddressZero()) {
                baseToken_.transferFrom(msg.sender, address(this), _params.baseTokenAmount);
            }
            (name, symbol,) = getCurrencyMeta(baseToken_);
            listingFeeAmount = config.existingTokenListingFee;
        }
        Currency azUsd = base.currencyAzUsd();
        base.hayek().takeToken(azUsd, msg.sender, address(this), listingFeeAmount);
        currentTokenId = ++currentTokenId;

        _mint(msg.sender, currentTokenId);

        bool azUsdIsZero = Currency.unwrap(azUsd) < Currency.unwrap(baseToken_);

        if (isNewToken) {
            _params.ticks = _params.ticks.convertTicks(azUsdIsZero);
        }
        markets[baseToken_] = Types.Market({
            tokenId: currentTokenId,
            creator: msg.sender,
            baseToken: baseToken_,
            startsAt: block.timestamp,
            endsAt: isNewToken ? block.timestamp + config.premarketWindow : block.timestamp,
            supply: _params.baseTokenAmount,
            ticks: _params.ticks,
            revenue: 0,
            fee: 0,
            isNewToken: isNewToken,
            initialLiquidityBurned: _params.initialLiquidityBurned,
            closed: false
        });

        PoolKey memory poolKey = PoolKey({
            currency0: azUsdIsZero ? azUsd : baseToken_,
            currency1: azUsdIsZero ? baseToken_ : azUsd,
            fee: config.swapFeeRateToLpE6,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(base.marketManager()))
        });

        poolKeys[baseToken_] = poolKey;
        tokenURIs[currentTokenId] = _params.tokenURI;

        base.poolManager().initialize(poolKey, _params.ticks[0].getSqrtPriceAtTick());
        emit PremarketCreated(poolKey, _params, markets[baseToken_], name, symbol);

        if (!isNewToken) {
            markets[baseToken_].revenue = _params.azUsdAmount;
            base.buybackManager().setBuyBackState(poolKey, true);
            base.hayek().takeToken(azUsd, msg.sender, address(this), _params.azUsdAmount);
            base.marketManager().closePremarketPosition(poolKey);
        } else if (_params.azUsdAmount > 0) {
            purchase(baseToken_, _params.azUsdAmount);
        }
    }

    function closePremarketPosition(
        PoolKey memory _poolKey
    ) public onlyMarketManager returns (Types.Market memory) {
        Currency azUsd = base.currencyAzUsd();
        Currency baseToken = _poolKey.baseToken(azUsd);
        Types.Market storage market = markets[baseToken];

        if (market.closed) {
            return market;
        }

        ILiquidityManager liquidityManager = base.liquidityManager();
        bool _azUsdIsZero = _poolKey.azUsdIsZero(azUsd);
        uint256 baseTokenBalance =
            _azUsdIsZero ? _poolKey.currency1.balanceOfSelf() : _poolKey.currency0.balanceOfSelf();
        if (_azUsdIsZero) {
            _poolKey.currency1.transfer(address(liquidityManager), baseTokenBalance);
        } else {
            _poolKey.currency0.transfer(address(liquidityManager), baseTokenBalance);
        }
        if (market.revenue > 0) {
            azUsd.transfer(address(liquidityManager), market.revenue);
        }

        ModifyLiquidityParams memory modifyLiquidityParams;
        if (market.isNewToken) {
            if (market.revenue > 0) {
                Types.ModifyLiquiditySweepParams memory sweepParams = Types.ModifyLiquiditySweepParams({
                    sweepAzUsd: true,
                    sweepBaseToken: false,
                    receiver: base.azUsdTreasure()
                });
                modifyLiquidityParams = LiquidityHelper.toAddSingleSidedLiquidityForAzUsdParams(
                    market.ticks[0], _poolKey.tickSpacing, market.revenue, _azUsdIsZero, Types.LISTING_SALT
                );
                liquidityManager.modifyLiquidity(_poolKey, modifyLiquidityParams, sweepParams);
                preMarketPositions[baseToken][0] = Types.LiquidityPositions({
                    owner: address(this),
                    tickLower: modifyLiquidityParams.tickLower,
                    tickUpper: modifyLiquidityParams.tickUpper,
                    baseTokenAmount: 0,
                    azUsdAmount: market.revenue
                });
            }
            if (baseTokenBalance > 0) {
                Types.ModifyLiquiditySweepParams memory sweepParams = Types.ModifyLiquiditySweepParams({
                    sweepAzUsd: false,
                    sweepBaseToken: true,
                    receiver: base.baseTokenTreasure()
                });
                modifyLiquidityParams = LiquidityHelper.toAddSingleSidedLiquidityForBaseTokenParams(
                    market.ticks[0], _poolKey.tickSpacing, baseTokenBalance, _azUsdIsZero, Types.LISTING_SALT
                );
                liquidityManager.modifyLiquidity(_poolKey, modifyLiquidityParams, sweepParams);
                preMarketPositions[baseToken][1] = Types.LiquidityPositions({
                    owner: address(this),
                    tickLower: modifyLiquidityParams.tickLower,
                    tickUpper: modifyLiquidityParams.tickUpper,
                    baseTokenAmount: baseTokenBalance,
                    azUsdAmount: 0
                });
            }
        } else {
            modifyLiquidityParams = LiquidityHelper.toAddLiquidityParams(
                market.ticks[0],
                market.ticks[1],
                market.ticks[2],
                market.revenue,
                baseTokenBalance,
                _azUsdIsZero,
                Types.LISTING_SALT
            );
            Types.ModifyLiquiditySweepParams memory sweepParams = Types.ModifyLiquiditySweepParams({
                sweepAzUsd: true,
                sweepBaseToken: true,
                receiver: markets[baseToken].creator
            });
            liquidityManager.modifyLiquidity(_poolKey, modifyLiquidityParams, sweepParams);
            preMarketPositions[baseToken][0] = Types.LiquidityPositions({
                owner: address(this),
                tickLower: modifyLiquidityParams.tickLower,
                tickUpper: modifyLiquidityParams.tickUpper,
                baseTokenAmount: 0,
                azUsdAmount: market.revenue
            });
        }

        market.endsAt = block.timestamp;
        market.closed = true;

        IMarketManager marketManager = base.marketManager();
        if (market.fee > 0) {
            azUsd.transfer(address(marketManager), market.fee);
            marketManager.notifyPoolFees(baseToken, market.fee);
        }
        emit PremarketEnded(market, modifyLiquidityParams);
        return market;
    }

    function purchase(
        Currency _baseToken,
        uint256 _azUsdAmount
    ) public returns (uint256 baseTokenAmount, uint256 feeAmount) {
        if (_azUsdAmount == 0) {
            revert Error.ZeroValue("azUsdAmount");
        }
        if (!isMarketExist(_baseToken)) {
            revert Error.PoolNotFound(Currency.unwrap(_baseToken));
        }
        Types.PremarketState stage = getPremarketState(_baseToken);
        if (stage != Types.PremarketState.Active) {
            revert Error.PremarketStateError(stage);
        }
        Types.Market storage market = markets[_baseToken];
        if (!markets[_baseToken].isNewToken) {
            revert Error.PremarketStateError(Types.PremarketState.Closed);
        }

        PoolKey memory _poolKey = poolKeys[_baseToken];
        Currency azUsd = base.currencyAzUsd();
        uint256 purchaseFeeRateE4 = config.purchaseFeeRateE4;
        base.hayek().takeToken(azUsd, msg.sender, address(this), _azUsdAmount);

        bool _azUsdIsZero = _poolKey.azUsdIsZero(azUsd);
        feeAmount = (_azUsdAmount * purchaseFeeRateE4) / Types.BASIS_POINT;
        baseTokenAmount = market.ticks[0].getQuoteAtTick(
            _azUsdAmount - feeAmount,
            _azUsdIsZero ? _poolKey.currency0 : _poolKey.currency1,
            _azUsdIsZero ? _poolKey.currency1 : _poolKey.currency0
        );
        if (baseTokenAmount > market.supply) {
            baseTokenAmount = market.supply;
            uint256 takeInAmount = market.ticks[0].getQuoteAtTick(
                baseTokenAmount,
                _azUsdIsZero ? _poolKey.currency1 : _poolKey.currency0,
                _azUsdIsZero ? _poolKey.currency0 : _poolKey.currency1
            );
            takeInAmount = (takeInAmount * Types.BASIS_POINT) / (Types.BASIS_POINT - purchaseFeeRateE4);
            feeAmount = (takeInAmount * purchaseFeeRateE4) / Types.BASIS_POINT;
            azUsd.transfer(msg.sender, _azUsdAmount - takeInAmount);
            _azUsdAmount = takeInAmount;
        }
        _baseToken.transfer(msg.sender, baseTokenAmount);

        market.supply -= baseTokenAmount;
        market.revenue += _azUsdAmount - feeAmount;

        market.fee += feeAmount;
        emit Purchase(msg.sender, market, _azUsdAmount, baseTokenAmount, feeAmount);
    }

    function removeLiquidityForCreator(
        Currency _baseToken
    ) public {
        Types.Market memory market = markets[_baseToken];
        if (market.creator != msg.sender) {
            revert Error.NotOwner(market.creator, msg.sender);
        }
        if (!market.closed) {
            revert Error.PremarketNotClosed();
        }
        if (market.isNewToken && market.initialLiquidityBurned) {
            revert Error.InitialLiquidityBurned();
        }

        base.marketManager().removeLiquidityForCreator(_baseToken);
    }

    function removeLiquidity(
        Currency _baseToken
    ) public onlyMarketManager {
        PoolKey memory _poolKey = poolKeys[_baseToken];
        if (markets[_baseToken].isNewToken) {
            for (uint256 i = 0; i < preMarketPositions[_baseToken].length; i++) {
                _removeInitialLiquidity(_poolKey, _baseToken, preMarketPositions[_baseToken][i]);
            }
        } else {
            _removeInitialLiquidity(_poolKey, _baseToken, preMarketPositions[_baseToken][0]);
        }
    }

    function _removeInitialLiquidity(
        PoolKey memory _poolKey,
        Currency _baseToken,
        Types.LiquidityPositions memory liquidityPosition
    ) internal {
        ILiquidityManager liquidityManager = base.liquidityManager();
        (uint128 liquidity,,) = base.poolManager().getPositionInfo({
            poolId: _poolKey.toId(),
            owner: address(liquidityManager),
            tickLower: liquidityPosition.tickLower,
            tickUpper: liquidityPosition.tickUpper,
            salt: Types.LISTING_SALT
        });

        ModifyLiquidityParams memory modifyLiquidityParams = ModifyLiquidityParams({
            tickLower: liquidityPosition.tickLower,
            tickUpper: liquidityPosition.tickUpper,
            liquidityDelta: -liquidity.toInt128(),
            salt: Types.LISTING_SALT
        });
        liquidityManager.removeLiquidityAndTakeTo(
            poolKeys[_baseToken], modifyLiquidityParams, markets[_baseToken].creator
        );
    }

    function getPreMarketPositions(
        Currency _baseToken
    ) public view returns (Types.LiquidityPositions[2] memory) {
        return preMarketPositions[_baseToken];
    }

    function tokenURI(
        uint256 _tokenId
    ) public view override returns (string memory) {
        return tokenURIs[_tokenId];
    }

    function getPremarketState(
        Currency _baseToken
    ) public view returns (Types.PremarketState) {
        Types.Market memory market = markets[_baseToken];
        if (markets[_baseToken].tokenId == 0) {
            return Types.PremarketState.Unknown;
        }
        if (market.closed) {
            return Types.PremarketState.Closed;
        }
        if (market.endsAt > block.timestamp && market.supply > 0) {
            return Types.PremarketState.Active;
        } else {
            return Types.PremarketState.WaitingForClose;
        }
    }

    function getMarket(
        Currency _baseToken
    ) public view returns (Types.Market memory) {
        return markets[_baseToken];
    }

    function isMarketExist(
        Currency _baseToken
    ) public view returns (bool) {
        return markets[_baseToken].tokenId != 0;
    }

    function getPoolKey(
        Currency _baseToken
    ) external view returns (PoolKey memory) {
        return poolKeys[_baseToken];
    }
}
