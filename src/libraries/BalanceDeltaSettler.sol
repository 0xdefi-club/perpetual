// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

library BalanceDeltaSettler {
    using CurrencySettler for Currency;

    function settleDeltaFor(
        BalanceDelta _delta,
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        address account
    ) internal {
        if (_delta.amount0() < 0) {
            _poolKey.currency0.settle(_poolManager, account, uint128(-_delta.amount0()), false);
        } else if (_delta.amount0() > 0) {
            _poolManager.take(_poolKey.currency0, account, uint128(_delta.amount0()));
        }

        if (_delta.amount1() < 0) {
            _poolKey.currency1.settle(_poolManager, account, uint128(-_delta.amount1()), false);
        } else if (_delta.amount1() > 0) {
            _poolManager.take(_poolKey.currency1, account, uint128(_delta.amount1()));
        }
    }

    function takeDeltaTo(
        BalanceDelta _delta,
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        address receiver
    ) internal {
        if (_delta.amount0() > 0) {
            _poolManager.take(_poolKey.currency0, receiver, uint128(_delta.amount0()));
        }

        if (_delta.amount1() > 0) {
            _poolManager.take(_poolKey.currency1, receiver, uint128(_delta.amount1()));
        }
    }
}
