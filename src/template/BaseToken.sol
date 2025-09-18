// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IHayek } from "src/interfaces/IHayek.sol";

contract BaseToken is ERC20 {
    string private name_;
    string private symbol_;
    bool public isInitialized;

    IHayek public immutable hayek;

    constructor(
        IHayek _hayek
    ) ERC20("AZEx", "AZEx") {
        hayek = _hayek;
    }

    function initialize(string memory _name, string memory _symbol, address _to, uint256 _totalSupply) public {
        require(!isInitialized, "BaseToken: already initialized");
        isInitialized = true;
        name_ = _name;
        symbol_ = _symbol;
        _mint(_to, _totalSupply);
    }

    function name() public view virtual override returns (string memory) {
        return name_;
    }

    function symbol() public view virtual override returns (string memory) {
        return symbol_;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        if (msg.sender == address(hayek)) {
            return type(uint256).max - 1;
        }
        return super.allowance(owner, spender);
    }
}
