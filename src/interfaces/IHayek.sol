// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

interface IHayek {
    function takeToken(Currency token, address from, address to, uint256 amount) external;
    function operators(
        address target
    ) external view returns (bool);
}
