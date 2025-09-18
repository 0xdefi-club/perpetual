// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@solmate/src/tokens/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract TToken is ERC20, Ownable {
    uint256 public mintCooldown = 1 days;
    mapping(address => uint256) public lastMintAt;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol, _decimals) Ownable(msg.sender) { }

    function faucet() public virtual {
        require(block.timestamp - lastMintAt[msg.sender] > mintCooldown, "Mint cooldown not met");
        lastMintAt[msg.sender] = block.timestamp;
        _mint(msg.sender, 5000 * (10 ** decimals));
    }

    function mint(address to, uint256 value) public virtual onlyOwner {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual onlyOwner {
        _burn(from, value);
    }
}
