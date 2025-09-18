// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Types } from "src/Types.sol";

interface IPerpVault {
    function addMarket(
        Currency baseToken
    ) external returns (uint256 tokenId);

    function buy(
        Currency baseToken,
        uint256 round,
        uint256 azUsdAmount,
        uint256 minLpTokenAmount,
        uint256 deadline
    ) external;

    function sell(
        Currency baseToken,
        uint256 round,
        uint256 alpTokenAmount,
        uint256 minAzUsdAmount,
        uint256 deadline
    ) external;

    function transferIn(
        Currency baseToken,
        uint256 round,
        Types.VaultTransferType transferType,
        uint256 amount
    ) external;

    function transferOut(
        Currency baseToken,
        uint256 round,
        Types.VaultTransferType transferType,
        uint256 amount
    ) external returns (int256);

    function getAlpPrice(Currency baseToken, uint256 round) external returns (uint256 alpPrice, uint256 aum);

    function baseTokenLpIds(
        Currency baseToken
    ) external view returns (uint256);

    function azUsdBalances(Currency baseToken, uint256 round) external view returns (uint256);

    function getVaultId(
        Currency baseToken
    ) external view returns (uint256);
}
