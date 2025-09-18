// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

library TickHelper {
    function findValidTick(int24 _tick, int24 _tickSpacing, bool _roundDown) public pure returns (int24 _targetTick) {
        _tick = _clamp(_tick, _tickSpacing);

        if (_tick % _tickSpacing == 0) return _tick;

        _targetTick = (_tick / _tickSpacing) * _tickSpacing;
        if (_tick < 0) {
            _targetTick -= _tickSpacing;
        }

        if (!_roundDown) {
            _targetTick += _tickSpacing;
        }
        return _targetTick;
    }

    function _clamp(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 minAligned = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxAligned = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        if (tick < minAligned) {
            return minAligned;
        }
        if (tick > maxAligned) {
            return maxAligned;
        }
        return tick;
    }

    function getQuoteAtTick(
        int24 _tick,
        uint256 _baseAmount,
        Currency _baseToken,
        Currency _quoteToken
    ) public pure returns (uint256 quoteAmount_) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX192, _baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, _baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX128, _baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, _baseAmount, ratioX128);
        }
    }

    function convertTicks(int24[3] memory ticks, bool azUsdIs0) public pure returns (int24[3] memory) {
        if (!azUsdIs0) {
            return ticks;
        }

        ticks[0] = -ticks[0];
        return ticks;
    }
}
