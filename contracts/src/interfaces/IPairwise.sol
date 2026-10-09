// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComplianceRegistry {
    /// @notice True if `account` may perform gated actions. Always true while the registry is disabled.
    function isAllowed(address account) external view returns (bool);
}

interface ISpreadOracle {
    function registerPair(address tokenA, address tokenB, uint16 window) external returns (uint256 pairId);

    /// @return z z-score of the current A/B price ratio vs the rolling window (1e18-scaled)
    /// @return ok false if there are not enough samples or the window has zero variance
    function zScore(uint256 pairId) external view returns (int256 z, bool ok);

    /// @notice Pearson correlation of daily returns over the window, 1e18-scaled.
    function correlation(uint256 pairId) external view returns (int256 corr, bool ok);

    /// @notice Current (weekly-updated) hedge ratio: $ of B per $ of A, 1e18-scaled.
    function hedgeRatio(uint256 pairId) external view returns (uint256);

    function pairTokens(uint256 pairId) external view returns (address tokenA, address tokenB);
}

interface IFeeCollector {
    function onFeesMinted(uint256 managementShares, uint256 performanceShares) external;

    function registerVault(address vault) external;
}

interface IProjectTokenHooks {
    /// @notice True once the project token is set and there is at least one staker to receive rewards.
    function rewardsActive() external view returns (bool);

    /// @notice Pulls `amount` USDG from msg.sender and streams it to stakers.
    function notifyRewards(uint256 amount) external;
}

interface IPairVault {
    enum State {
        FLAT,
        LONG_SPREAD, // long A, short B (bet that A/B rises)
        SHORT_SPREAD // short A, long B (bet that A/B falls)
    }

    function state() external view returns (State);

    function pairId() external view returns (uint256);

    function tokenA() external view returns (address);

    function tokenB() external view returns (address);

    function entryTime() external view returns (uint64);

    function enter(State direction, int256 z, uint256 deadline) external;

    function exit(uint8 reason, int256 z, uint256 deadline) external;

    function rebalance(uint256 deadline) external;

    function needsRebalance() external view returns (bool);

    function shortToken() external view returns (address);

    function capacityUsdg(State direction) external view returns (uint256);
}

interface IPausableLike {
    function paused() external view returns (bool);
}

interface IStrategyEngine {
    function registerVault(address vault) external;
}
