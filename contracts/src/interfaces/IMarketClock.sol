// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMarketClock
/// @notice US equity regular-session clock (NYSE hours, America/New_York incl. DST, holiday calendar).
interface IMarketClock {
    function isMarketOpen() external view returns (bool);

    function isOpenAt(uint256 timestamp) external view returns (bool);

    /// @notice ET calendar day number (days since 1970-01-01 in New York local time) for `timestamp`.
    function etDay(uint256 timestamp) external view returns (uint256 day);

    /// @notice True when `timestamp` falls on a trading day after that day's session closed.
    function isAfterCloseOnTradingDay(uint256 timestamp) external view returns (bool);

    /// @notice UTC timestamp of the session close for ET day `day` (early closes respected). Reverts if not a trading day.
    function closeTimestamp(uint256 day) external view returns (uint256);

    function isTradingDay(uint256 day) external view returns (bool);
}
