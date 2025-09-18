// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IBase } from "src/interfaces/IBase.sol";
import { Error } from "src/libraries/Error.sol";
import { Types } from "src/Types.sol";
import { ADLManager } from "src/libraries/ADLManager.sol";

library Position {
    using SafeCast for *;
    using SignedMath for int256;
    using EnumerableSet for EnumerableSet.AddressSet;

    event FeeToReceiver(Currency baseToken, Types.FeeType feeType, uint256 amount, address receiver);

    function getPositionKey(Types.Order memory order, uint256 round) internal pure returns (bytes32) {
        return _getPositionKey(order.owner, order.baseToken, order.isLong, order.positionId, round);
    }

    function getGlobalKey(Types.Order memory order, uint256 round) public pure returns (bytes32) {
        return _getPositionKey(address(0), order.baseToken, order.isLong, uint256(0), round);
    }

    function getGlobalKey(Currency base, bool isLong, uint256 round) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(address(0), base, isLong, uint256(0), round));
    }

    function getGlobalKeys(
        Types.Order memory order,
        uint256 round
    ) public pure returns (bytes32 currentGlobalKey, bytes32 oppositeGlobalKey) {
        return (
            _getPositionKey(address(0), order.baseToken, order.isLong, uint256(0), round),
            _getPositionKey(address(0), order.baseToken, !order.isLong, uint256(0), round)
        );
    }

    function getGlobalKeys(
        Types.Position memory position,
        uint256 round
    ) public pure returns (bytes32 currentGlobalKey, bytes32 oppositeGlobalKey) {
        return (
            getGlobalKey(position.baseToken, position.isLong, round),
            getGlobalKey(position.baseToken, !position.isLong, round)
        );
    }

    function getNewPositionKey(
        Types.Order memory order,
        uint256 positionId,
        uint256 round
    ) internal pure returns (bytes32) {
        return _getPositionKey(order.owner, order.baseToken, order.isLong, positionId, round);
    }

    function _getPositionKey(
        address owner,
        Currency baseToken,
        bool isLong,
        uint256 positionId,
        uint256 round
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, baseToken, isLong, positionId, round));
    }

    function getPositionKey(Types.Position memory position, uint256 round) internal pure returns (bytes32) {
        return _getPositionKey(position.owner, position.baseToken, position.isLong, position.positionId, round);
    }

    function getEffectiveSize(
        Types.Position memory position
    ) internal pure returns (uint256) {
        return position.size - position.adlSize;
    }

    function getSize(Types.Position memory user, Types.Position memory global) internal pure returns (uint256) {
        if (global.share == 0) {
            return 0;
        }
        return FullMath.mulDiv(getEffectiveSize(global), user.share, global.share);
    }

    function calculatePnL(
        Types.Position memory position,
        Types.Position memory global,
        uint256 markPrice,
        bool isUserPosition
    ) public pure returns (int256 signedPnL) {
        if (markPrice == 0 || position.entryPrice == 0) {
            return 0;
        }

        uint256 effectiveSize;

        if (isUserPosition) {
            if (global.share == 0 || position.share == 0) {
                return 0;
            }
            effectiveSize = getSize(position, global);
            if (effectiveSize == 0) {
                return 0;
            }
        } else {
            if (position.size == 0) {
                return 0;
            }
            effectiveSize = getEffectiveSize(position);
        }

        return getPnL(effectiveSize, position.entryPrice, markPrice, position.isLong);
    }

    function getPnL(
        uint256 size,
        uint256 entryPrice,
        uint256 markPrice,
        bool isLong
    ) public pure returns (int256 PnL) {
        if (markPrice == 0 || entryPrice == 0 || size == 0) {
            return 0;
        }

        bool hasProfit = isLong ? markPrice > entryPrice : markPrice < entryPrice;
        uint256 priceDelta = entryPrice > markPrice ? entryPrice - markPrice : markPrice - entryPrice;
        uint256 absPnL = FullMath.mulDiv(size, priceDelta, entryPrice);
        return hasProfit ? int256(absPnL) : -int256(absPnL);
    }

    function getGlobalPnL(
        Types.Position memory position,
        uint256 markPrice,
        uint256 round
    ) public pure returns (int256) {
        return calculatePnL(
            position,
            Types.Position(address(0), Currency.wrap(address(0)), false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, round, 0),
            markPrice,
            false
        );
    }

    function getUserPnL(
        Types.Position memory user,
        Types.Position memory global,
        uint256 markPrice,
        uint256 minPnLDuration,
        Types.ADLExecution[] memory executionsToSettle
    ) internal view returns (int256 remainingPnl, int256 adlPnl, uint256 adlSettledAmount) {
        bool needSettleADL = executionsToSettle.length > 0;

        if (needSettleADL) {
            uint256 originalSize = user.size;
            uint256 currentSize = originalSize;
            int256 totalAdlPnlAccumulated = 0;

            for (uint256 i = 0; i < executionsToSettle.length; i++) {
                Types.ADLExecution memory execution = executionsToSettle[i];
                uint256 adlSizeForExecution;

                if (execution.isCloseMarket) {
                    adlSizeForExecution = currentSize;
                } else {
                    adlSizeForExecution = (currentSize * ADLManager.ADL_REDUCTION_RATIO_E4) / Types.BASIS_POINT;
                }

                if (adlSizeForExecution > 0 && user.entryPrice > 0) {
                    int256 stepPnl = getPnL(adlSizeForExecution, user.entryPrice, execution.adlPrice, user.isLong);
                    totalAdlPnlAccumulated += stepPnl;
                    currentSize -= adlSizeForExecution;
                    adlSettledAmount += adlSizeForExecution;
                }
            }

            adlPnl = totalAdlPnlAccumulated;
            uint256 remainingSize = originalSize > adlSettledAmount ? originalSize - adlSettledAmount : 0;

            if (remainingSize > 0) {
                remainingPnl = getPnL(remainingSize, user.entryPrice, markPrice, user.isLong);
            } else {
                remainingPnl = 0;
            }
        } else {
            remainingPnl = calculatePnL(user, global, markPrice, true);
            adlPnl = 0;
            adlSettledAmount = 0;
        }

        if (block.timestamp < user.increasedAt + minPnLDuration && (remainingPnl + adlPnl) > 0) {
            remainingPnl = 0;
            adlPnl = 0;
        }
    }

    function updateGlobalPosition(
        Types.Position storage global,
        uint256 sizeDelta,
        uint256 share,
        uint256 collateralDelta,
        int256 pnlDelta,
        uint256 price,
        bool increase,
        uint256 round
    ) external {
        global.entryPrice = getNextEntryPrice(global, price, sizeDelta, pnlDelta, increase, round);
        if (increase) {
            global.size += sizeDelta;
            global.share += share;
            global.collateral += collateralDelta;
            global.increasedAtBlock = block.number;
        } else {
            global.size -= sizeDelta;
            global.share -= share;
            global.collateral -= collateralDelta;
        }
    }

    function getLeverage(uint256 size, uint256 collateral) internal pure returns (uint256) {
        return (size * Types.BASIS_POINT) / collateral;
    }

    function adlGlobalSize(Types.Position memory global, uint256 adlSizeDelta) internal pure {
        global.adlSize += adlSizeDelta;
    }

    function canOperate(
        Types.Position memory position
    ) internal view {
        if (position.owner == address(0)) {
            revert Error.PositionNotExist(position);
        }
        if (position.increasedAtBlock == block.number) {
            revert Error.CanNotOperate(position);
        }
        if (position.increasedAt == block.timestamp) {
            revert Error.CanNotOperate(position);
        }
    }

    function validate(
        Types.Position memory position,
        Types.PositionConfig memory config
    ) internal pure returns (bool) {
        if (position.collateral < config.minCollateral) {
            revert Error.InvalidCollateral(position.collateral, config.minCollateral);
        }

        uint256 leverageBps = getLeverage(position.size, position.collateral);

        if (leverageBps < config.minLeverage || leverageBps > config.maxLeverage) {
            revert Error.InvalidLeverage(leverageBps, config.minLeverage, config.maxLeverage);
        }

        return true;
    }

    function validateTriggerPrice(Types.Order memory order, uint256 markPrice) internal pure {
        if (order.triggerPrice == 0) {
            revert Error.ZeroValue("triggerPrice");
        }
        bool _isBuy = order.action == Types.Action.Increase ? order.isLong : !order.isLong;
        uint256 minPrice = order.triggerPrice;
        uint256 maxPrice = order.triggerPrice;

        if (_isBuy) {
            maxPrice = (order.triggerPrice * (order.slippage + Types.BASIS_POINT)) / Types.BASIS_POINT;
        } else {
            minPrice = (order.triggerPrice * (Types.BASIS_POINT - order.slippage)) / Types.BASIS_POINT;
        }
        if (minPrice > maxPrice) minPrice = maxPrice;
        bool canExecute = order.isTriggerAbove ? markPrice >= minPrice : markPrice <= maxPrice;
        if (!canExecute) {
            revert Error.InvalidTriggerPrice(order.triggerPrice, markPrice);
        }
    }

    function validateIncrease(
        Types.Order memory order,
        Types.PositionConfig memory config,
        uint256 markPrice
    ) internal view {
        if (order.collateralDelta < config.minCollateral) {
            revert Error.InvalidCollateral(order.collateralDelta, config.minCollateral);
        }
        if (order.sizeDelta == 0) {
            revert Error.ZeroValue("sizeDelta");
        }
        if (order.deadline < block.timestamp) {
            revert Error.InvalidDeadline(order.deadline, block.timestamp);
        }
        validateTriggerPrice(order, markPrice);
    }

    function validateDecrease(Types.Order memory order, uint256 markPrice) internal view {
        if (msg.sender != order.owner) {
            revert Error.NotOwner(msg.sender, order.owner);
        }
        if (order.deadline < block.timestamp) {
            revert Error.InvalidDeadline(order.deadline, block.timestamp);
        }
        validateTriggerPrice(order, markPrice);
    }

    function validateMarginCall(Types.Order memory order, Types.PositionConfig memory config) internal view {
        if (msg.sender != order.owner) {
            revert Error.NotOwner(msg.sender, order.owner);
        }

        if (order.collateralDelta < config.minCollateral) {
            revert Error.InvalidCollateral(order.collateralDelta, config.minCollateral);
        }
        if (order.deadline < block.timestamp) {
            revert Error.InvalidDeadline(order.deadline, block.timestamp);
        }
    }

    function validateReduceMargin(Types.Order memory order, Types.PositionConfig memory config) internal view {
        if (msg.sender != order.owner) {
            revert Error.NotOwner(msg.sender, order.owner);
        }

        if (order.collateralDelta < config.minCollateral) {
            revert Error.InvalidCollateral(order.collateralDelta, config.minCollateral);
        }
        if (order.deadline < block.timestamp) {
            revert Error.InvalidDeadline(order.deadline, block.timestamp);
        }
    }

    function getNextEntryPrice(
        Types.Position memory position,
        uint256 markPrice,
        uint256 sizeDelta,
        int256 pnlDelta,
        bool increase,
        uint256 round
    ) public pure returns (uint256) {
        if (position.size == 0) {
            return markPrice;
        }

        if (sizeDelta == 0) {
            return position.entryPrice;
        }

        uint256 nextSize = getEffectiveSize(position);
        int256 signedPnL = getGlobalPnL(position, markPrice, round);
        if (!increase) {
            signedPnL -= pnlDelta;
            if (signedPnL < 0 && uint256(-signedPnL) > position.collateral) {
                signedPnL = -int256(position.collateral);
            }
        }
        bool hasProfit = signedPnL >= 0;
        uint256 absPnL = signedPnL >= 0 ? uint256(signedPnL) : uint256(-signedPnL);
        nextSize = increase ? nextSize + sizeDelta : nextSize - sizeDelta;
        if (nextSize == 0) {
            return 0;
        }
        uint256 denominator;
        if (position.isLong) {
            denominator = hasProfit ? nextSize + absPnL : nextSize - absPnL;
        } else {
            denominator = hasProfit ? nextSize - absPnL : nextSize + absPnL;
        }

        if (denominator == 0) {
            return 0;
        }
        return FullMath.mulDiv(markPrice, nextSize, denominator);
    }

    function getPositionFees(
        Types.Position memory position,
        Types.Position memory global,
        Types.PositionConfig memory config,
        uint256 latestBorrowingRate
    ) internal pure returns (Types.PositionFees memory fees) {
        uint256 size = getSize(position, global);
        uint256 diffRate = latestBorrowingRate > position.borrowRate ? latestBorrowingRate - position.borrowRate : 0;
        fees.borrowingFee = (size * diffRate) / Types.BORROWING_RATE_PRECISION;
        fees.liquidationFee = (size * config.liquidationFeeRateE4) / Types.BASIS_POINT;
        fees.positionFee = (size * config.positionFeeRateE4) / Types.BASIS_POINT;
        fees.totalFee = fees.borrowingFee + fees.liquidationFee + fees.positionFee;
        return fees;
    }

    function getAdlSettledFees(
        Types.Position memory position,
        Types.PositionConfig memory config,
        Types.ADLExecution[] memory executionsToSettle
    ) external pure returns (Types.PositionFees memory fees) {
        if (executionsToSettle.length == 0) {
            return fees;
        }

        uint256 currentSize = position.size;

        for (uint256 i = 0; i < executionsToSettle.length; i++) {
            Types.ADLExecution memory execution = executionsToSettle[i];
            uint256 adlSizeForExecution;

            if (execution.isCloseMarket) {
                adlSizeForExecution = currentSize;
            } else {
                adlSizeForExecution = (currentSize * ADLManager.ADL_REDUCTION_RATIO_E4) / 10_000;
            }

            if (adlSizeForExecution > 0) {
                uint256 diffRate = execution.cumulativeBorrowingRates > position.borrowRate
                    ? execution.cumulativeBorrowingRates - position.borrowRate
                    : 0;

                uint256 executionBorrowingFee = (adlSizeForExecution * diffRate) / Types.BORROWING_RATE_PRECISION;
                uint256 executionPositionFee = (adlSizeForExecution * config.positionFeeRateE4) / Types.BASIS_POINT;

                fees.borrowingFee += executionBorrowingFee;
                fees.positionFee += executionPositionFee;

                currentSize -= adlSizeForExecution;
            }
        }

        fees.totalFee = fees.borrowingFee + fees.positionFee;
        return fees;
    }

    function processFees(
        Types.PositionFees memory fees,
        Types.PositionConfig memory config,
        IBase base,
        Types.Action action,
        Currency baseToken,
        uint256 remainingCollateral,
        uint256 round
    ) external returns (Types.PositionFees memory, uint256) {
        if (action == Types.Action.MarginCall || action == Types.Action.ReduceMargin) {
            fees.liquidationFee = 0;
            fees.positionFee = 0;
            fees.totalFee = fees.borrowingFee;
            splitAndDistributeFees(fees.borrowingFee, config, base, Types.FeeType.BorrowingFee, baseToken, round);
            return (fees, remainingCollateral - fees.borrowingFee);
        } else if (action == Types.Action.Decrease) {
            fees.liquidationFee = 0;
            fees.totalFee = fees.borrowingFee + fees.positionFee;
            splitAndDistributeFees(fees.positionFee, config, base, Types.FeeType.PositionFee, baseToken, round);
            splitAndDistributeFees(fees.borrowingFee, config, base, Types.FeeType.BorrowingFee, baseToken, round);
            return (fees, remainingCollateral - fees.borrowingFee - fees.positionFee);
        } else if (action == Types.Action.Liquidation || action == Types.Action.ADL) {
            Types.PositionFees memory settlementFees;
            if (remainingCollateral > 0) {
                settlementFees.borrowingFee = Math.min(remainingCollateral, fees.borrowingFee);
                splitAndDistributeFees(
                    settlementFees.borrowingFee, config, base, Types.FeeType.BorrowingFee, baseToken, round
                );
                remainingCollateral -= settlementFees.borrowingFee;
            }
            if (remainingCollateral > 0) {
                settlementFees.positionFee = Math.min(remainingCollateral, fees.positionFee);
                splitAndDistributeFees(
                    settlementFees.positionFee, config, base, Types.FeeType.PositionFee, baseToken, round
                );
                remainingCollateral -= settlementFees.positionFee;
            }
            if (action == Types.Action.Liquidation) {
                if (remainingCollateral > 0) {
                    settlementFees.liquidationFee = remainingCollateral;
                    splitAndDistributeFees(
                        settlementFees.liquidationFee, config, base, Types.FeeType.LiquidationFee, baseToken, round
                    );
                    remainingCollateral -= settlementFees.liquidationFee;
                }
            }
            settlementFees.totalFee =
                settlementFees.borrowingFee + settlementFees.positionFee + settlementFees.liquidationFee;
            return (settlementFees, remainingCollateral);
        }
        revert Error.InvalidAction(action);
    }

    function splitAndDistributeFees(
        uint256 feeAmount,
        Types.PositionConfig memory config,
        IBase base,
        Types.FeeType feeType,
        Currency baseToken,
        uint256 round
    ) internal {
        if (feeAmount == 0) return;

        Types.VaultTransferType vaultTransferType;
        if (feeType == Types.FeeType.BorrowingFee) {
            vaultTransferType = Types.VaultTransferType.BorrowFee;
        } else if (feeType == Types.FeeType.PositionFee) {
            vaultTransferType = Types.VaultTransferType.PositionFee;
        }
        uint256 feeToVault = (feeAmount * config.vaultFeeAllocationE4) / Types.BASIS_POINT;
        if (feeType == Types.FeeType.LiquidationFee) {
            feeToVault = 0;
        } else {
            base.perpVault().transferIn(baseToken, round, vaultTransferType, feeToVault);
        }
        base.currencyAzUsd().transfer(base.azUsdTreasure(), feeAmount - feeToVault);
        emit FeeToReceiver(baseToken, feeType, feeAmount - feeToVault, base.azUsdTreasure());
    }

    function checkLiquidation(
        Types.Position memory position,
        int256 pnl,
        Types.PositionFees memory fees
    ) internal pure returns (bool) {
        return int256(position.collateral) + pnl < int256(fees.totalFee);
    }

    function checkADLForLiquidity(
        Types.Position memory longPosition,
        Types.Position memory shortPosition,
        uint256 vaultBalance
    ) internal pure returns (bool needADL, int256 riskDelta, bool closeMarket) {
        int256 net = getEffectiveSize(longPosition).toInt256() - getEffectiveSize(shortPosition).toInt256();

        if (vaultBalance == 0) {
            return (true, 0, true);
        }

        if (net == 0) {
            return (false, 0, false);
        }

        bool isLongNet = net > 0;
        uint256 absNetSize = net.abs();

        if (absNetSize > vaultBalance) {
            uint256 targetNetOI = vaultBalance;
            int256 adlAmount = int256(absNetSize - targetNetOI);
            return (true, isLongNet ? adlAmount : -adlAmount, false);
        }

        return (false, net, false);
    }

    function validateADLAmount(int256 adlAmount, Types.Position memory globalPosition) internal pure {
        if (adlAmount == 0) return;

        bool isLong = adlAmount > 0;
        uint256 cappedDelta = adlAmount.abs();
        uint256 maxAllowed = getEffectiveSize(globalPosition);

        if (cappedDelta > maxAllowed) {
            revert Error.InvalidADLAmount(isLong, maxAllowed, cappedDelta);
        }
    }

    function processADLSettlement(
        Types.Position storage userPosition,
        Types.Position storage globalPosition,
        uint256 adlSettledAmount,
        int256 positionCollateralChange
    ) internal {
        if (adlSettledAmount == 0) return;

        userPosition.size -= adlSettledAmount;

        globalPosition.size -= adlSettledAmount;
        globalPosition.collateral = uint256(int256(globalPosition.collateral) + positionCollateralChange);
        globalPosition.adlSize -= adlSettledAmount;
    }
}
