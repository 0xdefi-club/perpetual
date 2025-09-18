// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBase } from "src/interfaces/IBase.sol";
import { IMarketManager } from "src/interfaces/IMarketManager.sol";
import { Position } from "src/libraries/Position.sol";
import { Types } from "src/Types.sol";

library ADLManager {
    using SafeCast for *;
    using SignedMath for int256;
    using Position for Types.Position;
    using Position for Types.PositionFees;

    uint256 public constant ADL_REDUCTION_RATIO_E4 = 1000;
    uint256 public constant MAX_ADL_EXECUTION_COUNT = 100;

    event ADLTriggered(
        Currency baseToken,
        int256 adlAmount,
        bool isLong,
        uint256 markPrice,
        uint256 round,
        Types.ADLInfo adlInfo,
        Types.ADLExecution adlExecution
    );
    event ADLSettled(
        Types.Position position,
        Types.ADLInfo adlInfo,
        uint256 adlSize,
        int256 adlPnl,
        uint256 borrowingFee,
        uint256 positionFee
    );
    event GlobalPositionUpdated(Types.Position globalPosition, Types.Position oppositeGlobalPosition);

    struct ADLStorage {
        mapping(Currency => mapping(bool => mapping(uint256 => Types.ADLInfo))) adlInfos;
        mapping(Currency => mapping(bool => mapping(uint256 => mapping(uint256 => Types.ADLExecution)))) adlExecutions;
    }

    function calculateActualADLSize(
        uint256 minAdlAmount,
        uint256 globalEffectiveSize
    ) internal pure returns (uint256 actualADLSize, uint256 executionCount) {
        if (globalEffectiveSize == 0 || minAdlAmount == 0) {
            return (0, 0);
        }

        if (minAdlAmount >= globalEffectiveSize) {
            return (globalEffectiveSize, 1);
        }

        uint256 remainingSize = globalEffectiveSize;
        uint256 currentADLSize;

        while (actualADLSize < minAdlAmount && remainingSize > 0) {
            currentADLSize = (remainingSize * ADL_REDUCTION_RATIO_E4) / 10_000;
            actualADLSize += currentADLSize;
            remainingSize -= currentADLSize;
            executionCount++;

            if (executionCount >= MAX_ADL_EXECUTION_COUNT) {
                actualADLSize = globalEffectiveSize;
                break;
            }
        }
    }

    function triggerADLIfNeeded(
        ADLStorage storage adlStorage,
        mapping(bytes32 => Types.Position) storage positions,
        mapping(Currency => uint256) storage currentRounds,
        mapping(Currency => mapping(uint256 => uint256)) storage cumulativeBorrowingRates,
        IBase base,
        Currency baseToken
    ) external {
        IMarketManager marketManager = base.marketManager();
        uint256 round = currentRounds[baseToken];
        bytes32 longKey = Position.getGlobalKey(baseToken, true, round);
        bytes32 shortKey = Position.getGlobalKey(baseToken, false, round);

        Types.Position storage longPosition = positions[longKey];
        Types.Position storage shortPosition = positions[shortKey];

        uint256 vaultBalance = base.perpVault().azUsdBalances(baseToken, round);

        (bool needADL, int256 riskDelta, bool closeMarket) =
            Position.checkADLForLiquidity(longPosition, shortPosition, vaultBalance);

        bool perpetualEnabled = marketManager.perpetualEnabled(baseToken);
        if (!perpetualEnabled || closeMarket) {
            executeADLAndCloseMarket(adlStorage, positions, cumulativeBorrowingRates, base, baseToken, round);
        } else if (needADL) {
            executeADL(adlStorage, positions, cumulativeBorrowingRates, base, baseToken, riskDelta, round);
        }
    }

    function executeADLAndCloseMarket(
        ADLStorage storage adlStorage,
        mapping(bytes32 => Types.Position) storage positions,
        mapping(Currency => mapping(uint256 => uint256)) storage cumulativeBorrowingRates,
        IBase base,
        Currency baseToken,
        uint256 round
    ) internal {
        uint256 markPrice;
        IMarketManager marketManager = base.marketManager();

        bytes32 longGlobalKey = Position.getGlobalKey(baseToken, true, round);
        bytes32 shortGlobalKey = Position.getGlobalKey(baseToken, false, round);
        Types.Position storage longGlobal = positions[longGlobalKey];
        Types.Position storage shortGlobal = positions[shortGlobalKey];
        Types.ADLInfo storage longAdlInfo = adlStorage.adlInfos[baseToken][true][round];
        Types.ADLInfo storage shortAdlInfo = adlStorage.adlInfos[baseToken][false][round];

        if (longGlobal.size == 0 && shortGlobal.size == 0) return;
        markPrice = base.oracleManager().syncAdjustedPrice(baseToken, 0, 0);
        int256 pnlDelta = 0;

        if (longGlobal.size > 0) {
            uint256 longAdlSize = longGlobal.getEffectiveSize();
            longGlobal.adlSize = longGlobal.size;
            longAdlInfo.adlExecutionCount++;
            adlStorage.adlExecutions[baseToken][true][round][longAdlInfo.adlExecutionCount] = Types.ADLExecution({
                adlPrice: markPrice,
                blockNumber: block.number,
                timestamp: block.timestamp,
                cumulativeBorrowingRates: cumulativeBorrowingRates[baseToken][round],
                isCloseMarket: true
            });

            if (longGlobal.entryPrice > 0) {
                pnlDelta = Position.getPnL(longAdlSize, longGlobal.entryPrice, markPrice, true);
                updateGlobalPnlAndSyncPrice(longAdlInfo, true, pnlDelta, base, baseToken);
            }
            emit ADLTriggered(
                baseToken,
                int256(longAdlSize),
                true,
                markPrice,
                round,
                longAdlInfo,
                adlStorage.adlExecutions[baseToken][true][round][longAdlInfo.adlExecutionCount]
            );
        }
        if (shortGlobal.size > 0) {
            uint256 shortAdlSize = shortGlobal.getEffectiveSize();
            shortGlobal.adlSize = shortGlobal.size;
            shortAdlInfo.adlExecutionCount++;
            adlStorage.adlExecutions[baseToken][false][round][shortAdlInfo.adlExecutionCount] = Types.ADLExecution({
                adlPrice: markPrice,
                blockNumber: block.number,
                timestamp: block.timestamp,
                cumulativeBorrowingRates: cumulativeBorrowingRates[baseToken][round],
                isCloseMarket: true
            });

            if (shortGlobal.entryPrice > 0) {
                pnlDelta = Position.getPnL(shortAdlSize, shortGlobal.entryPrice, markPrice, false);
                updateGlobalPnlAndSyncPrice(shortAdlInfo, false, pnlDelta, base, baseToken);
            }
            emit ADLTriggered(
                baseToken,
                int256(shortAdlSize),
                false,
                markPrice,
                round,
                shortAdlInfo,
                adlStorage.adlExecutions[baseToken][false][round][shortAdlInfo.adlExecutionCount]
            );
        }
        emit GlobalPositionUpdated(longGlobal, shortGlobal);

        if (marketManager.perpetualEnabled(baseToken)) {
            marketManager.disablePerpetual(baseToken);
        }
        return;
    }

    function executeADL(
        ADLStorage storage adlStorage,
        mapping(bytes32 => Types.Position) storage positions,
        mapping(Currency => mapping(uint256 => uint256)) storage cumulativeBorrowingRates,
        IBase base,
        Currency baseToken,
        int256 adlAmount,
        uint256 round
    ) internal {
        if (adlAmount == 0) return;

        uint256 markPrice;
        IMarketManager marketManager = base.marketManager();

        bool isLong = adlAmount > 0;
        bytes32 globalKey = Position.getGlobalKey(baseToken, isLong, round);
        bytes32 oppositeGlobalKey = Position.getGlobalKey(baseToken, !isLong, round);
        Types.Position storage global = positions[globalKey];
        Types.Position storage oppositeGlobal = positions[oppositeGlobalKey];
        Types.ADLInfo storage adlInfo = adlStorage.adlInfos[baseToken][isLong][round];

        uint256 globalEffectiveSize = global.getEffectiveSize();
        (uint256 actualADLSize, uint256 executionCount) = calculateActualADLSize(adlAmount.abs(), globalEffectiveSize);
        markPrice = base.oracleManager().syncAdjustedPrice(baseToken, isLong, false, actualADLSize);

        Position.validateADLAmount(int256(actualADLSize), global);
        global.adlSize += actualADLSize;

        for (uint256 i = 0; i < executionCount; i++) {
            adlInfo.adlExecutionCount++;
            adlStorage.adlExecutions[baseToken][isLong][round][adlInfo.adlExecutionCount] = Types.ADLExecution({
                adlPrice: markPrice,
                blockNumber: block.number,
                timestamp: block.timestamp,
                cumulativeBorrowingRates: cumulativeBorrowingRates[baseToken][round],
                isCloseMarket: false
            });
        }

        if (global.entryPrice > 0) {
            int256 pnlDelta = Position.getPnL(actualADLSize, global.entryPrice, markPrice, isLong);
            updateGlobalPnlAndSyncPrice(adlInfo, isLong, pnlDelta, base, baseToken);
        }

        if (global.size == global.adlSize) {
            if (marketManager.perpetualEnabled(baseToken)) {
                marketManager.disablePerpetual(baseToken);
            }
        }

        emit ADLTriggered(
            baseToken,
            int256(actualADLSize),
            isLong,
            markPrice,
            round,
            adlInfo,
            adlStorage.adlExecutions[baseToken][isLong][round][adlInfo.adlExecutionCount]
        );
        emit GlobalPositionUpdated(global, oppositeGlobal);
    }

    function settleAdlIfNeeded(
        ADLStorage storage adlStorage,
        mapping(bytes32 => Types.Position) storage positions,
        Types.PositionConfig memory config,
        IBase base,
        bytes32 positionKey,
        uint256 executeCount
    ) external {
        Types.Position storage position = positions[positionKey];
        if (position.owner == address(0)) {
            return;
        }

        bytes32 globalKey = Position.getGlobalKey(position.baseToken, position.isLong, position.round);
        Types.Position storage global = positions[globalKey];
        Types.ADLInfo storage adlInfo = adlStorage.adlInfos[position.baseToken][position.isLong][position.round];

        uint256 targetIndex = executeCount == 0
            ? adlInfo.adlExecutionCount
            : Math.min(position.lastProcessedAdlIndex + executeCount, adlInfo.adlExecutionCount);

        Types.ADLExecution[] memory executionsToSettle = getADLExecutions(
            adlStorage, position.baseToken, position.isLong, position.round, position.lastProcessedAdlIndex, targetIndex
        );

        (, int256 adlPnl, uint256 adlSettledAmount) =
            Position.getUserPnL(position, global, 1, config.minPnLDuration, executionsToSettle);

        if (adlSettledAmount == 0) {
            return;
        }

        int256 positionCollateralChange;
        uint256 remainingCollateral = position.collateral;
        uint256 round = position.round;
        if (adlPnl > 0) {
            uint256 profitAmount = uint256(adlPnl);
            base.perpVault().transferOut(position.baseToken, round, Types.VaultTransferType.Loss, profitAmount);
            remainingCollateral += profitAmount;
        } else {
            uint256 lossAmount = uint256(-adlPnl);
            if (remainingCollateral >= lossAmount) {
                remainingCollateral -= lossAmount;
                base.perpVault().transferIn(position.baseToken, round, Types.VaultTransferType.Profit, lossAmount);
            } else {
                uint256 actualLossAmount = remainingCollateral;
                base.perpVault().transferIn(position.baseToken, round, Types.VaultTransferType.Profit, actualLossAmount);
                remainingCollateral = 0;
            }
        }

        Types.PositionFees memory adlFees = Position.getAdlSettledFees(position, config, executionsToSettle);
        (adlFees, remainingCollateral) =
            adlFees.processFees(config, base, Types.Action.ADL, position.baseToken, remainingCollateral, round);
        positionCollateralChange = int256(remainingCollateral) - int256(position.collateral);
        position.collateral = remainingCollateral;

        updateGlobalPnlAndSyncPrice(adlInfo, position.isLong, -adlPnl, base, position.baseToken);

        position.lastProcessedAdlIndex = targetIndex;

        Position.processADLSettlement(position, global, adlSettledAmount, positionCollateralChange);

        emit ADLSettled(position, adlInfo, adlSettledAmount, adlPnl, adlFees.borrowingFee, adlFees.positionFee);
    }

    function getADLExecutions(
        ADLStorage storage adlStorage,
        Currency baseToken,
        bool isLong,
        uint256 round,
        uint256 fromIndex,
        uint256 toIndex
    ) internal view returns (Types.ADLExecution[] memory) {
        if (toIndex <= fromIndex) {
            return new Types.ADLExecution[](0);
        }
        uint256 count = toIndex - fromIndex;
        Types.ADLExecution[] memory executions = new Types.ADLExecution[](count);
        for (uint256 i = 0; i < count; i++) {
            executions[i] = adlStorage.adlExecutions[baseToken][isLong][round][fromIndex + i + 1];
        }
        return executions;
    }

    function updateGlobalPnlAndSyncPrice(
        Types.ADLInfo storage adlInfo,
        bool isLong,
        int256 pnlDelta,
        IBase base,
        Currency baseToken
    ) internal {
        if (isLong) {
            adlInfo.globalLongPnl += pnlDelta;
        } else {
            adlInfo.globalShortPnl += pnlDelta;
        }
        base.oracleManager().syncAdjustedPrice(baseToken);
    }

    function getADLInfo(
        ADLStorage storage adlStorage,
        Currency baseToken,
        bool isLong,
        uint256 round
    ) external view returns (Types.ADLInfo memory) {
        return adlStorage.adlInfos[baseToken][isLong][round];
    }
}
