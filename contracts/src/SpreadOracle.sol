// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {ISpreadOracle} from "./interfaces/IPairwise.sol";

/// @title SpreadOracle
/// @notice Per-pair fixed-size ring buffer of daily closes and the statistics the strategy needs:
///         - z-score of the live A/B price ratio vs the rolling mean/stdev of the ratio over `window` closes
///         - Pearson correlation of daily returns (entry gate / correlation-breakdown exit)
///         - OLS beta of A returns on B returns, published as the hedge ratio at most once a week
///         All loops are bounded by CAPACITY (64).
contract SpreadOracle is AccessControl, ISpreadOracle {
    using SafeCast for uint256;

    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant SEEDER_ROLE = keccak256("SEEDER_ROLE");

    uint256 public constant CAPACITY = 64;
    uint256 public constant MIN_WINDOW = 10;
    uint256 public constant MIN_SAMPLES = 10;
    uint256 public constant HEDGE_INTERVAL = 7 days;
    uint256 public constant MIN_HEDGE = 0.5e18;
    uint256 public constant MAX_HEDGE = 2e18;
    uint256 public constant SEED_MAX_AGE = 26 hours; // same bound as live oracle staleness
    uint256 internal constant WAD = 1e18;

    struct Close {
        uint96 priceA;
        uint96 priceB;
        uint64 day;
    }

    struct Pair {
        address tokenA;
        address tokenB;
        uint16 window;
        uint8 head; // next write slot
        uint8 count; // filled slots (<= CAPACITY)
        uint64 lastDay;
        uint64 hedgeUpdatedAt;
        uint128 hedgeRatio;
    }

    IPriceOracle public oracle;
    IMarketClock public immutable clock;

    uint256 public pairCount;
    mapping(uint256 pairId => Pair) internal _pairs;
    mapping(uint256 pairId => Close[CAPACITY]) internal _closes;

    event PairRegistered(uint256 indexed pairId, address indexed tokenA, address indexed tokenB, uint16 window);
    event CloseRecorded(uint256 indexed pairId, uint64 indexed day, uint256 priceA, uint256 priceB);
    event HedgeRatioUpdated(uint256 indexed pairId, uint256 rawBeta, uint256 hedgeRatio);
    event OracleSet(address oracle);
    event WindowSet(uint256 indexed pairId, uint16 window);

    error UnknownPair();
    error InvalidWindow();
    error InvalidTokens();
    error NotAfterClose();
    error AlreadyRecorded();
    error AlreadySeeded();
    error BadSeed(uint256 index);
    error TooEarly();
    error NotEnoughData();

    constructor(address admin, IPriceOracle oracle_, IMarketClock clock_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        oracle = oracle_;
        clock = clock_;
    }

    // ---------------------------------------------------------------- admin

    function setOracle(IPriceOracle oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setWindow(uint256 pairId, uint16 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pair(pairId);
        if (window < MIN_WINDOW || window > CAPACITY) revert InvalidWindow();
        _pairs[pairId].window = window;
        emit WindowSet(pairId, window);
    }

    function registerPair(address tokenA, address tokenB, uint16 window)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 pairId)
    {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert InvalidTokens();
        if (window < MIN_WINDOW || window > CAPACITY) revert InvalidWindow();
        if (!oracle.hasFeed(tokenA) || !oracle.hasFeed(tokenB)) revert InvalidTokens();
        pairId = ++pairCount;
        _pairs[pairId] = Pair({
            tokenA: tokenA,
            tokenB: tokenB,
            window: window,
            head: 0,
            count: 0,
            lastDay: 0,
            hedgeUpdatedAt: uint64(block.timestamp),
            hedgeRatio: uint128(WAD)
        });
        emit PairRegistered(pairId, tokenA, tokenB, window);
    }

    // ---------------------------------------------------------------- sampling

    /// @notice Permissionless: records today's close once the regular session has ended.
    function recordClose(uint256 pairId) public {
        Pair storage p = _pair(pairId);
        if (!clock.isAfterCloseOnTradingDay(block.timestamp)) revert NotAfterClose();
        uint64 day = uint64(clock.etDay(block.timestamp));
        if (day <= p.lastDay) revert AlreadyRecorded();
        _push(pairId, p, oracle.getPrice(p.tokenA), oracle.getPrice(p.tokenB), day);
    }

    function recordCloses(uint256[] calldata pairIds) external {
        uint256 n = pairIds.length;
        if (n > 32) revert InvalidWindow();
        for (uint256 i; i < n; ++i) {
            recordClose(pairIds[i]);
        }
    }

    /// @notice One-time bootstrap from historical Chainlink rounds. Trust-minimised: for every entry the contract
    ///         verifies, for both legs, that round r was the price prevailing at that trading day's official close
    ///         (r.updatedAt <= close < (r+1).updatedAt) and was no older than SEED_MAX_AGE at the close, on strictly
    ///         increasing past trading days. A quiet feed may legitimately provide the same round for consecutive
    ///         days. The seeder only chooses which days to include, never the prices.
    function seedFromRounds(
        uint256 pairId,
        uint64[] calldata days_,
        uint80[] calldata roundsA,
        uint80[] calldata roundsB
    ) external onlyRole(SEEDER_ROLE) {
        Pair storage p = _pair(pairId);
        if (p.count != 0) revert AlreadySeeded();
        uint256 n = days_.length;
        if (n != roundsA.length || n != roundsB.length || n == 0 || n > CAPACITY) revert BadSeed(0);
        uint256 today = clock.etDay(block.timestamp);
        uint256 prevDay = 0;
        for (uint256 i; i < n; ++i) {
            if (days_[i] <= prevDay || days_[i] >= today) revert BadSeed(i);
            prevDay = days_[i];
            _seedOne(pairId, p, days_[i], roundsA[i], roundsB[i]);
        }
    }

    function _seedOne(uint256 pairId, Pair storage p, uint64 day, uint80 roundA, uint80 roundB) internal {
        uint256 closeTs = clock.closeTimestamp(day); // reverts on non-trading days
        _push(pairId, p, _verifiedClose(p.tokenA, roundA, closeTs), _verifiedClose(p.tokenB, roundB, closeTs), day);
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _verifiedClose(address token, uint80 roundId, uint256 closeTs) internal view returns (uint256 price) {
        uint256 t;
        (price, t) = oracle.getRoundPrice(token, roundId);
        (, uint256 tNext) = oracle.getRoundPrice(token, roundId + 1);
        if (t > closeTs || tNext <= closeTs || closeTs - t > SEED_MAX_AGE) revert BadSeed(type(uint256).max);
    }
    // slither-disable-end unused-return

    function _push(uint256 pairId, Pair storage p, uint256 priceA, uint256 priceB, uint64 day) internal {
        _closes[pairId][p.head] = Close({priceA: priceA.toUint96(), priceB: priceB.toUint96(), day: day});
        p.head = uint8((uint256(p.head) + 1) % CAPACITY);
        if (p.count < CAPACITY) p.count += 1;
        p.lastDay = day;
        emit CloseRecorded(pairId, day, priceA, priceB);
    }

    // ---------------------------------------------------------------- hedge ratio

    /// @notice Permissionless weekly update of the hedge ratio from the ring buffer (OLS beta, clamped).
    function updateHedgeRatio(uint256 pairId) external {
        Pair storage p = _pair(pairId);
        if (block.timestamp < uint256(p.hedgeUpdatedAt) + HEDGE_INTERVAL) revert TooEarly();
        (int256 b, bool ok) = _beta(pairId, p);
        if (!ok) revert NotEnoughData();
        uint256 raw = b < 0 ? 0 : uint256(b);
        uint256 h = raw < MIN_HEDGE ? MIN_HEDGE : (raw > MAX_HEDGE ? MAX_HEDGE : raw);
        p.hedgeRatio = uint128(h);
        p.hedgeUpdatedAt = uint64(block.timestamp);
        emit HedgeRatioUpdated(pairId, raw, h);
    }

    // ---------------------------------------------------------------- views

    function pairTokens(uint256 pairId) external view returns (address, address) {
        Pair storage p = _pair(pairId);
        return (p.tokenA, p.tokenB);
    }

    function getPair(uint256 pairId) external view returns (Pair memory) {
        return _pair(pairId);
    }

    function hedgeRatio(uint256 pairId) external view returns (uint256) {
        return _pair(pairId).hedgeRatio;
    }

    /// @notice All stored closes, oldest first.
    function getCloses(uint256 pairId)
        external
        view
        returns (uint64[] memory days_, uint256[] memory pricesA, uint256[] memory pricesB)
    {
        Pair storage p = _pair(pairId);
        uint256 n = p.count;
        days_ = new uint64[](n);
        pricesA = new uint256[](n);
        pricesB = new uint256[](n);
        uint256 start = (uint256(p.head) + CAPACITY - n) % CAPACITY;
        for (uint256 i; i < n; ++i) {
            Close memory c = _closes[pairId][(start + i) % CAPACITY];
            days_[i] = c.day;
            pricesA[i] = c.priceA;
            pricesB[i] = c.priceB;
        }
    }

    function currentRatio(uint256 pairId) public view returns (uint256) {
        Pair storage p = _pair(pairId);
        return Math.mulDiv(oracle.getPrice(p.tokenA), WAD, oracle.getPrice(p.tokenB));
    }

    /// @notice Rolling mean and sample standard deviation of the A/B ratio over the window.
    function ratioStats(uint256 pairId) public view returns (uint256 mean, uint256 std, uint256 n) {
        Pair storage p = _pair(pairId);
        (uint256[] memory a, uint256[] memory b) = _window(pairId, p);
        n = a.length;
        if (n < 2) return (0, 0, n);
        uint256 sum = 0;
        uint256[] memory r = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = Math.mulDiv(a[i], WAD, b[i]);
            sum += r[i];
        }
        mean = sum / n;
        uint256 ss = 0;
        for (uint256 i; i < n; ++i) {
            uint256 d = r[i] > mean ? r[i] - mean : mean - r[i];
            ss += d * d;
        }
        std = Math.sqrt(ss / (n - 1)); // ss is wad^2 -> sqrt is wad
    }

    function zScore(uint256 pairId) external view returns (int256 z, bool ok) {
        (uint256 mean, uint256 std, uint256 n) = ratioStats(pairId);
        if (n < MIN_SAMPLES || std == 0) return (0, false);
        uint256 cur = currentRatio(pairId);
        int256 diff = cur >= mean ? int256(cur - mean) : -int256(mean - cur);
        z = diff * int256(WAD) / int256(std);
        ok = true;
    }

    function correlation(uint256 pairId) external view returns (int256 corr, bool ok) {
        Pair storage p = _pair(pairId);
        (int256 cov, int256 varA, int256 varB, bool enough) = _moments(pairId, p);
        if (!enough || varA == 0 || varB == 0) return (0, false);
        // corr = cov / sqrt(varA * varB); all terms share the same 1/(n-1) factor
        uint256 denom = Math.sqrt(uint256(varA) * uint256(varB));
        if (denom == 0) return (0, false);
        corr = cov * int256(WAD) / int256(denom);
        ok = true;
    }

    function beta(uint256 pairId) external view returns (int256 b, bool ok) {
        return _beta(pairId, _pair(pairId));
    }

    function _beta(uint256 pairId, Pair storage p) internal view returns (int256 b, bool ok) {
        (int256 cov,, int256 varB, bool enough) = _moments(pairId, p);
        if (!enough || varB == 0) return (0, false);
        b = cov * int256(WAD) / varB;
        ok = true;
    }

    /// @dev Sums of co-moments of simple daily returns (not divided by n-1; ratios cancel it).
    function _moments(uint256 pairId, Pair storage p)
        internal
        view
        returns (int256 cov, int256 varA, int256 varB, bool enough)
    {
        (int256[] memory ra, int256[] memory rb, bool ok) = _demeanedReturns(pairId, p);
        if (!ok) return (0, 0, 0, false);
        int256 w = int256(WAD);
        for (uint256 i; i < ra.length; ++i) {
            cov += ra[i] * rb[i] / w;
            varA += ra[i] * ra[i] / w;
            varB += rb[i] * rb[i] / w;
        }
        enough = true;
    }

    /// @dev Demeaned simple daily returns of both legs over the window.
    function _demeanedReturns(uint256 pairId, Pair storage p)
        internal
        view
        returns (int256[] memory ra, int256[] memory rb, bool ok)
    {
        (uint256[] memory a, uint256[] memory b) = _window(pairId, p);
        if (a.length < MIN_SAMPLES) return (ra, rb, false);
        uint256 m = a.length - 1;
        ra = new int256[](m);
        rb = new int256[](m);
        int256 sa = 0;
        int256 sb = 0;
        for (uint256 i; i < m; ++i) {
            ra[i] = int256(Math.mulDiv(a[i + 1], WAD, a[i])) - int256(WAD);
            rb[i] = int256(Math.mulDiv(b[i + 1], WAD, b[i])) - int256(WAD);
            sa += ra[i];
            sb += rb[i];
        }
        sa /= int256(m);
        sb /= int256(m);
        for (uint256 i; i < m; ++i) {
            ra[i] -= sa;
            rb[i] -= sb;
        }
        ok = true;
    }

    /// @dev Last min(count, window) closes, oldest first.
    function _window(uint256 pairId, Pair storage p) internal view returns (uint256[] memory a, uint256[] memory b) {
        uint256 n = p.count < p.window ? p.count : p.window;
        a = new uint256[](n);
        b = new uint256[](n);
        uint256 start = (uint256(p.head) + CAPACITY - n) % CAPACITY;
        for (uint256 i; i < n; ++i) {
            Close memory c = _closes[pairId][(start + i) % CAPACITY];
            a[i] = c.priceA;
            b[i] = c.priceB;
        }
    }

    function _pair(uint256 pairId) internal view returns (Pair storage p) {
        p = _pairs[pairId];
        if (p.tokenA == address(0)) revert UnknownPair();
    }
}
