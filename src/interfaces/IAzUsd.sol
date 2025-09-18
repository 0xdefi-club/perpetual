// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

interface IAzUsd is IERC20 {
    function underlying() external view returns (Currency);
    function mint(address to, uint256 value) external;
    function burn(address from, uint256 value) external;
}
