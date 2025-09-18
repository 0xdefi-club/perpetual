// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Types } from "src/Types.sol";
import { Error } from "src/libraries/Error.sol";
import { IHayek } from "src/interfaces/IHayek.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";

contract Hayek is IHayek {
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibraryExt for Currency;

    IBase public base;

    mapping(address => bool) public operators;

    event Initialized(address[] operators);

    modifier onlyOperator() {
        require(operators[msg.sender], "msg.sender is not an operator");
        _;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(base.poolManager()), "msg.sender is not the pool manager");
        _;
    }

    receive() external payable { }

    constructor(IBase _base, address[] memory _operators) {
        base = _base;
        for (uint256 i = 0; i < _operators.length; i++) {
            operators[_operators[i]] = true;
        }
        emit Initialized(_operators);
    }

    function takeToken(Currency token, address from, address to, uint256 amount) external onlyOperator {
        if (token.isAddressZero()) {
            revert Error.HayekOnlyForwardERC20();
        }
        token.transferFrom(from, to, amount);
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        Types.SwapSettings memory settings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            base.poolManager().unlock(abi.encode(Types.SwapCallbackData(msg.sender, settings, key, params, hookData))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(
        bytes calldata rawData
    ) external onlyPoolManager returns (bytes memory) {
        IPoolManager poolManager = base.poolManager();
        Types.SwapCallbackData memory data = abi.decode(rawData, (Types.SwapCallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaBefore0 == 0, "deltaBefore0 is not equal to 0");
        require(deltaBefore1 == 0, "deltaBefore1 is not equal to 0");

        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (data.params.zeroForOne) {
            if (data.params.amountSpecified < 0) {
                require(delta.amount0() == data.params.amountSpecified, "amount0 is not equal to amountSpecified");
                require(deltaAfter1 >= 0, "deltaAfter1 is not greater than or equal to 0");
            } else {
                require(delta.amount1() == data.params.amountSpecified, "amount1 is not equal to amountSpecified");
                require(deltaAfter0 <= 0, "deltaAfter0 is not less than or equal to zero");
            }
        } else {
            if (data.params.amountSpecified < 0) {
                require(delta.amount1() == data.params.amountSpecified, "amount1 is not equal to amountSpecified");
                require(deltaAfter0 >= 0, "deltaAfter0 is not greater than or equal to 0");
            } else {
                require(delta.amount0() == data.params.amountSpecified, "amount0 is not equal to amountSpecified");
                require(deltaAfter1 <= 0, "deltaAfter1 is not less than or equal to 0");
            }
        }

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(poolManager, data.sender, uint256(-deltaAfter0), data.settings.settleUsingBurn);
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(poolManager, data.sender, uint256(-deltaAfter1), data.settings.settleUsingBurn);
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(poolManager, data.sender, uint256(deltaAfter0), data.settings.takeClaims);
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(poolManager, data.sender, uint256(deltaAfter1), data.settings.takeClaims);
        }

        return abi.encode(delta);
    }

    function _fetchBalances(
        Currency currency,
        address user,
        address deltaHolder
    ) internal view returns (uint256 userBalance, uint256 poolBalance, int256 delta) {
        IPoolManager poolManager = base.poolManager();
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(poolManager));
        delta = poolManager.currencyDelta(deltaHolder, currency);
    }
}
