// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

interface IOracleManager {
    function getTruncatedPrice(
        Currency baseToken
    ) external view returns (uint256);
    function getMarkPrice(
        Currency baseToken
    ) external view returns (uint256);
    function syncAdjustedPrice(
        Currency baseToken,
        uint256 nextLongOI,
        uint256 nextShortOI
    ) external returns (uint256);
    function syncAdjustedPrice(
        Currency baseToken,
        bool isLong,
        bool isIncrease,
        uint256 sizeDelta
    ) external returns (uint256);
    function syncAdjustedPrice(
        Currency baseToken
    ) external returns (uint256);
    function updatePoolPrice(Currency baseToken, uint160 priceX96, bool azUsdIsZero) external;
    function initializeObservation(Currency baseToken, int24 tick) external;
}
