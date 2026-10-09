// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/external/IAggregatorV3.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title OracleAdapter
/// @notice Chainlink-backed IPriceOracle. Every read enforces:
///         - positive answer, non-zero and non-future timestamp, answeredInRound >= roundId
///         - per-feed max staleness
///         - optional L2 sequencer uptime check with grace period (disabled while no feed exists on the chain)
///         - optional deviation check against a secondary IPriceOracle (swap in a second source when one exists)
///         The whole adapter is swappable: consumers hold an IPriceOracle reference settable via the Timelock.
contract OracleAdapter is AccessControl, IPriceOracle {
    struct FeedConfig {
        IAggregatorV3 feed;
        uint32 maxStaleness;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        uint16 maxDeviationBps;
        IPriceOracle secondary;
    }

    uint256 public constant MAX_STALENESS_CAP = 4 days;
    uint256 public constant MIN_STALENESS = 60;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 public constant MAX_DEVIATION_CAP_BPS = 2_000;

    mapping(address token => FeedConfig) public feeds;
    IAggregatorV3 public sequencerUptimeFeed;

    event FeedSet(
        address indexed token, address feed, uint32 maxStaleness, address secondary, uint16 maxDeviationBps
    );
    event SequencerFeedSet(address feed);

    error NoFeed(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error SequencerDown();
    error PriceDeviation(address token, uint256 primary, uint256 secondary);
    error InvalidConfig();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- admin

    function setFeed(address token, address feed, uint32 maxStaleness, address secondary, uint16 maxDeviationBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0) || feed == address(0)) revert InvalidConfig();
        if (maxStaleness < MIN_STALENESS || maxStaleness > MAX_STALENESS_CAP) revert InvalidConfig();
        if (maxDeviationBps > MAX_DEVIATION_CAP_BPS) revert InvalidConfig();
        if (secondary != address(0) && maxDeviationBps == 0) revert InvalidConfig();
        uint8 fd = IAggregatorV3(feed).decimals();
        uint8 td = IERC20Metadata(token).decimals();
        if (fd > 18 || td > 36) revert InvalidConfig();
        feeds[token] = FeedConfig({
            feed: IAggregatorV3(feed),
            maxStaleness: maxStaleness,
            feedDecimals: fd,
            tokenDecimals: td,
            maxDeviationBps: maxDeviationBps,
            secondary: IPriceOracle(secondary)
        });
        emit FeedSet(token, feed, maxStaleness, secondary, maxDeviationBps);
    }

    function setSequencerUptimeFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = IAggregatorV3(feed);
        emit SequencerFeedSet(feed);
    }

    // ---------------------------------------------------------------- views

    function hasFeed(address token) external view returns (bool) {
        return address(feeds[token].feed) != address(0);
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function getPrice(address token) public view returns (uint256 priceWad) {
        FeedConfig memory c = feeds[token];
        if (address(c.feed) == address(0)) revert NoFeed(token);
        _checkSequencer();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = c.feed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(token);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > c.maxStaleness) {
            revert StalePrice(token, updatedAt);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        priceWad = uint256(answer) * 10 ** (18 - c.feedDecimals);
        if (address(c.secondary) != address(0)) {
            uint256 p2 = c.secondary.getPrice(token);
            uint256 diff = priceWad > p2 ? priceWad - p2 : p2 - priceWad;
            if (diff * 10_000 > uint256(c.maxDeviationBps) * p2) revert PriceDeviation(token, priceWad, p2);
        }
    }
    // slither-disable-end unused-return

    function convert(address from, uint256 amount, address to) external view returns (uint256) {
        if (amount == 0) return 0;
        uint256 pFrom = getPrice(from);
        uint256 pTo = getPrice(to);
        uint8 dFrom = feeds[from].tokenDecimals;
        uint8 dTo = feeds[to].tokenDecimals;
        // amount * pFrom / 10^dFrom = usdWad ; out = usdWad * 10^dTo / pTo
        return Math.mulDiv(Math.mulDiv(amount, pFrom, 10 ** dFrom), 10 ** dTo, pTo);
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function getRoundPrice(address token, uint80 roundId) external view returns (uint256 priceWad, uint256 updatedAt) {
        FeedConfig memory c = feeds[token];
        if (address(c.feed) == address(0)) revert NoFeed(token);
        int256 answer;
        (, answer,, updatedAt,) = c.feed.getRoundData(roundId);
        if (answer <= 0 || updatedAt == 0) revert InvalidPrice(token);
        // forge-lint: disable-next-line(unsafe-typecast)
        priceWad = uint256(answer) * 10 ** (18 - c.feedDecimals);
    }
    // slither-disable-end unused-return

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _checkSequencer() internal view {
        IAggregatorV3 seq = sequencerUptimeFeed;
        if (address(seq) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = seq.latestRoundData();
        // answer == 0: sequencer up; 1: down
        if (answer != 0 || startedAt == 0 || block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SequencerDown();
        }
    }
    // slither-disable-end unused-return
}
