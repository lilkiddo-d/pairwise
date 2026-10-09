// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketClock} from "../src/MarketClock.sol";

contract MarketClockTest is Test {
    MarketClock clock;
    address admin = makeAddr("admin");
    address cal = makeAddr("calendar");

    uint256 constant MON_1400_UTC = 1791208800; // Mon 2026-10-05 10:00 EDT
    uint256 constant DAY_MON = 20731;

    function setUp() public {
        clock = new MarketClock(admin, cal);
    }

    function test_regularSessionEdt() public view {
        // 09:30 EDT = 13:30 UTC
        assertFalse(clock.isOpenAt(1791207000 - 1)); // 09:29:59
        assertTrue(clock.isOpenAt(1791207000)); // 09:30
        assertTrue(clock.isOpenAt(MON_1400_UTC));
        assertTrue(clock.isOpenAt(1791230400 - 1)); // 15:59:59
        assertFalse(clock.isOpenAt(1791230400)); // 16:00
    }

    function test_weekendClosed() public view {
        assertFalse(clock.isOpenAt(MON_1400_UTC - 1 days)); // Sunday
        assertFalse(clock.isOpenAt(MON_1400_UTC - 2 days)); // Saturday
        assertTrue(clock.isOpenAt(MON_1400_UTC + 4 days)); // Friday
    }

    function test_dstBoundaries() public view {
        // 2026 DST starts Sun 2026-03-08 07:00 UTC, ends Sun 2026-11-01 06:00 UTC
        assertFalse(clock.isDst(1772953199));
        assertTrue(clock.isDst(1772953200));
        assertTrue(clock.isDst(1793512799));
        assertFalse(clock.isDst(1793512800));
    }

    function test_standardTimeSession() public view {
        // Mon 2026-01-05 (EST): open 14:30 UTC, close 21:00 UTC
        uint256 d = 1767571200; // 2026-01-05 00:00 UTC
        assertFalse(clock.isOpenAt(d + 14 hours + 29 minutes));
        assertTrue(clock.isOpenAt(d + 14 hours + 30 minutes));
        assertTrue(clock.isOpenAt(d + 20 hours + 59 minutes));
        assertFalse(clock.isOpenAt(d + 21 hours));
        assertEq(clock.closeTimestamp(20458), d + 21 hours);
    }

    function test_holidaysAndEarlyClose() public {
        uint256[] memory days_ = new uint256[](1);
        days_[0] = DAY_MON;
        vm.prank(cal);
        clock.setHolidays(days_, true);
        assertFalse(clock.isOpenAt(MON_1400_UTC));
        assertFalse(clock.isTradingDay(DAY_MON));
        vm.expectRevert(MarketClock.NotTradingDay.selector);
        clock.closeTimestamp(DAY_MON);
        vm.prank(cal);
        clock.setHolidays(days_, false);
        assertTrue(clock.isOpenAt(MON_1400_UTC));

        vm.prank(cal);
        clock.setEarlyCloses(days_, true);
        // 13:00 EDT = 17:00 UTC
        assertTrue(clock.isOpenAt(1791205200 + 3 hours + 59 minutes)); // 16:59 UTC
        assertFalse(clock.isOpenAt(1791205200 + 4 hours)); // 17:00 UTC
        assertTrue(clock.isAfterCloseOnTradingDay(1791205200 + 4 hours));
        assertEq(clock.closeTimestamp(DAY_MON), 1791205200 + 4 hours);
    }

    function test_afterClose() public view {
        assertFalse(clock.isAfterCloseOnTradingDay(MON_1400_UTC));
        assertTrue(clock.isAfterCloseOnTradingDay(1791230400)); // 16:00 EDT
        assertFalse(clock.isAfterCloseOnTradingDay(MON_1400_UTC - 1 days)); // Sunday
        assertEq(clock.etDay(1791230400 + 3 hours), DAY_MON); // 23:00 EDT still Monday ET
        assertEq(clock.etDay(1791230400 + 8 hours), DAY_MON + 1); // 04:00 EDT Tuesday
    }

    function test_buffers() public {
        vm.prank(admin);
        clock.setBuffers(15, 10);
        assertFalse(clock.isOpenAt(1791207000 + 14 minutes));
        assertTrue(clock.isOpenAt(1791207000 + 15 minutes));
        assertFalse(clock.isOpenAt(1791230400 - 10 minutes));
        assertTrue(clock.isMarketOpen() == clock.isOpenAt(block.timestamp));
        assertFalse(clock.isOpenAt(0)); // no underflow at genesis
        vm.prank(admin);
        vm.expectRevert(MarketClock.BufferTooLarge.selector);
        clock.setBuffers(61, 0);
    }

    function test_accessControl() public {
        uint256[] memory days_ = new uint256[](1);
        vm.expectRevert();
        clock.setHolidays(days_, true);
        vm.expectRevert();
        clock.setEarlyCloses(days_, true);
        vm.expectRevert();
        clock.setBuffers(1, 1);
        uint256[] memory big = new uint256[](65);
        vm.startPrank(cal);
        vm.expectRevert(MarketClock.BatchTooLarge.selector);
        clock.setHolidays(big, true);
        vm.expectRevert(MarketClock.BatchTooLarge.selector);
        clock.setEarlyCloses(big, true);
        vm.stopPrank();
    }

    function testFuzz_civilRoundTrip(uint256 day) public view {
        day = bound(day, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(day);
        assertEq(clock.daysFromCivil(y, m, d), day);
        assertGe(m, 1);
        assertLe(m, 12);
        assertGe(d, 1);
        assertLe(d, 31);
    }

    function testFuzz_neverOpenOnWeekends(uint256 ts) public view {
        ts = bound(ts, 1_700_000_000, 2_500_000_000);
        if (clock.isOpenAt(ts)) {
            uint256 wd = clock.weekday(clock.etDay(ts));
            assertTrue(wd >= 1 && wd <= 5);
        }
    }

    function testFuzz_sessionLength(uint256 dayOffset) public view {
        // every weekday has exactly 390 open minutes
        uint256 day = DAY_MON + bound(dayOffset, 0, 3000);
        if (!clock.isTradingDay(day)) return;
        uint256 close = clock.closeTimestamp(day);
        assertTrue(clock.isOpenAt(close - 1));
        assertFalse(clock.isOpenAt(close));
        assertTrue(clock.isOpenAt(close - 390 minutes));
        assertFalse(clock.isOpenAt(close - 390 minutes - 1));
    }
}
