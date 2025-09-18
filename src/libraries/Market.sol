// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { Error } from "src/libraries/Error.sol";
import { Types } from "src/Types.sol";

library Market {
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;

    function baseToken(PoolKey memory _key, Currency _azUsd) internal pure returns (Currency) {
        return _azUsd == _key.currency0 ? _key.currency1 : _key.currency0;
    }

    function azUsdIsZero(PoolKey memory _key, Currency _azUsd) internal pure returns (bool) {
        return _azUsd == _key.currency0;
    }

    function currencies(PoolKey memory _key, Currency _azUsd) internal pure returns (Currency, Currency) {
        return (_azUsd, _key.currency0 == _azUsd ? _key.currency1 : _key.currency0);
    }

    function validateListing(
        Types.ListingRequest memory _props,
        Types.ListingManagerConfig memory _config,
        Types.NewTokenSchema memory _schema,
        bool _isNewToken
    ) internal {
        if (_props.baseTokenAmount == 0) {
            revert Error.AmountsForPremarketIsZero();
        }

        if (_props.baseToken.isAddressZero() && msg.value != _props.baseTokenAmount) {
            revert Error.InvalidValue(msg.value, _props.baseTokenAmount);
        }

        if (_isNewToken) {
            if (_props.baseToken.isAddressZero()) {
                revert Error.ZeroValue("baseToken");
            }
            if (_props.azUsdAmount < _config.creatorMinPurchaseAmount) {
                revert Error.InsufficientAzUsd(_props.azUsdAmount, _config.creatorMinPurchaseAmount);
            }
            if (_props.baseTokenAmount > _schema.maxAmountsForPremarket) {
                revert Error.MaxAmountsForPremarket(_props.baseTokenAmount, _schema.maxAmountsForPremarket);
            }

            if (_props.creatorFeeAllocation > _schema.maxCreatorFeeAllocation) {
                revert Error.CreatorFeeAllocationTooHigh(_props.creatorFeeAllocation, _schema.maxCreatorFeeAllocation);
            }
        } else {
            if (_props.azUsdAmount == 0) {
                revert Error.ZeroValue("azUsdAmount");
            }
            if (_props.ticks[0] <= _props.ticks[1] || _props.ticks[0] >= _props.ticks[2]) {
                revert Error.InvalidTicks(_props.ticks);
            }
        }
    }
}
