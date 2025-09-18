// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20Minimal } from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library CurrencyLibraryExt {
    error NativeTransferFromFailed();
    error ERC20TransferFromFailed();

    error InvalidCurrency(Currency currency);

    function transferFrom(Currency currency, address from, address to, uint256 value) internal {
        if (currency.isAddressZero()) {
            if (to == address(this)) {
                if (msg.value == value) {
                    return;
                } else {
                    CustomRevert.bubbleUpAndRevertWith(from, bytes4(0), NativeTransferFromFailed.selector);
                }
            }
            if (from == address(this)) {
                bool success;
                assembly ("memory-safe") {
                    success := call(gas(), to, value, 0, 0, 0, 0)
                }
                if (success) {
                    return;
                } else {
                    CustomRevert.bubbleUpAndRevertWith(to, bytes4(0), NativeTransferFromFailed.selector);
                }
            }
            CustomRevert.bubbleUpAndRevertWith(from, bytes4(0), NativeTransferFromFailed.selector);
        } else if (msg.value != 0) {
            CustomRevert.bubbleUpAndRevertWith(from, bytes4(0), NativeTransferFromFailed.selector);
        }

        bytes4 selector_ = IERC20(Currency.unwrap(currency)).transferFrom.selector;
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, selector_)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 68), value)

            if iszero(call(gas(), currency, 0, freeMemoryPointer, 100, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        if (!getLastTransferResult(IERC20(Currency.unwrap(currency)))) {
            CustomRevert.bubbleUpAndRevertWith(
                Currency.unwrap(currency), IERC20Minimal.transferFrom.selector, ERC20TransferFromFailed.selector
            );
        }
    }

    function getLastTransferResult(
        IERC20 token
    ) private view returns (bool success) {
        assembly {
            function revertWithMessage(length, message) {
                mstore(0x00, "\x08\xc3\x79\xa0")
                mstore(0x04, 0x20)
                mstore(0x24, length)
                mstore(0x44, message)
                revert(0x00, 0x64)
            }

            switch returndatasize()
            case 0 {
                if iszero(extcodesize(token)) { revertWithMessage(20, "GPv2: not a contract") }
                success := 1
            }
            case 32 {
                returndatacopy(0, 0, returndatasize())
                success := iszero(iszero(mload(0)))
            }
            default { revertWithMessage(31, "GPv2: malformed transfer result") }
        }
    }

    function tryGetERC20Name(
        Currency currency
    ) internal view returns (bool, string memory) {
        (bool success, bytes memory encodedName) =
            Currency.unwrap(currency).staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        if (success && encodedName.length >= 32) {
            string memory returnedName = abi.decode(encodedName, (string));
            if (bytes(returnedName).length > 0) {
                return (true, returnedName);
            }
        }
        return (false, "");
    }

    function tryGetERC20Symbol(
        Currency currency
    ) internal view returns (bool, string memory) {
        (bool success, bytes memory encodedSymbol) =
            Currency.unwrap(currency).staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        if (success && encodedSymbol.length >= 32) {
            string memory returnedSymbol = abi.decode(encodedSymbol, (string));
            if (bytes(returnedSymbol).length > 0) {
                return (true, returnedSymbol);
            }
        }
        return (false, "");
    }

    function tryGetERC20Decimals(
        Currency currency
    ) internal view returns (bool, uint8) {
        (bool success, bytes memory encodedDecimals) =
            Currency.unwrap(currency).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    function mustGetDecimals(
        Currency currency
    ) internal view returns (uint8) {
        if (currency.isAddressZero()) {
            return 18;
        }
        (bool success, uint8 decimals) = tryGetERC20Decimals(currency);
        if (!success) {
            revert InvalidCurrency(currency);
        }
        return decimals;
    }

    function toStableTokenBAmount(
        Currency currencyA,
        uint256 currencyAAmount,
        Currency currencyB
    ) internal view returns (uint256) {
        uint8 decimalsA = mustGetDecimals(currencyA);
        uint8 decimalsB = mustGetDecimals(currencyB);

        if (decimalsA == decimalsB) {
            return currencyAAmount;
        } else if (decimalsA > decimalsB) {
            return currencyAAmount / (10 ** (decimalsA - decimalsB));
        } else {
            return currencyAAmount * (10 ** (decimalsB - decimalsA));
        }
    }
}
