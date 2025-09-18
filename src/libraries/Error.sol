// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Types } from "src/Types.sol";

library Error {
    error NotSelf(address);
    error PremineAmountZero();
    error PoolAlreadyExists();

    error CallerIsNotMarketManager();
    error CallerIsNotCreator(address _caller, address _creator);
    error CreatorFeeAllocationInvalid(uint24 _allocation, uint256 _maxAllocation);
    error InvalidCrossDomainSender();
    error InvalidLaunchSchedule();
    error InvalidInitialSupply(uint256 initialSupply);
    error PremineExceedsInitialAmount(uint256 buyAmount, uint256 initialSupply);
    error TokenAlreadyBridged();
    error UnknownMarketToken();

    error CallerIsNotBuybackManager();
    error CallerIsNotListingManager();
    error CannotBeInitializedDirectly();
    error InsufficientLaunchFee(uint256 paid, uint256 required);
    error TokenNotLaunched(uint256 launchesAt);
    error UnknownPool(PoolId poolId);

    error CannotModifyLiquidityDuringPremarket();
    error CannotSellTokenDuringPremarket();

    error MintAddressIsZero();
    error CallerNotStreams();
    error Permit2AllowanceIsFixedAtInfinity();

    error AmountsForPremarketIsZero();
    error MaxAmountsForPremarket(uint256 baseTokenAmount, uint256 maxAmountsForPremarket);
    error CreatorFeeAllocationTooHigh(uint24 creatorFeeAllocation, uint24 maxCreatorFeeAllocation);
    error InsufficientPremarketSupply(uint256 tokensOut, uint256 supply);
    error InsufficientAzUsd(uint256 azUsdAmount, uint256 actualTotalAzUsd);
    error InvalidTicks(int24[3] ticks);
    error PremarketNotClosed();
    error InitialLiquidityBurned();

    error PerpetualStateError(Types.PerpetualState state);

    error MarketNotExists();
    error MarketAlreadyExists(Currency baseToken);
    error OnlyPoolManager();
    error CannotAddLiquidityDuringPremarket();
    error CannotSwapDuringPremarket();
    error PremarketStateError(Types.PremarketState stage);
    error PoolNotFound(address baseToken);
    error CannotRemoveLockedLiquidity();
    error PerpetualDisabled(Currency baseToken);
    error PerpetualEnabled(Currency baseToken);
    error PerpetualMaxDelistCountReached(Currency baseToken);

    error ZeroOraclePrice(Currency baseToken);
    error ZeroValue(string value);
    error ZeroAddress(string value);
    error ZeroDelta();
    error InvalidBaseToken(Currency baseToken);
    error InsufficientOutputAmount();
    error InvalidTransferType(Types.VaultTransferType transferType);
    error InvalidDeadline(uint256 deadline, uint256 blockTimestamp);
    error InvalidValue(uint256 value, uint256 expectedValue);
    error HayekOnlyForwardERC20();
    error InvalidCaller();
    error InvalidCurrency(Currency currency);
    error UnLockCallbackFailed();

    error CallerIsNotPositionManager();
    error InvalidCollateral(uint256 collateral, uint256 minCollateral);
    error PositionNotExist(Types.Position position);
    error NotOwner(address owner, address expectedOwner);
    error ShouldBeLiquidated(Types.Position position, int256 pnl, Types.PositionFees fees, uint256 markPrice);
    error ShouldNotBeLiquidated(Types.Position position, int256 pnl, Types.PositionFees fees, uint256 markPrice);
    error CanNotOperate(Types.Position position);
    error InvalidLeverage(uint256 leverageBps, uint256 minLeverage, uint256 maxLeverage);
    error InsufficientLiquidity();
    error InvalidTriggerPrice(uint256 triggerPrice, uint256 markPrice);
    error InsufficientCollateral(uint256 collateral, uint256 requiredCollateral);
    error InvalidADLAmount(bool isLong, uint256 maxAllowed, uint256 adlAmount);
    error InvalidAction(Types.Action action);
    error InvalidRound(uint256 round, uint256 currentRound);
    error InvalidLiquidityAndPnl(uint256 azUsdBalances, int256 adlPnl);
    error InCoolDownDuration();
    error PerpVaultNotInitialized(Currency baseToken);
    error PerpetualAlreadyEnabled();
}
