// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

library Types {
    bytes32 public constant BUY_BACK_SALT = keccak256("BUYBACK");
    bytes32 public constant LISTING_SALT = keccak256("LISTING");

    uint256 public constant USD = 1 ether;
    uint256 public constant BASIS_POINT = 1e4;
    uint256 public constant BORROWING_RATE_PRECISION = 1e6;
    Currency public constant NEW_TOKEN_FLAG = Currency.wrap(0x000000000000000000000000000000000000dEaD);

    enum PremarketState {
        Unknown,
        Active,
        WaitingForClose,
        Closed
    }

    enum PerpetualState {
        Disabled,
        Preheating,
        Enabled
    }

    enum VaultTransferType {
        Buy,
        Sell,
        Profit,
        Loss,
        BorrowFee,
        PositionFee
    }

    enum FeeType {
        BorrowingFee,
        PositionFee,
        LiquidationFee
    }

    enum Action {
        Increase,
        Decrease,
        MarginCall,
        ReduceMargin,
        Liquidation,
        ADL
    }

    enum ADLReason {
        Decrease,
        Liquidation,
        RemoveLiquidity
    }

    struct ListingRequest {
        address creator;
        string name;
        string symbol;
        string tokenURI;
        Currency baseToken;
        uint256 baseTokenAmount;
        uint256 azUsdAmount;
        uint24 creatorFeeAllocation;
        bool initialLiquidityBurned;
        int24[3] ticks;
        string[] attributes;
    }

    struct Market {
        uint256 tokenId;
        address creator;
        Currency baseToken;
        uint256 startsAt;
        uint256 endsAt;
        uint256 supply;
        uint256 revenue;
        uint256 fee;
        int24[3] ticks;
        bool isNewToken;
        bool initialLiquidityBurned;
        bool closed;
    }

    struct ListingManagerConfig {
        uint256 creatorMinPurchaseAmount;
        uint256 existingTokenListingFee;
        uint256 newTokenListingFee;
        uint256 premarketWindow;
        uint256 purchaseFeeRateE4;
        uint24 swapFeeRateToLpE6;
        int24 tickSpacing;
    }

    struct NewTokenSchema {
        uint256 maxAmountsForPremarket;
        uint24 maxCreatorFeeAllocation;
        uint256 totalSupply;
    }

    struct BuyBackInfo {
        bool disabled;
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint256 pendingFees;
        uint256 cumulativeSwapFees;
    }

    struct PositionConfig {
        uint256 borrowingInterval;
        uint256 borrowingRateE6;
        uint256 liquidationFeeRateE4;
        uint256 maxLeverage;
        uint256 minCollateral;
        uint256 minLeverage;
        uint256 minPnLDuration;
        uint256 positionFeeRateE4;
        uint256 vaultFeeAllocationE4;
    }

    struct PositionFees {
        uint256 borrowingFee;
        uint256 liquidationFee;
        uint256 positionFee;
        uint256 totalFee;
    }

    struct LiquidityCalcState {
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int128 liquidityNet;
        uint256 amount0;
        uint256 amount1;
    }

    struct LiquidityPositions {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint256 baseTokenAmount;
        uint256 azUsdAmount;
    }

    struct MarketConfig {
        uint256 perpetualMinAzUsdAmount;
        uint256 preheatingDuration;
        uint24 swapFeeRateToProtocolE6;
    }

    struct ModifyLiquiditySweepParams {
        bool sweepAzUsd;
        bool sweepBaseToken;
        address receiver;
    }

    struct Order {
        address owner;
        Currency baseToken;
        bool isLong;
        uint256 positionId;
        Action action;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 triggerPrice;
        bool isTriggerAbove;
        uint256 slippage;
        uint256 deadline;
        string referralCode;
    }

    struct Position {
        address owner;
        Currency baseToken;
        bool isLong;
        uint256 positionId;
        uint256 size;
        uint256 adlSize;
        uint256 share;
        uint256 borrowRate;
        uint256 entryPrice;
        uint256 leverage;
        uint256 collateral;
        uint256 increasedAt;
        uint256 increasedAtBlock;
        uint256 round;
        uint256 lastProcessedAdlIndex;
    }

    struct ADLExecution {
        uint256 adlPrice;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 cumulativeBorrowingRates;
        bool isCloseMarket;
    }

    struct ADLInfo {
        int256 globalLongPnl;
        int256 globalShortPnl;
        uint256 adlExecutionCount;
    }

    struct ReferralInfo {
        address referrer;
        uint256 level;
        uint256 totalReferrals;
        uint256 spotVolume;
        uint256 perpetualVolume;
        uint256 totalRewards;
    }

    struct LevelConfig {
        uint256 minSpotVolume;
        uint256 minPerpetualVolume;
        uint256 rewardRate;
        uint256 discountRate;
        bool isActive;
    }

    struct SwapCallbackData {
        address sender;
        SwapSettings settings;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    struct SwapSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    struct ADLEvent {
        uint256 markPrice;
        uint256 sizeReduced;
        uint256 globalSharesBefore;
    }

    struct PriceAdjustmentConfig {
        uint256 alphaE18;
        uint256 betaE18;
        uint256 k1E4;
        uint256 k2E4;
    }

    struct PriceAdjustmentCache {
        uint256 truncatedPrice;
        uint256 spotLiquidity;
        uint256 perpetualLiquidity;
        uint256 netOI;
        int256 impactSign;
        uint256 impactCapacity;
    }
}
