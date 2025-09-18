// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBase } from "src/interfaces/IBase.sol";
import { Position } from "src/libraries/Position.sol";
import { Error } from "src/libraries/Error.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";
import { IPositionManager } from "src/interfaces/IPositionManager.sol";
import { ADLManager } from "src/libraries/ADLManager.sol";
import { Types } from "src/Types.sol";

contract PositionManager is IPositionManager, ReentrancyGuard, Pausable {
    using SafeCast for *;
    using SignedMath for int256;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Position for Types.Position;
    using Position for Types.Order;
    using Position for Types.PositionFees;
    using Position for Currency;
    using CurrencyLibraryExt for Currency;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using ADLManager for ADLManager.ADLStorage;

    string public constant name = "PositionManager";
    IBase public base;
    Types.PositionConfig public config;

    mapping(Currency => uint256) public currentRounds;
    mapping(address => uint256) public userPositionIds;
    mapping(bytes32 => Types.Position) public positions;
    mapping(address => EnumerableSet.Bytes32Set) private positionKeys;
    mapping(Currency => mapping(uint256 => uint256)) public borrowingUpdatedAt;
    mapping(Currency => mapping(uint256 => uint256)) public cumulativeBorrowingRates;

    ADLManager.ADLStorage private adlStorage;

    event UpdateBorrowingRate(Currency baseToken, uint256 round, uint256 borrowingRate);
    event PositionConfigUpdated(address owner, Types.PositionConfig config);
    event PositionUpdated(
        Types.Order order,
        Types.Position position,
        Types.Action action,
        uint256 markPrice,
        Types.PositionFees fees,
        int256 pnl,
        int256 vaultPnl,
        uint256 round
    );
    event GlobalPositionUpdated(Types.Position globalPosition, Types.Position oppositeGlobalPosition);
    event Liquidate(Types.Position position, uint256 markPrice, Types.PositionFees fees, int256 pnl, int256 vaultPnl);
    event FeeToReceiver(Currency baseToken, Types.FeeType feeType, uint256 amount, address receiver, uint256 round);
    event IncrementRound(Currency baseToken, uint256 round);

    constructor(IBase _base, Types.PositionConfig memory _config) {
        base = _base;
        config = _config;
        emit PositionConfigUpdated(msg.sender, config);
    }

    function increasePosition(
        Types.Order memory order
    ) external override nonReentrant whenNotPaused returns (bytes32 positionKey) {
        return _increasePosition(order, currentRounds[order.baseToken]);
    }

    function _increasePosition(Types.Order memory order, uint256 round) private returns (bytes32 positionKey) {
        if (!base.marketManager().perpetualEnabled(order.baseToken)) {
            revert Error.PerpetualDisabled(order.baseToken);
        }
        uint256 markPrice = base.oracleManager().syncAdjustedPrice(order.baseToken, order.isLong, true, order.sizeDelta);
        order.validateIncrease(config, markPrice);
        validateLiquidity(order.baseToken, order.isLong, order.sizeDelta, round);

        updateBorrowingRate(order.baseToken, round);
        base.hayek().takeToken(base.currencyAzUsd(), msg.sender, address(this), order.collateralDelta);
        (bytes32 globalKey, bytes32 oppositeGlobalKey) = order.getGlobalKeys(round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        uint256 share =
            global.share == 0 ? order.sizeDelta : (order.sizeDelta * global.share) / global.getEffectiveSize();

        if (global.size == 0 || oppositeGlobal.size == 0) {
            global.baseToken = order.baseToken;
            global.isLong = order.isLong;
            global.round = round;
            oppositeGlobal.baseToken = order.baseToken;
            oppositeGlobal.isLong = !order.isLong;
            oppositeGlobal.round = round;
        }
        global.updateGlobalPosition(order.sizeDelta, share, order.collateralDelta, 0, markPrice, true, round);

        Types.ADLInfo memory currentAdlInfo = adlStorage.getADLInfo(order.baseToken, order.isLong, round);

        uint256 id = userPositionIds[order.owner]++;
        positionKey = order.getNewPositionKey(id, round);
        Types.Position memory position = Types.Position({
            owner: order.owner,
            baseToken: order.baseToken,
            isLong: order.isLong,
            positionId: id,
            share: share,
            leverage: Position.getLeverage(order.sizeDelta, order.collateralDelta),
            collateral: order.collateralDelta,
            increasedAt: block.timestamp,
            increasedAtBlock: block.number,
            entryPrice: markPrice,
            size: order.sizeDelta,
            adlSize: 0,
            borrowRate: cumulativeBorrowingRates[order.baseToken][round],
            round: round,
            lastProcessedAdlIndex: currentAdlInfo.adlExecutionCount
        });

        position.validate(config);
        positionKeys[order.owner].add(positionKey);
        positions[positionKey] = position;

        adlStorage.triggerADLIfNeeded(positions, currentRounds, cumulativeBorrowingRates, base, order.baseToken);

        Types.PositionFees memory fees;
        emit PositionUpdated(order, position, Types.Action.Increase, markPrice, fees, 0, 0, round);
        emit GlobalPositionUpdated(global, oppositeGlobal);
        return positionKey;
    }

    function decreasePosition(
        Types.Order memory order
    ) external override nonReentrant whenNotPaused {
        _decreasePosition(order, currentRounds[order.baseToken]);
    }

    function decreasePositionInRound(Types.Order memory order, uint256 round) external nonReentrant whenNotPaused {
        if (round > currentRounds[order.baseToken]) {
            revert Error.InvalidRound(round, currentRounds[order.baseToken]);
        }

        _decreasePosition(order, round);
    }

    function _decreasePosition(Types.Order memory order, uint256 round) private {
        bytes32 positionKey = order.getPositionKey(round);
        adlStorage.settleAdlIfNeeded(positions, config, base, positionKey, 0);

        Types.Position storage position = positions[positionKey];
        uint256 markPrice = base.oracleManager().syncAdjustedPrice(order.baseToken, order.isLong, false, position.size);
        order.validateDecrease(markPrice);
        position.canOperate();

        updateBorrowingRate(order.baseToken, round);
        (bytes32 globalKey, bytes32 oppositeGlobalKey) = order.getGlobalKeys(round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        Types.PositionFees memory fees =
            position.getPositionFees(global, config, cumulativeBorrowingRates[order.baseToken][round]);

        (int256 userPnl,,) =
            Position.getUserPnL(position, global, markPrice, config.minPnLDuration, new Types.ADLExecution[](0));
        bool needLiquidation = position.checkLiquidation(userPnl, fees);
        if (needLiquidation) {
            revert Error.ShouldBeLiquidated(position, userPnl, fees, markPrice);
        }

        uint256 userSize = position.getSize(global);
        global.updateGlobalPosition(userSize, position.share, position.collateral, userPnl, markPrice, false, round);

        uint256 remainingCollateral = position.collateral;
        int256 vaultPnl;
        if (userPnl > 0) {
            remainingCollateral += uint256(userPnl);
            vaultPnl =
                base.perpVault().transferOut(order.baseToken, round, Types.VaultTransferType.Loss, uint256(userPnl));
        } else {
            remainingCollateral -= uint256(-userPnl);
            base.perpVault().transferIn(order.baseToken, round, Types.VaultTransferType.Profit, uint256(-userPnl));
        }

        (fees, remainingCollateral) =
            fees.processFees(config, base, Types.Action.Decrease, order.baseToken, remainingCollateral, round);
        base.currencyAzUsd().transfer(order.owner, remainingCollateral);

        adlStorage.triggerADLIfNeeded(positions, currentRounds, cumulativeBorrowingRates, base, order.baseToken);

        emit PositionUpdated(order, position, Types.Action.Decrease, markPrice, fees, userPnl, vaultPnl, round);
        emit GlobalPositionUpdated(global, oppositeGlobal);
        delete positions[positionKey];
        base.oracleManager().syncAdjustedPrice(order.baseToken);
        positionKeys[order.owner].remove(positionKey);
    }

    function marginCall(
        Types.Order memory order
    ) external override nonReentrant whenNotPaused {
        _marginCall(order, currentRounds[order.baseToken]);
    }

    function _marginCall(Types.Order memory order, uint256 round) private {
        if (!base.marketManager().perpetualEnabled(order.baseToken)) {
            revert Error.PerpetualDisabled(order.baseToken);
        }

        bytes32 positionKey = order.getPositionKey(round);
        adlStorage.settleAdlIfNeeded(positions, config, base, positionKey, 0);

        order.validateMarginCall(config);
        Types.Position storage position = positions[positionKey];
        position.canOperate();

        updateBorrowingRate(order.baseToken, round);
        (bytes32 globalKey, bytes32 oppositeGlobalKey) = order.getGlobalKeys(round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        Types.PositionFees memory fees =
            position.getPositionFees(global, config, cumulativeBorrowingRates[order.baseToken][round]);
        uint256 markPrice = base.oracleManager().syncAdjustedPrice(order.baseToken, order.isLong, true, 0);
        (int256 userPnl,,) =
            Position.getUserPnL(position, global, markPrice, config.minPnLDuration, new Types.ADLExecution[](0));
        if (position.checkLiquidation(userPnl, fees)) {
            revert Error.ShouldBeLiquidated(position, userPnl, fees, markPrice);
        }

        position.collateral += order.collateralDelta;
        base.hayek().takeToken(base.currencyAzUsd(), msg.sender, address(this), order.collateralDelta);
        (fees, position.collateral) =
            fees.processFees(config, base, Types.Action.MarginCall, order.baseToken, position.collateral, round);
        position.borrowRate = cumulativeBorrowingRates[order.baseToken][round];
        global.updateGlobalPosition(0, 0, order.collateralDelta, 0, markPrice, true, round);
        position.validate(config);

        adlStorage.triggerADLIfNeeded(positions, currentRounds, cumulativeBorrowingRates, base, order.baseToken);
        base.oracleManager().syncAdjustedPrice(order.baseToken);
        emit PositionUpdated(order, position, Types.Action.MarginCall, markPrice, fees, 0, 0, round);
        emit GlobalPositionUpdated(global, oppositeGlobal);
    }

    function reduceMargin(
        Types.Order memory order
    ) external override nonReentrant whenNotPaused {
        _reduceMargin(order, currentRounds[order.baseToken]);
    }

    function _reduceMargin(Types.Order memory order, uint256 round) private {
        if (!base.marketManager().perpetualEnabled(order.baseToken)) {
            revert Error.PerpetualDisabled(order.baseToken);
        }

        bytes32 positionKey = order.getPositionKey(round);
        adlStorage.settleAdlIfNeeded(positions, config, base, positionKey, 0);

        order.validateReduceMargin(config);
        Types.Position storage position = positions[positionKey];
        position.canOperate();

        updateBorrowingRate(order.baseToken, round);
        (bytes32 globalKey, bytes32 oppositeGlobalKey) = order.getGlobalKeys(round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        Types.PositionFees memory fees =
            position.getPositionFees(global, config, cumulativeBorrowingRates[order.baseToken][round]);
        uint256 markPrice = base.oracleManager().syncAdjustedPrice(order.baseToken, order.isLong, false, 0);
        (int256 userPnl,,) =
            Position.getUserPnL(position, global, markPrice, config.minPnLDuration, new Types.ADLExecution[](0));

        position.collateral -= order.collateralDelta;
        if (position.checkLiquidation(userPnl, fees)) {
            revert Error.ShouldBeLiquidated(position, userPnl, fees, markPrice);
        }

        (fees, position.collateral) =
            fees.processFees(config, base, Types.Action.ReduceMargin, order.baseToken, position.collateral, round);
        base.currencyAzUsd().transfer(order.owner, order.collateralDelta);
        position.borrowRate = cumulativeBorrowingRates[order.baseToken][round];
        global.updateGlobalPosition(0, 0, order.collateralDelta, 0, markPrice, false, round);
        position.validate(config);

        adlStorage.triggerADLIfNeeded(positions, currentRounds, cumulativeBorrowingRates, base, order.baseToken);
        emit PositionUpdated(order, position, Types.Action.ReduceMargin, markPrice, fees, 0, 0, round);
        emit GlobalPositionUpdated(global, oppositeGlobal);
        base.oracleManager().syncAdjustedPrice(order.baseToken);
    }

    function triggerADLIfNeeded(
        Currency baseToken
    ) public override {
        updateBorrowingRate(baseToken, currentRounds[baseToken]);
        adlStorage.triggerADLIfNeeded(positions, currentRounds, cumulativeBorrowingRates, base, baseToken);
    }

    function settleAdl(bytes32 positionKey, uint256 executeCount) external nonReentrant whenNotPaused {
        Types.Position storage position = positions[positionKey];
        position.canOperate();

        adlStorage.settleAdlIfNeeded(positions, config, base, positionKey, executeCount);

        if (positions[positionKey].size == 0) {
            if (positions[positionKey].collateral > 0) {
                base.currencyAzUsd().transfer(positions[positionKey].owner, positions[positionKey].collateral);
            }
            delete positions[positionKey];
            positionKeys[msg.sender].remove(positionKey);
        }
        base.oracleManager().syncAdjustedPrice(position.baseToken);

        (bytes32 globalKey, bytes32 oppositeGlobalKey) = position.getGlobalKeys(position.round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        emit GlobalPositionUpdated(global, oppositeGlobal);
    }

    function liquidate(address owner, Currency baseToken, bool isLong, uint256 positionId) external override {
        _liquidate(owner, baseToken, isLong, positionId, currentRounds[baseToken]);
    }

    function liquidateInRound(
        address owner,
        Currency baseToken,
        bool isLong,
        uint256 positionId,
        uint256 round
    ) external {
        if (round > currentRounds[baseToken]) {
            revert Error.InvalidRound(round, currentRounds[baseToken]);
        }
        _liquidate(owner, baseToken, isLong, positionId, round);
    }

    function _liquidate(address owner, Currency baseToken, bool isLong, uint256 positionId, uint256 round) private {
        bytes32 positionKey = Position._getPositionKey(owner, baseToken, isLong, positionId, round);
        adlStorage.settleAdlIfNeeded(positions, config, base, positionKey, 0);

        Types.Position memory position = positions[positionKey];
        position.canOperate();
        updateBorrowingRate(position.baseToken, round);

        uint256 markPrice =
            base.oracleManager().syncAdjustedPrice(position.baseToken, position.isLong, false, position.size);

        (bytes32 globalKey, bytes32 oppositeGlobalKey) = position.getGlobalKeys(round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        Types.PositionFees memory fees =
            position.getPositionFees(global, config, cumulativeBorrowingRates[position.baseToken][round]);
        (int256 userPnl,,) =
            Position.getUserPnL(position, global, markPrice, config.minPnLDuration, new Types.ADLExecution[](0));
        if (!position.checkLiquidation(userPnl, fees)) {
            revert Error.ShouldNotBeLiquidated(position, userPnl, fees, markPrice);
        }

        uint256 remainingCollateral = position.collateral;
        uint256 vaultPnl;
        if (userPnl > 0) {
            remainingCollateral += userPnl.abs();
        } else {
            vaultPnl = remainingCollateral > userPnl.abs() ? userPnl.abs() : remainingCollateral;
            base.perpVault().transferIn(position.baseToken, round, Types.VaultTransferType.Profit, vaultPnl);
            remainingCollateral -= vaultPnl;
        }
        (fees, remainingCollateral) =
            fees.processFees(config, base, Types.Action.Liquidation, position.baseToken, remainingCollateral, round);

        uint256 userSize = position.getSize(global);
        int256 settlementPnl = userPnl > 0 ? userPnl : -int256(vaultPnl);
        global.updateGlobalPosition(
            userSize, position.share, position.collateral, settlementPnl, markPrice, false, round
        );
        triggerADLIfNeeded(baseToken);
        emit Liquidate(position, markPrice, fees, settlementPnl, int256(vaultPnl));
        emit GlobalPositionUpdated(global, oppositeGlobal);
        delete positions[positionKey];
        positionKeys[position.owner].remove(positionKey);
        base.oracleManager().syncAdjustedPrice(baseToken);
    }

    function updateBorrowingRate(Currency baseToken, uint256 round) public {
        if (borrowingUpdatedAt[baseToken][round] == 0) {
            borrowingUpdatedAt[baseToken][round] =
                (block.timestamp / config.borrowingInterval) * config.borrowingInterval;
            emit UpdateBorrowingRate(baseToken, round, cumulativeBorrowingRates[baseToken][round]);
            return;
        }

        if (borrowingUpdatedAt[baseToken][round] + config.borrowingInterval > block.timestamp) return;

        uint256 borrowingRateDelta = getBorrowingRateDelta(baseToken, round);
        cumulativeBorrowingRates[baseToken][round] += borrowingRateDelta;
        borrowingUpdatedAt[baseToken][round] = (block.timestamp / config.borrowingInterval) * config.borrowingInterval;
        emit UpdateBorrowingRate(baseToken, round, cumulativeBorrowingRates[baseToken][round]);
    }

    function getBorrowingRateDelta(Currency baseToken, uint256 round) public view returns (uint256) {
        if (borrowingUpdatedAt[baseToken][round] + config.borrowingInterval > block.timestamp) return 0;

        uint256 azUsdBalance = base.perpVault().azUsdBalances(baseToken, round);
        if (azUsdBalance == 0) return 0;

        uint256 intervals = (block.timestamp - borrowingUpdatedAt[baseToken][round]) / config.borrowingInterval;
        (, uint256 longOI, uint256 shortOI) = getMarketOI(baseToken, round);
        return (config.borrowingRateE6 * (longOI + shortOI) * intervals) / azUsdBalance;
    }

    function getNextBorrowingRate(
        Currency[] calldata baseTokens
    ) public view returns (uint256[] memory, uint256) {
        uint256 round;
        uint256[] memory nextBorrowingRates = new uint256[](baseTokens.length);
        for (uint256 i = 0; i < baseTokens.length; i++) {
            round = currentRounds[baseTokens[i]];
            nextBorrowingRates[i] =
                cumulativeBorrowingRates[baseTokens[i]][round] + getBorrowingRateDelta(baseTokens[i], round);
        }
        return (nextBorrowingRates, block.timestamp);
    }

    function getPosition(
        bytes32 positionKey
    ) public view override returns (Types.Position memory) {
        return positions[positionKey];
    }

    function getUserPositions(
        address user
    ) public view returns (Types.Position[] memory) {
        bytes32[] memory positionKeys_ = positionKeys[user].values();
        Types.Position[] memory positions_ = new Types.Position[](positionKeys_.length);
        for (uint256 i = 0; i < positionKeys_.length; i++) {
            positions_[i] = positions[positionKeys_[i]];
        }
        return positions_;
    }

    function getCurrentRound(
        Currency baseToken
    ) external view returns (uint256) {
        return currentRounds[baseToken];
    }

    function getPositionKeys(
        address user
    ) external view returns (bytes32[] memory) {
        return positionKeys[user].values();
    }

    function getGlobalUnrealizedPnl(Currency baseToken, uint256 round) public override returns (int256) {
        bytes32 longPositionKey = Position.getGlobalKey(baseToken, true, round);
        bytes32 shortPositionKey = Position.getGlobalKey(baseToken, false, round);
        Types.Position memory longPosition = positions[longPositionKey];
        Types.Position memory shortPosition = positions[shortPositionKey];
        uint256 markPrice = base.oracleManager().syncAdjustedPrice(baseToken);
        int256 pnl = longPosition.getGlobalPnL(markPrice, round) + shortPosition.getGlobalPnL(markPrice, round);
        (Types.ADLInfo memory longAdlInfo, Types.ADLInfo memory shortAdlInfo) = getAdlStorage(baseToken, round);
        pnl += (longAdlInfo.globalLongPnl + shortAdlInfo.globalShortPnl);
        return pnl;
    }

    function incrementRound(
        Currency baseToken
    ) external returns (uint256) {
        require(msg.sender == address(base.marketManager()), "PositionManager: Only marketManager can increment round");
        require(!base.marketManager().perpetualEnabled(baseToken), "PositionManager: Perpetual is enabled");
        currentRounds[baseToken]++;
        emit IncrementRound(baseToken, currentRounds[baseToken]);
        return currentRounds[baseToken];
    }

    function getMarketOI(
        Currency baseToken,
        uint256 round
    ) public view returns (uint256 netOI, uint256 longOI, uint256 shortOI) {
        longOI = positions[Position.getGlobalKey(baseToken, true, round)].getEffectiveSize();
        shortOI = positions[Position.getGlobalKey(baseToken, false, round)].getEffectiveSize();
        netOI = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        return (netOI, longOI, shortOI);
    }

    function getAvailableLiquidity(
        Currency baseToken,
        uint256 round
    ) public view returns (uint256 longAvailableLiq, uint256 shortAvailableLiq, uint256 totalLiquidity) {
        (uint256 netOI, uint256 longOI, uint256 shortOI) = getMarketOI(baseToken, round);
        totalLiquidity = base.perpVault().azUsdBalances(baseToken, round);
        if (netOI > totalLiquidity) {
            return (0, 0, totalLiquidity);
        }
        return longOI > shortOI
            ? (totalLiquidity - netOI, totalLiquidity + netOI, totalLiquidity)
            : (totalLiquidity + netOI, totalLiquidity - netOI, totalLiquidity);
    }

    function validateLiquidity(Currency baseToken, bool isLong, uint256 sizeDelta, uint256 round) public view {
        (uint256 longAvailableLiq, uint256 shortAvailableLiq,) = getAvailableLiquidity(baseToken, round);
        if (isLong && longAvailableLiq < sizeDelta) {
            revert Error.InsufficientLiquidity();
        }
        if (!isLong && shortAvailableLiq < sizeDelta) {
            revert Error.InsufficientLiquidity();
        }
    }

    function getADLInfo(Currency baseToken, bool isLong, uint256 round) external view returns (Types.ADLInfo memory) {
        return adlStorage.getADLInfo(baseToken, isLong, round);
    }

    function getAdlStorage(
        Currency baseToken,
        uint256 round
    ) public view returns (Types.ADLInfo memory longAdlInfo, Types.ADLInfo memory shortAdlInfo) {
        longAdlInfo = adlStorage.getADLInfo(baseToken, true, round);
        shortAdlInfo = adlStorage.getADLInfo(baseToken, false, round);
    }

    function getADLExecutions(
        Currency baseToken,
        bool isLong,
        uint256 round,
        uint256 fromIndex,
        uint256 toIndex
    ) external view returns (Types.ADLExecution[] memory) {
        return ADLManager.getADLExecutions(adlStorage, baseToken, isLong, round, fromIndex, toIndex);
    }
}
