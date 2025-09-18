// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { Types } from "src/Types.sol";

interface IMarketManager {
    function notifyPoolFees(Currency _baseToken, uint256 _feeAmount) external;
    function closeBuyBack(
        PoolKey memory _key
    ) external;
    function removeLiquidityForCreator(
        Currency baseToken
    ) external;
    function closePremarketPosition(
        PoolKey memory _poolKey
    ) external;
    function perpetualEnabled(
        Currency _baseToken
    ) external view returns (bool);
    function getPerpetualState(
        Currency _baseToken
    ) external view returns (Types.PerpetualState state, uint256 preheatedAt);
    function getNarrowSpotLiquidityInAzUsd(
        Currency _baseToken
    ) external view returns (uint256 amount);
    function disablePerpetual(
        Currency _baseToken
    ) external;
    function getMarketLiquidity(
        Currency _baseToken,
        uint256 round
    ) external view returns (uint256 spotLiquidity, uint256 perpetualLiquidity);
}
