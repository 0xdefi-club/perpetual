// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { IAzUsd } from "src/interfaces/IAzUsd.sol";

contract AzUsd is ERC20, IAzUsd, Ownable {
    using CurrencyLibraryExt for Currency;

    IBase public base;
    Currency public underlying;
    uint256 public mintCooldown = 1 days;
    mapping(address => uint256) public lastMintAt;

    constructor(address _owner, IBase _base, Currency _underlying) ERC20("AZEx USD", "azUsd") Ownable(_owner) {
        base = _base;
        underlying = _underlying;
    }

    function allowance(address owner, address spender) public view virtual override(ERC20, IERC20) returns (uint256) {
        if (msg.sender == address(base.hayek())) {
            return type(uint256).max - 1;
        }
        return super.allowance(owner, spender);
    }

    function mint(address to, uint256 value) public {
        underlying.transferFrom(msg.sender, address(this), value);
        uint256 azUsdAmount = underlying.toStableTokenBAmount(value, Currency.wrap(address(this)));
        _mint(to, azUsdAmount);
    }

    function burn(address from, uint256 value) public {
        uint256 underlyingAmount = Currency.wrap(address(this)).toStableTokenBAmount(value, underlying);
        _burn(from, value);
        underlying.transfer(msg.sender, underlyingAmount);
    }
}
