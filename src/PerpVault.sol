// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { Error } from "src/libraries/Error.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";
import { VaultToken } from "src/template/VaultToken.sol";
import { IPositionManager } from "src/interfaces/IPositionManager.sol";
import { IPerpVault } from "src/interfaces/IPerpVault.sol";
import { TokenHelper } from "src/libraries/TokenHelper.sol";
import { Types } from "src/Types.sol";

contract PerpVault is VaultToken, ReentrancyGuard, IPerpVault, TokenHelper {
    using SignedMath for int256;
    using CurrencyLibrary for Currency;
    using CurrencyLibraryExt for Currency;

    string public constant name = "PerpVault";

    IBase public base;

    mapping(Currency => uint256) public baseTokenLpIds;
    mapping(uint256 => Currency) public lpIdBaseTokens;

    mapping(Currency => mapping(uint256 => uint256)) public lpSupply;
    mapping(Currency => mapping(uint256 => uint256)) public azUsdBalances;
    mapping(Currency => mapping(uint256 => uint256)) public feeBalances;
    mapping(Currency => mapping(uint256 => mapping(address => uint256))) public userLpBalances;
    mapping(Currency => mapping(uint256 => mapping(address => uint256))) public lastBuyAt;

    uint256 feeRate = 0;
    uint256 coolDownDuration = 10 minutes;
    uint256 minAzUsdAmount = 1e5;

    event BalanceUpdated(
        uint256 round,
        address from,
        Currency baseToken,
        Types.VaultTransferType transferType,
        uint256 azUsdAmount,
        uint256 feeAmount,
        uint256 lpAmount,
        uint256 callerLpBalance,
        uint256 vaultAzUsdBalance,
        uint256 lpTotalSupply,
        uint256 lpPrice
    );

    modifier onlyMarketManager() {
        if (msg.sender != address(base.marketManager())) {
            revert Error.CallerIsNotMarketManager();
        }
        _;
    }

    modifier onlyPositionManager() {
        if (msg.sender != address(base.positionManager())) {
            revert Error.CallerIsNotPositionManager();
        }
        _;
    }

    constructor(
        IBase _base,
        string memory _nativeTokenName,
        string memory _nativeTokenSymbol
    ) TokenHelper(_nativeTokenName, _nativeTokenSymbol) {
        base = _base;
    }

    function addMarket(
        Currency _baseToken
    ) public onlyMarketManager returns (uint256 tokenId) {
        (string memory tokenName, string memory tokenSymbol,) = getCurrencyMeta(_baseToken);
        tokenId = _allocate(string.concat("AZEx Vault-", tokenName), string.concat("AZEx-", tokenSymbol));
        lpIdBaseTokens[tokenId] = _baseToken;
        baseTokenLpIds[_baseToken] = tokenId;
        return tokenId;
    }

    function buy(Currency _baseToken, uint256 azUsdAmount, uint256 minLpTokenOut, uint256 deadline) public {
        buy(_baseToken, azUsdAmount, minLpTokenOut, base.positionManager().getCurrentRound(_baseToken), deadline);
    }

    function buy(
        Currency _baseToken,
        uint256 azUsdAmount,
        uint256 minLpTokenOut,
        uint256 round,
        uint256 deadline
    ) public nonReentrant {
        IPositionManager positionManager = base.positionManager();
        require(round == positionManager.getCurrentRound(_baseToken), "Invalid round");
        require(block.timestamp < deadline, "Deadline exceeded");

        uint256 baseTokenLpId = baseTokenLpIds[_baseToken];
        if (baseTokenLpId == 0) {
            revert Error.PerpVaultNotInitialized(_baseToken);
        }
        uint256 amountAfterFee = (azUsdAmount * (Types.BASIS_POINT - feeRate)) / Types.BASIS_POINT;
        (uint256 alpPrice,) = getAlpPrice(_baseToken, round);
        uint256 outputLp = (amountAfterFee * 10 ** decimals()) / alpPrice;
        if (outputLp < minLpTokenOut) {
            revert Error.InsufficientOutputAmount();
        }
        base.hayek().takeToken(base.currencyAzUsd(), msg.sender, address(this), azUsdAmount);
        _mint(msg.sender, baseTokenLpId, outputLp);
        lpSupply[_baseToken][round] += outputLp;
        userLpBalances[_baseToken][round][msg.sender] += outputLp;

        positionManager.updateBorrowingRate(_baseToken, round);
        azUsdBalances[_baseToken][round] += amountAfterFee;
        feeBalances[_baseToken][round] += azUsdAmount - amountAfterFee;
        lastBuyAt[_baseToken][round][msg.sender] = block.timestamp;
        base.oracleManager().syncAdjustedPrice(_baseToken);

        emit BalanceUpdated(
            round,
            msg.sender,
            _baseToken,
            Types.VaultTransferType.Buy,
            azUsdAmount,
            azUsdAmount - amountAfterFee,
            outputLp,
            userLpBalances[_baseToken][round][msg.sender],
            azUsdBalances[_baseToken][round],
            lpSupply[_baseToken][round],
            alpPrice
        );
    }

    function sell(Currency _baseToken, uint256 alpTokenAmount, uint256 minAzUsdOut, uint256 deadline) public {
        sell(_baseToken, alpTokenAmount, minAzUsdOut, base.positionManager().getCurrentRound(_baseToken), deadline);
    }

    function sell(
        Currency _baseToken,
        uint256 alpTokenAmount,
        uint256 minAzUsdOut,
        uint256 round,
        uint256 deadline
    ) public nonReentrant {
        IPositionManager positionManager = base.positionManager();
        require(round <= positionManager.getCurrentRound(_baseToken), "Invalid round");
        require(block.timestamp < deadline, "Deadline exceeded");
        uint256 baseTokenLpId = baseTokenLpIds[_baseToken];
        if (baseTokenLpId == 0) {
            revert Error.PerpVaultNotInitialized(_baseToken);
        }
        if (block.timestamp < lastBuyAt[_baseToken][round][msg.sender] + coolDownDuration) {
            revert Error.InCoolDownDuration();
        }
        (uint256 alpPrice,) = getAlpPrice(_baseToken, round);
        Currency azUsd = base.currencyAzUsd();
        uint256 azUsdDecimals = azUsd.mustGetDecimals();
        uint256 azUsdAmount = (alpTokenAmount * alpPrice) / (10 ** azUsdDecimals);
        uint256 azUsdAmountAfterFee = (azUsdAmount * (Types.BASIS_POINT - feeRate)) / Types.BASIS_POINT;
        if (azUsdAmountAfterFee < minAzUsdOut) {
            revert Error.InsufficientOutputAmount();
        }

        positionManager.updateBorrowingRate(_baseToken, round);
        azUsd.transfer(msg.sender, azUsdAmountAfterFee);
        azUsdBalances[_baseToken][round] -= azUsdAmountAfterFee;
        feeBalances[_baseToken][round] += azUsdAmount - azUsdAmountAfterFee;

        _burn(msg.sender, baseTokenLpId, alpTokenAmount);
        lpSupply[_baseToken][round] -= alpTokenAmount;
        userLpBalances[_baseToken][round][msg.sender] -= alpTokenAmount;
        base.oracleManager().syncAdjustedPrice(_baseToken);

        emit BalanceUpdated(
            round,
            msg.sender,
            _baseToken,
            Types.VaultTransferType.Sell,
            azUsdAmount,
            azUsdAmount - azUsdAmountAfterFee,
            alpTokenAmount,
            userLpBalances[_baseToken][round][msg.sender],
            azUsdBalances[_baseToken][round],
            lpSupply[_baseToken][round],
            alpPrice
        );

        positionManager.triggerADLIfNeeded(_baseToken);
    }

    function transferIn(
        Currency _baseToken,
        uint256 round,
        Types.VaultTransferType transferType,
        uint256 amount
    ) public onlyPositionManager {
        if (
            transferType != Types.VaultTransferType.Profit && transferType != Types.VaultTransferType.BorrowFee
                && transferType != Types.VaultTransferType.PositionFee
        ) {
            revert Error.InvalidTransferType(transferType);
        }
        if (baseTokenLpIds[_baseToken] == 0) {
            revert Error.PerpVaultNotInitialized(_baseToken);
        }

        base.hayek().takeToken(base.currencyAzUsd(), msg.sender, address(this), amount);
        azUsdBalances[_baseToken][round] += amount;

        (uint256 alpPrice,) = getAlpPrice(_baseToken, round);
        emit BalanceUpdated(
            round,
            msg.sender,
            _baseToken,
            transferType,
            amount,
            0,
            0,
            0,
            azUsdBalances[_baseToken][round],
            lpSupply[_baseToken][round],
            alpPrice
        );
    }

    function transferOut(
        Currency _baseToken,
        uint256 round,
        Types.VaultTransferType transferType,
        uint256 amount
    ) public onlyPositionManager returns (int256) {
        if (transferType != Types.VaultTransferType.Loss) {
            revert Error.InvalidTransferType(transferType);
        }
        if (baseTokenLpIds[_baseToken] == 0) {
            revert Error.PerpVaultNotInitialized(_baseToken);
        }

        uint256 availableAmount = azUsdBalances[_baseToken][round] - minAzUsdAmount;
        if (amount > availableAmount) {
            amount = availableAmount;
        }
        base.currencyAzUsd().transfer(msg.sender, amount);
        azUsdBalances[_baseToken][round] -= amount;

        (uint256 alpPrice,) = getAlpPrice(_baseToken, round);
        emit BalanceUpdated(
            round,
            msg.sender,
            _baseToken,
            transferType,
            amount,
            0,
            0,
            0,
            lpSupply[_baseToken][round],
            azUsdBalances[_baseToken][round],
            alpPrice
        );
        return int256(amount);
    }

    function getAlpPrice(Currency _baseToken, uint256 round) public returns (uint256 alpPrice, uint256 aum) {
        uint256 alpId = baseTokenLpIds[_baseToken];
        uint256 totalSupply_ = lpSupply[_baseToken][round];
        if (totalSupply_ == 0) return (Types.USD, 0);

        uint256 azUsdBalance = azUsdBalances[_baseToken][round];
        int256 unrealizedPnl = base.positionManager().getGlobalUnrealizedPnl(_baseToken, round);
        if (unrealizedPnl > 0) {
            aum = unrealizedPnl.abs() > azUsdBalance ? 0 : azUsdBalance - unrealizedPnl.abs();
        } else {
            aum = azUsdBalance + unrealizedPnl.abs();
        }
        alpPrice = (aum * (10 ** decimals())) / totalSupply_;
        return (alpPrice, aum);
    }

    function getVaultId(
        Currency _baseToken
    ) public view returns (uint256) {
        return baseTokenLpIds[_baseToken];
    }
}
