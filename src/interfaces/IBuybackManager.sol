// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IBuybackManager {
    function notifyBuyBack(PoolKey memory _poolKey, uint256 _feeAmount, int24 _currentTick) external;

    function setBuyBackState(PoolKey memory _key, bool _disable) external;

    function closeBuyBack(
        PoolKey memory _key
    ) external;

    function getBuyBackPosition(
        Currency _baseToken
    ) external view returns (uint256 amount0_, uint256 amount1_, uint256 pendingAzUsd_);

    function isBuyBackEnabled(
        Currency _baseToken
    ) external view returns (bool);
}
