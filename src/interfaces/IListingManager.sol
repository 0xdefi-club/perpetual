// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Types } from "src/Types.sol";

interface IListingManager {
    function list(
        Types.ListingRequest calldata params
    ) external payable returns (Currency baseToken);

    function purchase(
        Currency baseToken,
        uint256 azUsdAmount
    ) external returns (uint256 tokensOut, uint256 feeAmount);

    function closePremarketPosition(
        PoolKey memory poolKey
    ) external returns (Types.Market memory);

    function removeLiquidityForCreator(
        Currency baseToken
    ) external;

    function removeLiquidity(
        Currency baseToken
    ) external;

    function getMarket(
        Currency baseToken
    ) external view returns (Types.Market memory);

    function isMarketExist(
        Currency baseToken
    ) external view returns (bool);

    function getPremarketState(
        Currency baseToken
    ) external view returns (Types.PremarketState);

    function getPoolKey(
        Currency baseToken
    ) external view returns (PoolKey memory);
}
