// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";

/// @title MarketClock
/// @notice Answers "is the US equity regular session open right now?" fully on-chain.
///         - Regular session 09:30-16:00 America/New_York, Monday-Friday.
///         - US DST rule (since 2007): starts 2nd Sunday of March 02:00 local, ends 1st Sunday of November 02:00 local.
///         - Exchange holidays and 13:00 early closes are maintained by CALENDAR_ROLE (bounded batch writes).
///         - Optional buffers keep keepers away from the open/close auctions.
contract MarketClock is AccessControl, IMarketClock {
    bytes32 public constant CALENDAR_ROLE = keccak256("CALENDAR_ROLE");

    uint256 public constant OPEN_MINUTE = 9 * 60 + 30;
    uint256 public constant CLOSE_MINUTE = 16 * 60;
    uint256 public constant EARLY_CLOSE_MINUTE = 13 * 60;
    uint256 public constant MAX_BUFFER_MINUTES = 60;
    uint256 public constant MAX_BATCH = 64;

    mapping(uint256 day => bool) public isHoliday;
    mapping(uint256 day => bool) public isEarlyClose;

    uint256 public openBufferMinutes;
    uint256 public closeBufferMinutes;

    event HolidaySet(uint256 indexed day, bool isHoliday);
    event EarlyCloseSet(uint256 indexed day, bool isEarlyClose);
    event BuffersSet(uint256 openBufferMinutes, uint256 closeBufferMinutes);

    error BatchTooLarge();
    error BufferTooLarge();
    error NotTradingDay();

    constructor(address admin, address calendarKeeper) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CALENDAR_ROLE, calendarKeeper);
    }

    // ---------------------------------------------------------------- admin

    function setHolidays(uint256[] calldata days_, bool value) external onlyRole(CALENDAR_ROLE) {
        if (days_.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < days_.length; ++i) {
            isHoliday[days_[i]] = value;
            emit HolidaySet(days_[i], value);
        }
    }

    function setEarlyCloses(uint256[] calldata days_, bool value) external onlyRole(CALENDAR_ROLE) {
        if (days_.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < days_.length; ++i) {
            isEarlyClose[days_[i]] = value;
            emit EarlyCloseSet(days_[i], value);
        }
    }

    function setBuffers(uint256 openBuffer, uint256 closeBuffer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (openBuffer > MAX_BUFFER_MINUTES || closeBuffer > MAX_BUFFER_MINUTES) revert BufferTooLarge();
        openBufferMinutes = openBuffer;
        closeBufferMinutes = closeBuffer;
        emit BuffersSet(openBuffer, closeBuffer);
    }

    // ---------------------------------------------------------------- views

    function isMarketOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    function isOpenAt(uint256 timestamp) public view returns (bool) {
        (uint256 day, uint256 minute) = _local(timestamp);
        if (!isTradingDay(day)) return false;
        uint256 close = isEarlyClose[day] ? EARLY_CLOSE_MINUTE : CLOSE_MINUTE;
        return minute >= OPEN_MINUTE + openBufferMinutes && minute < close - closeBufferMinutes;
    }

    function isAfterCloseOnTradingDay(uint256 timestamp) external view returns (bool) {
        (uint256 day, uint256 minute) = _local(timestamp);
        if (!isTradingDay(day)) return false;
        return minute >= (isEarlyClose[day] ? EARLY_CLOSE_MINUTE : CLOSE_MINUTE);
    }

    function etDay(uint256 timestamp) external pure returns (uint256 day) {
        (day,) = _local(timestamp);
    }

    function isTradingDay(uint256 day) public view returns (bool) {
        uint256 wd = weekday(day);
        return wd >= 1 && wd <= 5 && !isHoliday[day];
    }

    function closeTimestamp(uint256 day) external view returns (uint256) {
        if (!isTradingDay(day)) revert NotTradingDay();
        uint256 minute = isEarlyClose[day] ? EARLY_CLOSE_MINUTE : CLOSE_MINUTE;
        // local wall-clock -> UTC. DST status at 13:00/16:00 local equals DST status at noon local.
        uint256 localTs = day * 1 days + minute * 60;
        uint256 offset = isDst(day * 1 days + 17 hours) ? 4 hours : 5 hours; // noon ET ~ 16:00-17:00 UTC
        return localTs + offset;
    }

    /// @notice 0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday.
    // slither: weak-prng: modulo is calendar arithmetic (weekday / minute-of-day), not randomness
    // slither-disable-start weak-prng
    function weekday(uint256 day) public pure returns (uint256) {
        return (day + 4) % 7;
    }
    // slither-disable-end weak-prng

    /// @notice True if US Eastern daylight time is in effect at UTC `timestamp`.
    // slither: weak-prng: modulo is calendar arithmetic (weekday / minute-of-day), not randomness
    // slither-disable-start weak-prng
    function isDst(uint256 timestamp) public pure returns (bool) {
        (uint256 year,,) = civilFromDays(timestamp / 1 days);
        // DST starts 2nd Sunday of March at 02:00 EST == 07:00 UTC
        uint256 march1 = daysFromCivil(year, 3, 1);
        uint256 startDay = march1 + ((7 - weekday(march1)) % 7) + 7;
        // DST ends 1st Sunday of November at 02:00 EDT == 06:00 UTC
        uint256 nov1 = daysFromCivil(year, 11, 1);
        uint256 endDay = nov1 + ((7 - weekday(nov1)) % 7);
        return timestamp >= startDay * 1 days + 7 hours && timestamp < endDay * 1 days + 6 hours;
    }
    // slither-disable-end weak-prng

    // slither: weak-prng: modulo is calendar arithmetic (weekday / minute-of-day), not randomness
    // slither-disable-start weak-prng
    function _local(uint256 timestamp) internal pure returns (uint256 day, uint256 minute) {
        uint256 offset = isDst(timestamp) ? 4 hours : 5 hours;
        uint256 local = timestamp > offset ? timestamp - offset : 0;
        day = local / 1 days;
        minute = (local % 1 days) / 60;
    }
    // slither-disable-end weak-prng

    // Howard Hinnant's civil-date algorithms (public domain), restricted to dates >= 1970.
    // slither: divide-before-multiply: Hinnant civil-date algorithm relies on intentional floor division
    // slither-disable-start divide-before-multiply
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }
    // slither-disable-end divide-before-multiply

    // slither: divide-before-multiply: Hinnant civil-date algorithm relies on intentional floor division
    // slither-disable-start divide-before-multiply
    function civilFromDays(uint256 z) public pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
    // slither-disable-end divide-before-multiply
}
