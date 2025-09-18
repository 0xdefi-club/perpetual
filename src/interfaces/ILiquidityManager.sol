// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import { Types } from "src/Types.sol";

interface ILiquidityManager {
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        Types.ModifyLiquiditySweepParams memory sweepParams
    ) external returns (BalanceDelta delta);

    function removeLiquidityAndTakeTo(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        address to
    ) external returns (BalanceDelta delta);
}
