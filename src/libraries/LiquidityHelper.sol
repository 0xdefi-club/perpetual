// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { LiquidityMath } from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { TickHelper } from "src/libraries/TickHelper.sol";
import { Types } from "src/Types.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Market } from "src/libraries/Market.sol";

library LiquidityHelper {
    using SafeCast for uint128;
    using TickHelper for int24;
    using TickMath for int24;
    using StateLibrary for IPoolManager;
    using Market for PoolKey;

    function toV4PositionKey(
        PoolId _poolId,
        address _owner,
        int24 _tickLower,
        int24 _tickUpper,
        bytes32 _salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_poolId, _owner, _tickLower, _tickUpper, _salt));
    }

    function toAddLiquidityParams(
        int24 _currentTick,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _azUsdAmount,
        uint256 _baseTokenAmount,
        bool _azUsdIsZero,
        bytes32 salt
    ) external pure returns (ModifyLiquidityParams memory) {
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            _currentTick.getSqrtPriceAtTick(),
            _tickLower.getSqrtPriceAtTick(),
            _tickUpper.getSqrtPriceAtTick(),
            _azUsdIsZero ? _azUsdAmount : _baseTokenAmount,
            _azUsdIsZero ? _baseTokenAmount : _azUsdAmount
        );
        return ModifyLiquidityParams({
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidityDelta: liquidityDelta.toInt128(),
            salt: salt
        });
    }

    function toAddSingleSidedLiquidityForAzUsdParams(
        int24 _currentTick,
        int24 _tickSpacing,
        uint256 _azUsdAmount,
        bool _azUsdIsZero,
        bytes32 salt
    ) external pure returns (ModifyLiquidityParams memory) {
        int24 tickLower;
        int24 tickUpper;
        if (_azUsdIsZero) {
            tickLower = (_currentTick + 1).findValidTick(_tickSpacing, false);
            tickUpper = tickLower + _tickSpacing;
        } else {
            tickUpper = (_currentTick - 1).findValidTick(_tickSpacing, true);
            tickLower = tickUpper - _tickSpacing;
        }
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            _currentTick.getSqrtPriceAtTick(),
            tickLower.getSqrtPriceAtTick(),
            tickUpper.getSqrtPriceAtTick(),
            _azUsdIsZero ? _azUsdAmount : 0,
            _azUsdIsZero ? 0 : _azUsdAmount
        );
        return ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta.toInt128(),
            salt: salt
        });
    }

    function toAddSingleSidedLiquidityForBaseTokenParams(
        int24 _currentTick,
        int24 _tickSpacing,
        uint256 _baseTokenAmount,
        bool _azUsdIsZero,
        bytes32 salt
    ) external pure returns (ModifyLiquidityParams memory) {
        int24 tickLower;
        int24 tickUpper;
        if (_azUsdIsZero) {
            tickLower = TickMath.MIN_TICK.findValidTick(_tickSpacing, false);
            tickUpper = (_currentTick - 1).findValidTick(_tickSpacing, true);
        } else {
            tickLower = (_currentTick + 1).findValidTick(_tickSpacing, false);
            tickUpper = TickMath.MAX_TICK.findValidTick(_tickSpacing, true);
        }
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            _currentTick.getSqrtPriceAtTick(),
            tickLower.getSqrtPriceAtTick(),
            tickUpper.getSqrtPriceAtTick(),
            _azUsdIsZero ? 0 : _baseTokenAmount,
            _azUsdIsZero ? _baseTokenAmount : 0
        );
        return ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta.toInt128(),
            salt: salt
        });
    }

    function getNarrowLiquidityAmounts(
        PoolKey memory key,
        IBase base,
        uint256 adjacentRanges
    ) public view returns (uint256 azUsdAmount, uint256 baseTokenAmount, int24 currentTick) {
        IPoolManager poolManager = base.poolManager();
        PoolId poolId = key.toId();

        Types.LiquidityCalcState memory state;
        uint256 amount0;
        uint256 amount1;

        (state.sqrtPriceX96, state.tick,,) = poolManager.getSlot0(poolId);
        currentTick = state.tick;
        int24 tickLower = state.tick.findValidTick(key.tickSpacing, true);
        int24 tickUpper = tickLower + key.tickSpacing;
        uint128 currentLiquidity = poolManager.getLiquidity(poolId);

        if (tickUpper > TickMath.MAX_TICK) {
            tickUpper = TickMath.MAX_TICK - 1;
        }
        if (tickLower < TickMath.MIN_TICK) {
            tickLower = TickMath.MIN_TICK + 1;
        }

        state.tickLower = tickLower;
        state.tickUpper = tickUpper;
        state.liquidity = currentLiquidity;

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity({
            sqrtPriceX96: state.sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(state.tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(state.tickUpper),
            liquidity: state.liquidity
        });
        state.amount0 += amount0;
        state.amount1 += amount1;

        state.tick = tickUpper;
        state.liquidity = currentLiquidity;
        for (uint256 i = 0; i < adjacentRanges; i++) {
            if (state.tick + key.tickSpacing > TickMath.MAX_TICK) break;

            state.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(state.tick);
            (, state.liquidityNet) = poolManager.getTickLiquidity(poolId, state.tick);
            state.liquidity = LiquidityMath.addDelta(state.liquidity, state.liquidityNet);
            if (state.liquidity == 0) {
                state.tick += key.tickSpacing;
                continue;
            }

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity({
                sqrtPriceX96: state.sqrtPriceX96,
                sqrtPriceAX96: state.sqrtPriceX96,
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(state.tick + key.tickSpacing),
                liquidity: state.liquidity
            });
            state.amount0 += amount0;
            state.amount1 += amount1;
            state.tick += key.tickSpacing;
        }

        state.tick = tickLower;
        state.liquidity = currentLiquidity;
        for (uint256 i = 0; i < adjacentRanges; i++) {
            if (state.tick - key.tickSpacing < TickMath.MIN_TICK) break;

            state.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(state.tick);
            (, state.liquidityNet) = poolManager.getTickLiquidity(poolId, state.tick);
            state.liquidity = LiquidityMath.addDelta(state.liquidity, -state.liquidityNet);
            if (state.liquidity == 0) {
                state.tick -= key.tickSpacing;
                continue;
            }

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity({
                sqrtPriceX96: state.sqrtPriceX96,
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(state.tick - key.tickSpacing),
                sqrtPriceBX96: state.sqrtPriceX96,
                liquidity: state.liquidity
            });

            state.amount0 += amount0;
            state.amount1 += amount1;
            state.tick -= key.tickSpacing;
        }

        if (key.azUsdIsZero(base.currencyAzUsd())) {
            return (state.amount0, state.amount1, currentTick);
        } else {
            return (state.amount1, state.amount0, currentTick);
        }
    }
}
