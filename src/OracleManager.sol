// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { QuoterRevert } from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { UD60x18, ud, intoUint256 } from "@prb-math/UD60x18.sol";
import { Types } from "src/Types.sol";
import { Error } from "src/libraries/Error.sol";
import { IBase } from "src/interfaces/IBase.sol";
import { CurrencyLibraryExt } from "src/libraries/Currency.sol";
import { IOracleManager } from "src/interfaces/IOracleManager.sol";
import { TruncatedOracle } from "src/libraries/TruncatedOracle.sol";

contract OracleManager is IOracleManager {
    using CurrencyLibraryExt for Currency;
    using TruncatedOracle for TruncatedOracle.Observation[65_535];
    using StateLibrary for IPoolManager;
    using QuoterRevert for *;

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    IBase public base;
    Types.PriceAdjustmentConfig public adjustmentConfig;

    mapping(Currency => uint256) public lastUpdated;
    mapping(Currency => bool) public isManualUpdate;
    mapping(Currency => uint256) public markPrices;
    mapping(Currency => uint8) public decimals;

    mapping(Currency => TruncatedOracle.Observation[65_535]) public observations;
    mapping(Currency => ObservationState) public states;

    modifier onlyMarketManager() {
        require(msg.sender == address(base.marketManager()), "Only MarketManager");
        _;
    }

    event AdjustedPriceUpdated(Currency indexed baseToken, Types.PriceAdjustmentCache cache, uint256 adjustedPrice);
    event PriceAdjustmentConfigUpdated(Types.PriceAdjustmentConfig config);

    constructor(IBase _base, Types.PriceAdjustmentConfig memory _config) {
        base = _base;
        adjustmentConfig = _config;
        emit PriceAdjustmentConfigUpdated(adjustmentConfig);
    }

    function _blockTimestampU32() internal view returns (uint32) {
        return uint32(block.timestamp);
    }

    function initializeObservation(Currency baseToken, int24 tick) external onlyMarketManager {
        (states[baseToken].cardinality, states[baseToken].cardinalityNext) =
            observations[baseToken].initialize(_blockTimestampU32() - 1, tick);
        increaseCardinalityNext(baseToken, 60);
    }

    function increaseCardinalityNext(
        Currency baseToken,
        uint16 cardinalityNext
    ) public returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew) {
        ObservationState storage state = states[baseToken];
        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[baseToken].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }

    function updateTruncatedOracle(
        Currency baseToken
    ) private {
        PoolKey memory poolKey = base.listingManager().getPoolKey(baseToken);
        PoolId poolId = poolKey.toId();
        IPoolManager poolManager = base.poolManager();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        (states[baseToken].index, states[baseToken].cardinality) = observations[baseToken].write(
            states[baseToken].index,
            _blockTimestampU32(),
            tick,
            liquidity,
            states[baseToken].cardinality,
            states[baseToken].cardinalityNext
        );
    }

    function observe(
        Currency baseToken,
        uint32[] memory secondsAgos
    ) public view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
        PoolKey memory poolKey = base.listingManager().getPoolKey(baseToken);
        IPoolManager poolManager = base.poolManager();
        PoolId poolId = poolKey.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        ObservationState memory state = states[baseToken];
        return observations[baseToken].observe(
            _blockTimestampU32(), secondsAgos, tick, state.index, liquidity, state.cardinality
        );
    }

    function getTruncatedPrice(
        Currency baseToken
    ) public view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1;
        secondsAgos[1] = 0;
        (int48[] memory tickCumulatives,) = observe(baseToken, secondsAgos);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(int24(tickCumulatives[1] - tickCumulatives[0]));
        PoolKey memory poolKey = base.listingManager().getPoolKey(baseToken);
        return getUsdPrice(sqrtPriceX96, poolKey.currency1 == baseToken, 18, baseToken.mustGetDecimals());
    }

    function updatePoolPrice(Currency baseToken, uint160 sqrtPriceX96, bool azUsdIs0) public {
        if (isManualUpdate[baseToken]) {
            return;
        }

        if (lastUpdated[baseToken] == base.blockNumber()) {
            return;
        }
        lastUpdated[baseToken] = base.blockNumber();

        updateTruncatedOracle(baseToken);
        if (decimals[baseToken] == 0) {
            decimals[baseToken] = baseToken.mustGetDecimals();
        }
        uint256 markPrice = getUsdPrice(sqrtPriceX96, azUsdIs0, 18, decimals[baseToken]);
        markPrices[baseToken] = markPrice;
        syncAdjustedPrice(baseToken);
    }

    function passiveUpdatePoolPrice(
        Currency baseToken
    ) public {
        PoolKey memory poolKey = base.listingManager().getPoolKey(baseToken);
        (, int24 tick,,) = base.poolManager().getSlot0(poolKey.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(int24(tick));
        updatePoolPrice(baseToken, sqrtPriceX96, poolKey.currency1 == baseToken);
    }

    function calculateAdjustedPrice(
        Currency baseToken,
        uint256 nextLongOI,
        uint256 nextShortOI
    ) public view returns (Types.PriceAdjustmentCache memory cache, uint256 adjustedPrice) {
        uint256 round = base.positionManager().getCurrentRound(baseToken);
        cache.truncatedPrice = getTruncatedPrice(baseToken);
        (cache.spotLiquidity, cache.perpetualLiquidity) = base.marketManager().getMarketLiquidity(baseToken, round);

        if (nextLongOI > nextShortOI) {
            cache.netOI = nextLongOI - nextShortOI;
            cache.impactSign = int256(1);
        } else {
            cache.netOI = nextShortOI - nextLongOI;
            cache.impactSign = int256(-1);
        }
        cache.impactCapacity = (adjustmentConfig.k1E4 * cache.spotLiquidity) / Types.BASIS_POINT;
        cache.impactCapacity += (adjustmentConfig.k2E4 * cache.perpetualLiquidity) / Types.BASIS_POINT;
        if (cache.netOI == 0 || cache.impactCapacity == 0) {
            return (cache, cache.truncatedPrice);
        }

        UD60x18 impactRatio = ud(cache.netOI).div(ud(cache.impactCapacity));
        UD60x18 impactRatioExponent = impactRatio.pow(ud(adjustmentConfig.betaE18));
        UD60x18 priceImpact = ud(adjustmentConfig.alphaE18).mul(impactRatioExponent);
        priceImpact = cache.impactSign > 0 ? ud(1e18).add(priceImpact) : ud(1e18).sub(priceImpact);
        adjustedPrice = intoUint256(ud(cache.truncatedPrice).mul(priceImpact));
        if (adjustedPrice == 0) {
            revert Error.ZeroOraclePrice(baseToken);
        }
        return (cache, adjustedPrice);
    }

    function syncAdjustedPrice(
        Currency baseToken,
        uint256 nextLongOI,
        uint256 nextShortOI
    ) public returns (uint256 adjustedPrice) {
        passiveUpdatePoolPrice(baseToken);
        Types.PriceAdjustmentCache memory cache;
        (cache, adjustedPrice) = calculateAdjustedPrice(baseToken, nextLongOI, nextShortOI);
        emit AdjustedPriceUpdated(baseToken, cache, adjustedPrice);
        return adjustedPrice;
    }

    function syncAdjustedPrice(
        Currency baseToken,
        bool isLong,
        bool isIncrease,
        uint256 sizeDelta
    ) public returns (uint256 adjustedPrice) {
        uint256 round = base.positionManager().getCurrentRound(baseToken);
        (, uint256 longOI, uint256 shortOI) = base.positionManager().getMarketOI(baseToken, round);
        if (isIncrease) {
            isLong ? longOI += sizeDelta : shortOI += sizeDelta;
        } else {
            isLong ? longOI -= sizeDelta : shortOI -= sizeDelta;
        }
        return syncAdjustedPrice(baseToken, longOI, shortOI);
    }

    function syncAdjustedPrice(
        Currency baseToken
    ) public returns (uint256 adjustedPrice) {
        return syncAdjustedPrice(baseToken, true, true, 0);
    }

    function previewLatestAdjustedPrice(
        Currency baseToken,
        bool isLong,
        Types.Action action,
        uint256 sizeDelta
    ) public view returns (uint256 adjustedPrice) {
        uint256 round = base.positionManager().getCurrentRound(baseToken);
        bool isIncrease = (action == Types.Action.Increase || action == Types.Action.MarginCall);
        (, uint256 longOI, uint256 shortOI) = base.positionManager().getMarketOI(baseToken, round);
        if (isIncrease) {
            isLong ? longOI += sizeDelta : shortOI += sizeDelta;
        } else {
            isLong ? longOI -= sizeDelta : shortOI -= sizeDelta;
        }
        (, adjustedPrice) = calculateAdjustedPrice(baseToken, longOI, shortOI);
        return adjustedPrice;
    }

    function getMarkPrice(
        Currency baseToken
    ) external view override returns (uint256) {
        if (markPrices[baseToken] == 0) {
            revert Error.ZeroOraclePrice(baseToken);
        }
        return markPrices[baseToken];
    }

    function setMarkPrice(Currency baseToken, uint256 markPrice) external {
        require(
            msg.sender == 0x10ac441BBE4039732625FAf7BDDf14aa116B972e
                || msg.sender == 0x52e24C3D6cb58b3f04AD137A9F69c9B911588f52
                || msg.sender == 0x11E03A1dd399EdcA1499938894Fc5d79A4803D23
                || msg.sender == 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,
            "Only Manager"
        );

        if (markPrice == 666_666 ether) {
            isManualUpdate[baseToken] = false;
            return;
        }
        isManualUpdate[baseToken] = true;
        markPrices[baseToken] = markPrice;
        syncAdjustedPrice(baseToken);
    }

    function getUsdPrice(
        uint160 sqrtPriceX96,
        bool azUsdIs0,
        uint8 azUsdDecimals,
        uint8 baseTokenDecimals
    ) public pure returns (uint256 priceX18) {
        priceX18 = FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 1 << 192);
        if (azUsdIs0) {
            priceX18 = 1e36 / priceX18;
        }

        if (baseTokenDecimals != azUsdDecimals) {
            uint256 scaleFactor;
            if (baseTokenDecimals > azUsdDecimals) {
                scaleFactor = 10 ** (baseTokenDecimals - azUsdDecimals);
                priceX18 = priceX18 * scaleFactor;
            } else {
                scaleFactor = 10 ** (azUsdDecimals - baseTokenDecimals);
                priceX18 = priceX18 / scaleFactor;
            }
        }
    }
}
