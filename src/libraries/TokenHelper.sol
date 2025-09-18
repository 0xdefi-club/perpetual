// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";

abstract contract TokenHelper {
    using CurrencyLibrary for Currency;
    using CurrencyLibraryExt for Currency;

    string public NATIVE_TOKEN_NAME;
    string public NATIVE_TOKEN_SYMBOL;
    uint8 public DEFAULT_DECIMALS = 18;

    error InvalidBaseToken(Currency baseToken);

    constructor(string memory _nativeTokenName, string memory _nativeTokenSymbol) {
        NATIVE_TOKEN_NAME = _nativeTokenName;
        NATIVE_TOKEN_SYMBOL = _nativeTokenSymbol;
    }

    function getCurrencyMeta(
        Currency baseToken
    ) internal view returns (string memory name_, string memory symbol_, uint8 decimals_) {
        if (baseToken.isAddressZero()) {
            return (NATIVE_TOKEN_NAME, NATIVE_TOKEN_SYMBOL, DEFAULT_DECIMALS);
        }
        bool success;

        (success, symbol_) = baseToken.tryGetERC20Symbol();
        if (!success) {
            revert InvalidBaseToken(baseToken);
        }

        (success, name_) = baseToken.tryGetERC20Name();
        if (!success) {
            name_ = symbol_;
        }

        (success, decimals_) = baseToken.tryGetERC20Decimals();
        if (!success) {
            revert InvalidBaseToken(baseToken);
        }

        return (name_, symbol_, decimals_);
    }
}
