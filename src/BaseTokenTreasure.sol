// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721Enumerable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";

contract BaseTokenTreasure is ERC721, ERC721Enumerable {
    using CurrencyLibrary for Currency;

    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public CLAIM_INTERVAL = 1 days;

    uint256 public tokenId;
    mapping(uint256 => uint256) public lastClaimedAt;

    event SetClaimInterval(uint256 claimInterval);
    event Claim(address indexed user, uint256 tokenId, Currency currency, uint256 amount);

    receive() external payable { }

    constructor(
        uint256 _claimInterval
    ) ERC721("AZEx BaseTokenTreasure", "AZEx BTT") {
        CLAIM_INTERVAL = _claimInterval;
        emit SetClaimInterval(_claimInterval);
    }

    function mint(
        address to
    ) public {
        uint256 nextId = ++tokenId;
        require(nextId <= MAX_SUPPLY, "BaseTokenTreasure: max supply reached");
        tokenId = nextId;
        _mint(to, nextId);
    }

    function claim(uint256 tokenId_, Currency currency) public {
        require(ownerOf(tokenId_) == msg.sender, "BaseTokenTreasure: not owner");

        uint256 lastClaimedAt_ = lastClaimedAt[tokenId_];
        if (lastClaimedAt_ + CLAIM_INTERVAL > block.timestamp) {
            revert("BaseTokenTreasure: already claimed");
        }

        uint256 balance = currency.balanceOfSelf();
        if (balance == 0) {
            revert("BaseTokenTreasure: no fee");
        }

        uint256 percentage = getPercentage(balance);
        uint256 jackPot = (balance * percentage) / 100;
        lastClaimedAt[tokenId_] = block.timestamp;

        currency.transfer(msg.sender, jackPot);
        emit Claim(msg.sender, tokenId_, currency, jackPot);
    }

    function getPercentage(
        uint256 balance
    ) public view returns (uint256) {
        uint256 randomValue = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, balance, block.coinbase)));
        return (randomValue % 100) + 1;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address to,
        uint256 _tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        if (to != address(0) && balanceOf(to) > 0) {
            revert("BaseTokenTreasure: user already owns an NFT");
        }
        return super._update(to, _tokenId, auth);
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://indexer.azex.io/nft";
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}
