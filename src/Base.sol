// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { IAzUsd } from "src/interfaces/IAzUsd.sol";
import { IBuybackManager } from "src/interfaces/IBuybackManager.sol";
import { IHayek } from "src/interfaces/IHayek.sol";
import { IListingManager } from "src/interfaces/IListingManager.sol";
import { ILiquidityManager } from "src/interfaces/ILiquidityManager.sol";
import { IMarketManager } from "src/interfaces/IMarketManager.sol";
import { IOracleManager } from "src/interfaces/IOracleManager.sol";
import { IPerpVault } from "src/interfaces/IPerpVault.sol";
import { IPositionManager } from "src/interfaces/IPositionManager.sol";
import { Error } from "src/libraries/Error.sol";

interface ArbSys {
    function arbBlockNumber() external view returns (uint256);

    function arbBlockHash(
        uint256 blockNumber
    ) external view returns (bytes32);
}

contract Base is IBase, Ownable {
    IPoolManager public poolManager;
    IAzUsd public azUsd;
    IBuybackManager public buybackManager;
    IHayek public hayek;
    IListingManager public listingManager;
    ILiquidityManager public liquidityManager;
    IMarketManager public marketManager;
    IOracleManager public oracleManager;
    IPerpVault public perpVault;
    IPositionManager public positionManager;
    address public baseTokenImpl;
    address public baseTokenTreasure;
    address public azUsdTreasure;

    bool public immutable IS_ARBITRUM;
    address public constant ARB_SYS = 0x0000000000000000000000000000000000000064;

    event SystemAddressesInitialized(
        address poolManager,
        address azUsd,
        address buybackManager,
        address hayek,
        address listingManager,
        address liquidityManager,
        address marketManager,
        address oracleManager,
        address perpVault,
        address positionManager,
        address baseTokenImpl,
        address baseTokenTreasure,
        address azUsdFeeReceiver
    );

    constructor() Ownable(msg.sender) {
        uint256 id = block.chainid;
        IS_ARBITRUM = (id == 42_161 || id == 421_614);
    }

    function initializeAddresses(
        IPoolManager _poolManager,
        IAzUsd _azUsd,
        IBuybackManager _buybackManager,
        IHayek _hayek,
        IListingManager _listingManager,
        ILiquidityManager _liquidityManager,
        IMarketManager _marketManager,
        IOracleManager _oracleManager,
        IPerpVault _perpVault,
        IPositionManager _positionManager,
        address _baseTokenImpl,
        address _baseTokenTreasure,
        address _azUsdTreasure
    ) public onlyOwner {
        if (address(_poolManager) == address(0)) {
            revert Error.ZeroAddress("poolManager");
        }
        if (address(_azUsd) == address(0)) revert Error.ZeroAddress("azUsd");
        if (address(_buybackManager) == address(0)) {
            revert Error.ZeroAddress("buybackManager");
        }
        if (address(_hayek) == address(0)) revert Error.ZeroAddress("hayek");
        if (address(_listingManager) == address(0)) {
            revert Error.ZeroAddress("listingManager");
        }
        if (address(_liquidityManager) == address(0)) {
            revert Error.ZeroAddress("liquidityManager");
        }
        if (address(_marketManager) == address(0)) {
            revert Error.ZeroAddress("marketManager");
        }
        if (address(_oracleManager) == address(0)) {
            revert Error.ZeroAddress("oracleManager");
        }
        if (address(_perpVault) == address(0)) {
            revert Error.ZeroAddress("perpVault");
        }
        if (address(_positionManager) == address(0)) {
            revert Error.ZeroAddress("positionManager");
        }
        if (address(_baseTokenImpl) == address(0)) {
            revert Error.ZeroAddress("baseTokenImpl");
        }
        if (address(_baseTokenTreasure) == address(0)) {
            revert Error.ZeroAddress("baseTokenTreasure");
        }
        if (address(_azUsdTreasure) == address(0)) {
            revert Error.ZeroAddress("azUsdTreasure");
        }

        poolManager = _poolManager;
        azUsd = _azUsd;
        buybackManager = _buybackManager;
        hayek = _hayek;
        listingManager = _listingManager;
        liquidityManager = _liquidityManager;
        marketManager = _marketManager;
        oracleManager = _oracleManager;
        perpVault = _perpVault;
        positionManager = _positionManager;
        baseTokenImpl = _baseTokenImpl;
        baseTokenTreasure = _baseTokenTreasure;
        azUsdTreasure = _azUsdTreasure;

        emit SystemAddressesInitialized(
            address(_poolManager),
            address(_azUsd),
            address(_buybackManager),
            address(_hayek),
            address(_listingManager),
            address(_liquidityManager),
            address(_marketManager),
            address(_oracleManager),
            address(_perpVault),
            address(_positionManager),
            _baseTokenImpl,
            _baseTokenTreasure,
            _azUsdTreasure
        );
    }

    function currencyAzUsd() public view returns (Currency) {
        return Currency.wrap(address(azUsd));
    }

    function blockNumber() public view returns (uint256) {
        if (IS_ARBITRUM) {
            (bool ok, bytes memory data) = ARB_SYS.staticcall(abi.encodeWithSelector(ArbSys.arbBlockNumber.selector));
            if (ok && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
        }
        return block.number;
    }
}
