// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Market } from "src/libraries/Market.sol";
import { LiquidityHelper } from "src/libraries/LiquidityHelper.sol";
import { TickHelper } from "src/libraries/TickHelper.sol";
import { BalanceDeltaSettler } from "src/libraries/BalanceDeltaSettler.sol";
import { ILiquidityManager } from "src/interfaces/ILiquidityManager.sol";
import { IBuybackManager } from "src/interfaces/IBuybackManager.sol";
import { Error } from "src/libraries/Error.sol";
import { Types } from "src/Types.sol";

contract BuybackManager is IBuybackManager {
    using Market for Types.Market;
    using Market for Types.NewTokenSchema;
    using Market for PoolKey;
    using Market for Currency;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickHelper for int24;
    using BalanceDeltaSettler for Currency;
    using StateLibrary for IPoolManager;

    string public constant name = "BuybackManager";

    IBase public base;
    uint256 public buyBackFeeThreshold;

    mapping(Currency baseToken => Types.BuyBackInfo buyBackInfo) public buyBackInfo;

    event FeeReceived(Currency indexed baseToken, uint256 added, uint256 pending);

    event BuyBackRepositioned(Currency indexed baseToken, uint256 azUsdAmount, int24 tickLower, int24 tickUpper);

    event BuyBackClosed(Currency indexed baseToken, uint256 azUsdAmount);

    event BuyBackDisabledStateUpdated(Currency indexed baseToken, bool disabled);

    event BuyBackFeeThresholdUpdated(uint256 newSwapFeeThreshold);

    receive() external payable { }

    modifier onlyMarketManager() {
        if (msg.sender != address(base.marketManager())) {
            revert Error.CallerIsNotMarketManager();
        }
        _;
    }

    modifier onlyListingManager() {
        if (msg.sender != address(base.listingManager())) {
            revert Error.CallerIsNotListingManager();
        }
        _;
    }

    constructor(IBase _base, uint256 _buyBackFeeThreshold) {
        base = _base;
        buyBackFeeThreshold = _buyBackFeeThreshold;
        emit BuyBackFeeThresholdUpdated(buyBackFeeThreshold);
    }

    function _removeLiquidity(
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        bool _azUsdIsZero
    ) internal returns (uint256 azUsdWithdrawn, uint256 baseTokenWithdrawn) {
        ILiquidityManager liquidityManager = base.liquidityManager();
        (uint128 liquidityBefore,,) = base.poolManager().getPositionInfo({
            poolId: _poolKey.toId(),
            owner: address(liquidityManager),
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            salt: Types.BUY_BACK_SALT
        });

        Types.ModifyLiquiditySweepParams memory sweepParams =
            Types.ModifyLiquiditySweepParams({ sweepAzUsd: false, sweepBaseToken: true, receiver: address(this) });
        BalanceDelta delta = liquidityManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: -liquidityBefore.toInt128(),
                salt: Types.BUY_BACK_SALT
            }),
            sweepParams
        );
        (azUsdWithdrawn, baseTokenWithdrawn) = _azUsdIsZero
            ? (uint128(delta.amount0()), uint128(delta.amount1()))
            : (uint128(delta.amount1()), uint128(delta.amount0()));
    }

    function notifyBuyBack(PoolKey memory _poolKey, uint256 _feeAmount, int24 _currentTick) public onlyMarketManager {
        Currency azUsd = base.currencyAzUsd();
        bool _azUsdIsZero = _poolKey.azUsdIsZero(azUsd);
        Currency baseToken = _poolKey.baseToken(azUsd);
        Types.BuyBackInfo storage _buyBackInfo = buyBackInfo[baseToken];
        _buyBackInfo.cumulativeSwapFees += _feeAmount;
        _buyBackInfo.pendingFees += _feeAmount;

        emit FeeReceived(baseToken, _feeAmount, _buyBackInfo.pendingFees);
        if (_buyBackInfo.pendingFees < buyBackFeeThreshold) {
            return;
        }

        uint256 azUsdWithdrawn;
        uint256 baseTokenWithdrawn;
        if (_buyBackInfo.initialized) {
            (azUsdWithdrawn, baseTokenWithdrawn) =
                _removeLiquidity(_poolKey, _buyBackInfo.tickLower, _buyBackInfo.tickUpper, _azUsdIsZero);
        } else {
            _buyBackInfo.initialized = true;
        }

        ILiquidityManager liquidityManager = base.liquidityManager();
        azUsd.transfer(address(liquidityManager), _buyBackInfo.pendingFees);

        uint256 totalFees = _buyBackInfo.pendingFees;
        _buyBackInfo.pendingFees = 0;
        (, int24 slot0Tick,,) = base.poolManager().getSlot0(_poolKey.toId());
        if (_azUsdIsZero == slot0Tick > _currentTick) {
            _currentTick = slot0Tick;
        }

        Types.ModifyLiquiditySweepParams memory sweepParams = Types.ModifyLiquiditySweepParams({
            sweepAzUsd: true,
            sweepBaseToken: false,
            receiver: base.azUsdTreasure()
        });
        ModifyLiquidityParams memory modifyLiquidityParams = LiquidityHelper.toAddSingleSidedLiquidityForAzUsdParams(
            _currentTick, _poolKey.tickSpacing, azUsdWithdrawn + totalFees, _azUsdIsZero, Types.BUY_BACK_SALT
        );
        liquidityManager.modifyLiquidity(_poolKey, modifyLiquidityParams, sweepParams);
        _buyBackInfo.tickLower = modifyLiquidityParams.tickLower;
        _buyBackInfo.tickUpper = modifyLiquidityParams.tickUpper;

        if (baseTokenWithdrawn != 0) {
            baseToken.transfer(base.baseTokenTreasure(), baseTokenWithdrawn);
        }

        emit BuyBackRepositioned(baseToken, azUsdWithdrawn + totalFees, _buyBackInfo.tickLower, _buyBackInfo.tickUpper);
    }

    function setBuyBackState(PoolKey memory _poolKey, bool _disable) external onlyListingManager {
        Currency baseToken = _poolKey.baseToken(base.currencyAzUsd());

        Types.BuyBackInfo storage _buyBackInfo = buyBackInfo[baseToken];
        if (_disable == _buyBackInfo.disabled) {
            return;
        }

        if (_disable) {
            base.marketManager().closeBuyBack(_poolKey);
        }

        _buyBackInfo.disabled = _disable;

        emit BuyBackDisabledStateUpdated(baseToken, _disable);
    }

    function closeBuyBack(
        PoolKey memory _poolKey
    ) external onlyMarketManager {
        Currency azUsd = base.currencyAzUsd();
        bool azUsdIsZero = _poolKey.azUsdIsZero(azUsd);
        Currency baseToken = _poolKey.baseToken(azUsd);
        Types.BuyBackInfo storage _buyBackInfo = buyBackInfo[baseToken];

        uint256 azUsdWithdrawn;
        uint256 baseTokenWithdrawn;

        if (_buyBackInfo.initialized) {
            (azUsdWithdrawn, baseTokenWithdrawn) =
                _removeLiquidity(_poolKey, _buyBackInfo.tickLower, _buyBackInfo.tickUpper, azUsdIsZero);
            _buyBackInfo.initialized = false;
        }

        uint256 pendingAzUsdFees = _buyBackInfo.pendingFees;
        _buyBackInfo.pendingFees = 0;
        _buyBackInfo.cumulativeSwapFees = 0;

        emit BuyBackClosed(baseToken, azUsdWithdrawn + pendingAzUsdFees);
    }

    function getBuyBackPosition(
        Currency _baseToken
    ) public view returns (uint256 amount0_, uint256 amount1_, uint256 pendingAzUsd_) {
        Types.BuyBackInfo memory _buyBackInfo = buyBackInfo[_baseToken];
        if (!_buyBackInfo.initialized) {
            return (0, 0, _buyBackInfo.pendingFees);
        }
        PoolId poolId = base.listingManager().getPoolKey(_baseToken).toId();
        (uint128 liquidity,,) = base.poolManager().getPositionInfo({
            poolId: poolId,
            owner: address(base.liquidityManager()),
            tickLower: _buyBackInfo.tickLower,
            tickUpper: _buyBackInfo.tickUpper,
            salt: Types.BUY_BACK_SALT
        });

        (uint160 sqrtPriceX96,,,) = base.poolManager().getSlot0(poolId);
        (amount0_, amount1_) = LiquidityAmounts.getAmountsForLiquidity({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_buyBackInfo.tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_buyBackInfo.tickUpper),
            liquidity: liquidity
        });

        pendingAzUsd_ = _buyBackInfo.pendingFees;
    }

    function isBuyBackEnabled(
        Currency _baseToken
    ) public view returns (bool) {
        return !buyBackInfo[_baseToken].disabled;
    }
}
