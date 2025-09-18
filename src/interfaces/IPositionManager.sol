// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Types } from "src/Types.sol";

interface IPositionManager {
    function incrementRound(
        Currency baseToken
    ) external returns (uint256);

    function increasePosition(
        Types.Order memory order
    ) external returns (bytes32 positionKey);

    function decreasePosition(
        Types.Order memory order
    ) external;

    function marginCall(
        Types.Order memory order
    ) external;

    function reduceMargin(
        Types.Order memory order
    ) external;

    function triggerADLIfNeeded(
        Currency baseToken
    ) external;

    function liquidate(address owner, Currency baseToken, bool isLong, uint256 positionId) external;

    function updateBorrowingRate(Currency baseToken, uint256 round) external;

    function getPosition(
        bytes32 positionKey
    ) external view returns (Types.Position memory);

    function getGlobalUnrealizedPnl(Currency baseToken, uint256 round) external returns (int256);

    function getMarketOI(Currency baseToken, uint256 round) external view returns (uint256, uint256, uint256);

    function getUserPositions(
        address user
    ) external view returns (Types.Position[] memory);

    function getCurrentRound(
        Currency baseToken
    ) external view returns (uint256);

    function getAdlStorage(
        Currency baseToken,
        uint256 round
    ) external view returns (Types.ADLInfo memory, Types.ADLInfo memory);
}
