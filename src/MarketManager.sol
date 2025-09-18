// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Error } from "src/libraries/Error.sol";
import { Market } from "src/libraries/Market.sol";
import { IMarketManager } from "src/interfaces/IMarketManager.sol";
import { IListingManager } from "src/interfaces/IListingManager.sol";
import { IBuybackManager } from "src/interfaces/IBuybackManager.sol";
import { IPerpVault } from "src/interfaces/IPerpVault.sol";
import { Types } from "src/Types.sol";
import { IOracleManager } from "src/interfaces/IOracleManager.sol";
import { TickHelper } from "src/libraries/TickHelper.sol";
import { LiquidityHelper } from "src/libraries/LiquidityHelper.sol";

contract MarketManager is BaseHook, IMarketManager {
    using Market for PoolKey;
    using Market for Types.Market;
    using SafeCast for *;
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using TickMath for int24;
    using TickHelper for int24;
    using LiquidityHelper for PoolKey;

    string public constant name = "MarketManager";
    IBase public base;
    Types.MarketConfig public config;
    uint256 public constant ADJACENT_RANGES = 2;

    mapping(Currency baseToken => int24 lastTick) public lastTicks;
    mapping(Currency baseToken => uint256 feeAmount) public poolFees;

    mapping(Currency baseToken => bool perpetualEnabled) public perpetualEnabled;
    mapping(Currency baseToken => uint256 perpetualPreheatedAt) public perpetualPreheatedAt;

    event MarketConfigUpdated(Types.MarketConfig config);

    event PerpetualPreheatedUpdated(Currency indexed baseToken, uint256 preheatedAt);

    event PerpetualEnabled(
        Currency indexed baseToken,
        uint256 indexed vaultId,
        uint160 sqrtPriceX96,
        uint256 markPrice,
        uint256 enabledNewRound
    );

    event PerpetualDisabled(
        Currency indexed baseToken,
        uint256 indexed vaultId,
        uint160 sqrtPriceX96,
        uint256 markPrice,
        uint256 disabledPreRound
    );

    event NarrowLiquidityUpdated(Currency indexed baseToken, uint256 azUsdAmount, uint256 baseTokenAmount);

    event BaseTokenFeesCollected(Currency indexed baseToken, uint256 feeAmount);

    event Swap(
        Currency indexed baseToken,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 lpFee,
        uint256 feeAmount,
        Currency feeCurrency,
        uint256 swapFeeBps,
        int24 beforeTick,
        SwapParams swapParams
    );

    event ModifyLiquidity(
        Currency indexed baseToken, int128 amount0, int128 amount1, ModifyLiquidityParams modifyLiquidityParams
    );

    receive() external payable { }

    modifier selfOnly() {
        if (msg.sender != address(this)) revert Error.NotSelf(msg.sender);
        _;
    }

    modifier liquidityChecker(
        PoolKey calldata _poolKey
    ) {
        Currency baseToken = (_poolKey.baseToken(base.currencyAzUsd()));
        (Types.PerpetualState perpetualState,) = getPerpetualState(baseToken);
        (uint256 azUsdAmount, uint256 baseTokenAmount, int24 currentTick) = _poolKey.getNarrowLiquidityAmounts(base, 2);
        emit NarrowLiquidityUpdated(baseToken, azUsdAmount, baseTokenAmount);
        bool reached = isReachPreheatingThreshold(_poolKey, azUsdAmount, baseTokenAmount, currentTick);
        if (reached) {
            if (perpetualPreheatedAt[baseToken] == 0) {
                perpetualPreheatedAt[baseToken] = block.timestamp;
                emit PerpetualPreheatedUpdated(baseToken, block.timestamp);
            }
            if (perpetualState == Types.PerpetualState.Enabled && !perpetualEnabled[baseToken]) {
                _enablePerpetual(_poolKey);
            }
        } else {
            if (perpetualPreheatedAt[baseToken] != 0) {
                perpetualPreheatedAt[baseToken] = 0;
                emit PerpetualPreheatedUpdated(baseToken, 0);
            }
            if (perpetualEnabled[baseToken]) {
                _disablePerpetual(_poolKey);
            }
        }
        _;
    }

    constructor(IBase _base, IPoolManager _manager, Types.MarketConfig memory _config) BaseHook(_manager) {
        base = _base;
        config = _config;
        emit MarketConfigUpdated(config);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata _poolKey,
        uint160
    ) internal virtual override returns (bytes4) {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());
        if (!base.listingManager().isMarketExist(baseToken)) {
            revert Error.MarketNotExists();
        } else {
            PoolKey memory listingPoolKey = base.listingManager().getPoolKey(baseToken);
            if (PoolId.unwrap(listingPoolKey.toId()) != PoolId.unwrap(_poolKey.toId())) {
                revert Error.MarketNotExists();
            }
        }
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(
        address,
        PoolKey calldata _poolKey,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());
        lastTicks[baseToken] = tick;
        base.oracleManager().initializeObservation(baseToken, tick);
        return this.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata _poolKey,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());
        Types.PremarketState _state = base.listingManager().getPremarketState(baseToken);
        if (_state != Types.PremarketState.WaitingForClose && _state != Types.PremarketState.Closed) {
            revert Error.PremarketStateError(_state);
        }
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata _poolKey,
        ModifyLiquidityParams calldata _params,
        BalanceDelta _delta,
        BalanceDelta,
        bytes calldata
    ) internal override liquidityChecker(_poolKey) returns (bytes4, BalanceDelta) {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());
        emit ModifyLiquidity(baseToken, _delta.amount0(), _delta.amount1(), _params);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata _poolKey,
        ModifyLiquidityParams calldata _params,
        BalanceDelta _delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override liquidityChecker(_poolKey) returns (bytes4, BalanceDelta) {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());
        emit ModifyLiquidity(baseToken, _delta.amount0(), _delta.amount1(), _params);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(
        address,
        PoolKey calldata _poolKey,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4 _selector, BeforeSwapDelta _beforeSwapDelta, uint24) {
        (Currency azUsd, Currency baseToken) = _poolKey.currencies(base.currencyAzUsd());
        IListingManager listingManager = base.listingManager();
        Types.PremarketState _stage = listingManager.getPremarketState(baseToken);
        if (_stage == Types.PremarketState.WaitingForClose) {
            listingManager.closePremarketPosition(_poolKey);
        } else if (_stage != Types.PremarketState.Closed) {
            revert Error.PremarketStateError(_stage);
        }
        (uint160 sqrtPriceX96, int24 _beforeSwapTick,,) = poolManager.getSlot0(_poolKey.toId());
        lastTicks[baseToken] = _beforeSwapTick;
        if (perpetualEnabled[baseToken]) {
            base.oracleManager().updatePoolPrice(baseToken, sqrtPriceX96, _poolKey.azUsdIsZero(azUsd));
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata _poolKey,
        SwapParams calldata _swapParams,
        BalanceDelta _delta,
        bytes calldata
    ) internal override liquidityChecker(_poolKey) returns (bytes4, int128 _deltaUnspecified) {
        PoolId poolId = _poolKey.toId();
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());

        (uint160 sqrtPriceX96, int24 afterTick,, uint24 lpFee) = poolManager.getSlot0(poolId);

        (Currency unspecifiedCurrency, int128 unspecifiedAmount) = (
            _swapParams.amountSpecified < 0 == _swapParams.zeroForOne
        ) ? (_poolKey.currency1, _delta.amount1()) : (_poolKey.currency0, _delta.amount0());

        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;
        uint256 feeAmount =
            (uint256(uint128(unspecifiedAmount)) * config.swapFeeRateToProtocolE6) / Types.BORROWING_RATE_PRECISION;
        if (feeAmount > 0) {
            _captureAndDistributeFees(_poolKey, unspecifiedCurrency, feeAmount);
            _deltaUnspecified = int128(int256(feeAmount));
        }

        emit Swap(
            baseToken,
            msg.sender,
            _delta.amount0(),
            _delta.amount1(),
            sqrtPriceX96,
            poolManager.getLiquidity(poolId),
            afterTick,
            lpFee,
            feeAmount,
            unspecifiedCurrency,
            config.swapFeeRateToProtocolE6,
            lastTicks[baseToken],
            _swapParams
        );

        return (this.afterSwap.selector, _deltaUnspecified);
    }

    function _captureAndDistributeFees(PoolKey memory _poolKey, Currency _feeCurrency, uint256 _feeAmount) internal {
        (Currency azUsd, Currency baseToken) = _poolKey.currencies(base.currencyAzUsd());
        poolManager.take(_feeCurrency, address(this), _feeAmount);
        if (_feeCurrency == azUsd) {
            IBuybackManager buybackManager = base.buybackManager();
            if (buybackManager.isBuyBackEnabled(baseToken)) {
                _feeCurrency.transfer(address(buybackManager), poolFees[baseToken] + _feeAmount);
                buybackManager.notifyBuyBack(_poolKey, poolFees[baseToken] + _feeAmount, lastTicks[baseToken]);
                poolFees[baseToken] = 0;
            } else {
                _feeCurrency.transfer(base.azUsdTreasure(), _feeAmount);
            }
        } else {
            _feeCurrency.transfer(base.baseTokenTreasure(), _feeAmount);
            emit BaseTokenFeesCollected(baseToken, _feeAmount);
        }
    }

    function notifyPoolFees(Currency _baseToken, uint256 _feeAmount) public {
        if (msg.sender != address(base.listingManager())) {
            revert Error.CallerIsNotListingManager();
        }
        if (_feeAmount == 0) {
            return;
        }
        poolFees[_baseToken] += _feeAmount;
    }

    function _enablePerpetual(
        PoolKey memory _poolKey
    ) internal {
        IPerpVault perpVault = base.perpVault();
        IOracleManager oracleManager = base.oracleManager();
        (Currency azUsd, Currency baseToken) = _poolKey.currencies(base.currencyAzUsd());
        uint256 vaultId = perpVault.getVaultId(baseToken);
        if (vaultId == 0) {
            vaultId = perpVault.addMarket(baseToken);
        }
        base.positionManager().incrementRound(baseToken);
        perpetualEnabled[baseToken] = true;
        (uint160 sqrtPriceX96,,,) = base.poolManager().getSlot0(_poolKey.toId());
        oracleManager.updatePoolPrice(baseToken, sqrtPriceX96, _poolKey.azUsdIsZero(azUsd));
        uint256 currentRound = base.positionManager().getCurrentRound(baseToken);
        emit PerpetualEnabled(baseToken, vaultId, sqrtPriceX96, oracleManager.getMarkPrice(baseToken), currentRound);
    }

    function _disablePerpetual(
        PoolKey memory _poolKey
    ) internal {
        (Currency azUsd, Currency baseToken) = _poolKey.currencies(base.currencyAzUsd());
        perpetualEnabled[baseToken] = false;
        uint256 vaultId = base.perpVault().getVaultId(baseToken);
        if (vaultId != 0) {
            IOracleManager oracleManager = base.oracleManager();
            (uint160 sqrtPriceX96,,,) = base.poolManager().getSlot0(_poolKey.toId());
            oracleManager.updatePoolPrice(baseToken, sqrtPriceX96, _poolKey.azUsdIsZero(azUsd));
            uint256 currentRound = base.positionManager().getCurrentRound(baseToken);
            emit PerpetualDisabled(
                baseToken, vaultId, sqrtPriceX96, oracleManager.getMarkPrice(baseToken), currentRound
            );
        }
        base.positionManager().triggerADLIfNeeded(baseToken);
    }

    function disablePerpetual(
        Currency _baseToken
    ) external {
        if (msg.sender != address(base.positionManager())) {
            revert Error.CallerIsNotPositionManager();
        }
        PoolKey memory poolKey = base.listingManager().getPoolKey(_baseToken);
        _disablePerpetual(poolKey);
    }

    function fastEnablePerpetual(
        Currency _baseToken
    ) public {
        if (!base.listingManager().isMarketExist(_baseToken)) {
            revert Error.MarketNotExists();
        }
        if (perpetualEnabled[_baseToken]) {
            revert Error.PerpetualAlreadyEnabled();
        }

        PoolKey memory poolKey = base.listingManager().getPoolKey(_baseToken);
        (uint256 azUsdAmount, uint256 baseTokenAmount, int24 currentTick) = poolKey.getNarrowLiquidityAmounts(base, 2);
        emit NarrowLiquidityUpdated(_baseToken, azUsdAmount, baseTokenAmount);
        bool reached = isReachPreheatingThreshold(poolKey, azUsdAmount, baseTokenAmount, currentTick);
        require(reached, "Not reached preheating threshold");
        perpetualPreheatedAt[_baseToken] = block.timestamp - config.preheatingDuration - 1;
        emit PerpetualPreheatedUpdated(_baseToken, perpetualPreheatedAt[_baseToken]);
        _enablePerpetual(poolKey);
    }

    function closeBuyBack(
        PoolKey memory _poolKey
    ) public {
        if (msg.sender != address(base.buybackManager())) {
            revert Error.CallerIsNotBuybackManager();
        }
        base.poolManager().unlock(abi.encodeCall(base.buybackManager().closeBuyBack, (_poolKey)));
    }

    function removeLiquidityForCreator(
        Currency _baseToken
    ) public {
        if (msg.sender != address(base.listingManager())) {
            revert Error.CallerIsNotListingManager();
        }
        base.poolManager().unlock(abi.encodeCall(base.listingManager().removeLiquidity, _baseToken));
    }

    function closePremarketPosition(
        PoolKey memory _poolKey
    ) public {
        if (msg.sender != address(base.listingManager())) {
            revert Error.CallerIsNotListingManager();
        }
        base.poolManager().unlock(abi.encodeCall(base.listingManager().closePremarketPosition, _poolKey));
    }

    function unlockCallback(
        bytes calldata _data
    ) external returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(_data);
        if (success) return returnData;
        if (returnData.length == 0) revert Error.UnLockCallbackFailed();
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    function isReachPreheatingThreshold(
        PoolKey memory _poolKey,
        uint256 azUsdAmount,
        uint256 baseTokenAmount,
        int24 currentTick
    ) public view returns (bool) {
        if (config.perpetualMinAzUsdAmount > azUsdAmount) {
            return false;
        }
        bool _azUsdIsZero = _poolKey.azUsdIsZero(base.currencyAzUsd());
        uint256 minBaseTokenAmount = currentTick.getQuoteAtTick(
            config.perpetualMinAzUsdAmount,
            _azUsdIsZero ? _poolKey.currency0 : _poolKey.currency1,
            _azUsdIsZero ? _poolKey.currency1 : _poolKey.currency0
        );
        return baseTokenAmount >= minBaseTokenAmount;
    }

    function getNarrowSpotLiquidityInAzUsd(
        Currency _baseToken
    ) public view returns (uint256 amount) {
        PoolKey memory poolKey = base.listingManager().getPoolKey(_baseToken);
        bool _azUsdIsZero = poolKey.azUsdIsZero(base.currencyAzUsd());
        (uint256 azUsdAmount, uint256 baseTokenAmount, int24 currentTick) = poolKey.getNarrowLiquidityAmounts(base, 1);
        uint256 estimatedBaseTokenInAzUsd = currentTick.getQuoteAtTick(
            baseTokenAmount,
            _azUsdIsZero ? poolKey.currency1 : poolKey.currency0,
            _azUsdIsZero ? poolKey.currency0 : poolKey.currency1
        );
        return azUsdAmount + estimatedBaseTokenInAzUsd;
    }

    function getMarketLiquidity(
        Currency _baseToken,
        uint256 round
    ) public view returns (uint256 spotLiquidity, uint256 perpetualLiquidity) {
        spotLiquidity = getNarrowSpotLiquidityInAzUsd(_baseToken);
        uint256 azUsdBalances = base.perpVault().azUsdBalances(_baseToken, round);
        (Types.ADLInfo memory longAdlInfo, Types.ADLInfo memory shortAdlInfo) =
            base.positionManager().getAdlStorage(_baseToken, round);
        int256 adlPnl = longAdlInfo.globalLongPnl + shortAdlInfo.globalShortPnl;
        if (int256(azUsdBalances) - adlPnl < 0) {
            revert Error.InvalidLiquidityAndPnl(azUsdBalances, adlPnl);
        } else {
            perpetualLiquidity = uint256(int256(azUsdBalances) - adlPnl);
        }
        return (spotLiquidity, perpetualLiquidity);
    }

    function getPerpetualState(
        Currency _baseToken
    ) public view returns (Types.PerpetualState state, uint256 preheatedAt) {
        preheatedAt = perpetualPreheatedAt[_baseToken];

        if (preheatedAt == 0) {
            return (Types.PerpetualState.Disabled, preheatedAt);
        }

        uint256 preheatedEndTime = preheatedAt + config.preheatingDuration;
        if (block.timestamp < preheatedEndTime) {
            return (Types.PerpetualState.Preheating, preheatedAt);
        } else {
            return (Types.PerpetualState.Enabled, preheatedAt);
        }
    }

    function getPoolFees(
        Currency _baseToken
    ) public view returns (uint256) {
        return poolFees[_baseToken];
    }
}
