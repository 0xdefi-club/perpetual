// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Market } from "src/libraries/Market.sol";
import { TickHelper } from "src/libraries/TickHelper.sol";
import { BalanceDeltaSettler } from "src/libraries/BalanceDeltaSettler.sol";
import { Error } from "src/libraries/Error.sol";
import { BalanceDeltaSettler } from "src/libraries/BalanceDeltaSettler.sol";
import { ILiquidityManager } from "src/interfaces/ILiquidityManager.sol";
import { Types } from "src/Types.sol";

contract LiquidityManager is ILiquidityManager {
    using StateLibrary for IPoolManager;
    using Market for PoolKey;
    using BalanceDeltaSettler for Currency;
    using SafeCast for *;
    using StateLibrary for IPoolManager;
    using TickHelper for int24;

    string public constant name = "LiquidityManager";

    IBase public base;

    event LiquidityManagerInitialized(address indexed azUsd, address indexed marketManager);

    event LiquidityModified(
        PoolKey indexed poolKey, address indexed caller, ModifyLiquidityParams params, int256 amount0, int256 amount1
    );

    event LiquidityRemoved(
        PoolKey indexed poolKey,
        address indexed caller,
        address indexed recipient,
        ModifyLiquidityParams params,
        int256 amount0,
        int256 amount1
    );

    event NarrowLiquidityCalculated(
        PoolKey indexed poolKey, uint256 adjacentRanges, uint256 azUsdAmount, uint256 baseTokenAmount
    );

    receive() external payable { }

    constructor(
        IBase _base
    ) {
        base = _base;
    }

    modifier onlyMarketManager() {
        require(msg.sender == address(base.marketManager()), "Only market manager can call this function");
        _;
    }

    modifier onlyOperator() {
        require(base.hayek().operators(msg.sender), "Only operator or token creator can call this function");
        _;
    }

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        Types.ModifyLiquiditySweepParams memory sweepParams
    ) public onlyOperator returns (BalanceDelta delta) {
        IPoolManager poolManager = base.poolManager();
        (delta,) = poolManager.modifyLiquidity({ key: key, params: params, hookData: "" });
        BalanceDeltaSettler.settleDeltaFor(delta, poolManager, key, address(this));

        Currency azUsd_ = base.currencyAzUsd();
        Currency baseToken_ = key.baseToken(azUsd_);
        if (sweepParams.sweepAzUsd && azUsd_.balanceOf(address(this)) > 0) {
            uint256 azUsdBalance = azUsd_.balanceOf(address(this));
            if (azUsdBalance > 0) {
                azUsd_.transfer(sweepParams.receiver, azUsdBalance);
            }
        }
        if (sweepParams.sweepBaseToken && baseToken_.balanceOf(address(this)) > 0) {
            uint256 baseTokenBalance = baseToken_.balanceOf(address(this));
            if (baseTokenBalance > 0) {
                baseToken_.transfer(sweepParams.receiver, baseTokenBalance);
            }
        }
        emit LiquidityModified(key, msg.sender, params, delta.amount0(), delta.amount1());
        return delta;
    }

    function removeLiquidityAndTakeTo(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        address to
    ) public onlyOperator returns (BalanceDelta delta) {
        IPoolManager poolManager = base.poolManager();
        (delta,) = poolManager.modifyLiquidity({ key: key, params: params, hookData: "" });
        if (delta.amount0() < 0 && delta.amount1() < 0) {
            revert Error.ZeroDelta();
        }
        BalanceDeltaSettler.takeDeltaTo(delta, poolManager, key, to);
        emit LiquidityRemoved(key, msg.sender, to, params, delta.amount0(), delta.amount1());
        return delta;
    }
}
