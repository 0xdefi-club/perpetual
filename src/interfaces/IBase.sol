// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { IAzUsd } from "src/interfaces/IAzUsd.sol";
import { IBuybackManager } from "src/interfaces/IBuybackManager.sol";
import { IHayek } from "src/interfaces/IHayek.sol";
import { IListingManager } from "src/interfaces/IListingManager.sol";
import { ILiquidityManager } from "src/interfaces/ILiquidityManager.sol";
import { IMarketManager } from "src/interfaces/IMarketManager.sol";
import { IOracleManager } from "src/interfaces/IOracleManager.sol";
import { IPerpVault } from "src/interfaces/IPerpVault.sol";
import { IPositionManager } from "src/interfaces/IPositionManager.sol";

interface IBase {
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
    ) external;

    function poolManager() external view returns (IPoolManager);

    function azUsd() external view returns (IAzUsd);
    function currencyAzUsd() external view returns (Currency);

    function buybackManager() external view returns (IBuybackManager);

    function hayek() external view returns (IHayek);

    function listingManager() external view returns (IListingManager);

    function liquidityManager() external view returns (ILiquidityManager);

    function marketManager() external view returns (IMarketManager);

    function oracleManager() external view returns (IOracleManager);

    function perpVault() external view returns (IPerpVault);

    function positionManager() external view returns (IPositionManager);

    function baseTokenImpl() external view returns (address);

    function baseTokenTreasure() external view returns (address);

    function azUsdTreasure() external view returns (address);

    function blockNumber() external view returns (uint256);
}
