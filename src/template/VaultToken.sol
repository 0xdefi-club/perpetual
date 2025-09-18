// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC6909 } from "@solmate/src/tokens/ERC6909.sol";

abstract contract VaultToken is ERC6909 {
    mapping(uint256 => string) public names;
    mapping(uint256 => string) public symbols;
    mapping(uint256 => uint256) public totalSupplies;
    uint256 public lpId;

    event Allocate(uint256 id, string name, string symbol);

    function name(
        uint256 id
    ) external view returns (string memory) {
        return names[id];
    }

    function symbol(
        uint256 id
    ) external view returns (string memory) {
        return symbols[id];
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function totalSupply(
        uint256 id
    ) public view returns (uint256) {
        return totalSupplies[id];
    }

    function _mint(address receiver, uint256 id, uint256 amount) internal virtual override {
        super._mint(receiver, id, amount);
        totalSupplies[id] += amount;
    }

    function _burn(address sender, uint256 id, uint256 amount) internal virtual override {
        super._burn(sender, id, amount);
        totalSupplies[id] -= amount;
    }

    function _allocate(string memory name_, string memory symbol_) internal returns (uint256) {
        uint256 id = ++lpId;
        names[id] = name_;
        symbols[id] = symbol_;
        emit Allocate(id, name_, symbol_);
        return id;
    }
}
