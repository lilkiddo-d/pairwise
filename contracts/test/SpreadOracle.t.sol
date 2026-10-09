// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {SpreadOracle} from "../src/SpreadOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20, MockAggregator} from "./mocks/Mocks.sol";

contract SpreadOracleTest is Fixture {
    function test_registerValidation() public {
        vm.startPrank(admin);
        spread.grantRole(spread.REGISTRAR_ROLE(), admin);
        vm.expectRevert(SpreadOracle.InvalidTokens.selector);
        spread.registerPair(address(0), address(tokB), 30);
        vm.expectRevert(SpreadOracle.InvalidTokens.selector);
        spread.registerPair(address(tokA), address(tokA), 30);
        vm.expectRevert(SpreadOracle.InvalidWindow.selector);
        spread.registerPair(address(tokA), address(tokB), 9);
        vm.expectRevert(SpreadOracle.InvalidWindow.selector);
        spread.registerPair(address(tokA), address(tokB), 65);
        MockERC20 nofeed = new MockERC20("X", "X", 18);
        vm.expectRevert(SpreadOracle.InvalidTokens.selector);
        spread.registerPair(address(tokA), address(nofeed), 30);
        uint256 id = spread.registerPair(address(tokB), address(tokA), 20);
        assertEq(id, 2);
        vm.stopPrank();
        vm.expectRevert();
        spread.registerPair(address(tokA), address(tokB), 30);
        vm.expectRevert(SpreadOracle.UnknownPair.selector);
        spread.hedgeRatio(99);
    }

    function test_recordCloseRules() public {
        vm.expectRevert(SpreadOracle.NotAfterClose.selector); // market open
        spread.recordClose(pairId);
        _toNextClose();
        spread.recordClose(pairId);
        vm.expectRevert(SpreadOracle.AlreadyRecorded.selector);
        spread.recordClose(pairId);
        SpreadOracle.Pair memory p = spread.getPair(pairId);
        assertEq(p.count, 1);
        assertEq(p.lastDay, clock.etDay(block.timestamp));
    }

    function test_recordClosesBatch() public {
        _toNextClose();
        uint256[] memory ids = new uint256[](1);
        ids[0] = pairId;
        spread.recordCloses(ids);
        assertEq(spread.getPair(pairId).count, 1);
        uint256[] memory big = new uint256[](33);
        vm.expectRevert(SpreadOracle.InvalidWindow.selector);
        spread.recordCloses(big);
    }

    function test_ringBufferWraps() public {
        _seedHistory(70);
        SpreadOracle.Pair memory p = spread.getPair(pairId);
        assertEq(p.count, 64);
        (uint64[] memory d, uint256[] memory a, uint256[] memory b) = spread.getCloses(pairId);
        assertEq(d.length, 64);
        for (uint256 i = 1; i < d.length; ++i) {
            assertGt(d[i], d[i - 1], "chronological");
        }
        assertEq(d[63], p.lastDay);
        assertGt(a[0], 0);
        assertGt(b[0], 0);
    }

    function test_statsMatchReference() public {
        _seedHistory(40);
        (uint256 mean, uint256 std, uint256 n) = spread.ratioStats(pairId);
        assertEq(n, 30);
        (, uint256[] memory a, uint256[] memory b) = spread.getCloses(pairId);
        uint256 sum;
        uint256 start = a.length - 30;
        for (uint256 i = start; i < a.length; ++i) {
            sum += a[i] * 1e18 / b[i];
        }
        uint256 m = sum / 30;
        assertEq(mean, m);
        uint256 ss;
        for (uint256 i = start; i < a.length; ++i) {
            uint256 r = a[i] * 1e18 / b[i];
            uint256 dd = r > m ? r - m : m - r;
            ss += dd * dd;
        }
        assertApproxEqAbs(std, _sqrt(ss / 29), 1);

        _toNextOpen();
        (int256 z, bool ok) = spread.zScore(pairId);
        assertTrue(ok);
        uint256 cur = spread.currentRatio(pairId);
        int256 expected = (int256(cur) - int256(mean)) * 1e18 / int256(std);
        assertEq(z, expected);
    }

    function test_notEnoughData() public {
        _seedHistory(5);
        (, bool ok) = spread.zScore(pairId);
        assertFalse(ok);
        (, bool cok) = spread.correlation(pairId);
        assertFalse(cok);
        (, bool bok) = spread.beta(pairId);
        assertFalse(bok);
        (uint256 mean, uint256 std, uint256 n) = spread.ratioStats(pairId);
        assertEq(n, 5);
        assertGt(mean, 0);
        assertGt(std, 0);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(SpreadOracle.NotEnoughData.selector);
        spread.updateHedgeRatio(pairId);
    }

    function test_flatSeriesHasNoZ() public {
        for (uint256 i; i < 12; ++i) {
            _toNextClose();
            _setPrices(100e8, 50e8);
            spread.recordClose(pairId);
        }
        (, bool ok) = spread.zScore(pairId);
        assertFalse(ok); // zero stdev
        (, bool cok) = spread.correlation(pairId);
        assertFalse(cok); // zero variance
        (, bool bok) = spread.beta(pairId);
        assertFalse(bok);
        (uint256 mean, uint256 std,) = spread.ratioStats(pairId);
        assertEq(mean, 2e18);
        assertEq(std, 0);
    }

    function test_correlationAndBeta() public {
        _seedHistory(30);
        (int256 corr, bool ok) = spread.correlation(pairId);
        assertTrue(ok);
        assertGt(corr, 0.85e18);
        assertLe(corr, 1e18 + 1e9);
        (int256 b, bool bok) = spread.beta(pairId);
        assertTrue(bok);
        assertApproxEqRel(uint256(b), 1e18, 0.15e18);
    }

    function test_hedgeRatioWeeklyAndClamped() public {
        // freshly registered: weekly gate is closed
        vm.expectRevert(SpreadOracle.TooEarly.selector);
        spread.updateHedgeRatio(pairId);
        // A moves 3x B -> beta ~3 -> clamped to 2
        uint256 pb = 50e8;
        uint256 pa = 100e8;
        for (uint256 i; i < 20; ++i) {
            _toNextClose();
            int256 r = (i % 2 == 0) ? int256(100) : int256(-90);
            pb = uint256(int256(pb) + int256(pb) * r / 10_000);
            pa = uint256(int256(pa) + int256(pa) * (3 * r) / 10_000);
            _setPrices(pa, pb);
            spread.recordClose(pairId);
        }
        spread.updateHedgeRatio(pairId);
        assertEq(spread.hedgeRatio(pairId), 2e18);
        vm.expectRevert(SpreadOracle.TooEarly.selector);
        spread.updateHedgeRatio(pairId);
    }

    function test_hedgeRatioClampedLow() public {
        // A moves opposite to B -> negative beta -> 0.5 floor
        uint256 pb = 50e8;
        uint256 pa = 100e8;
        for (uint256 i; i < 20; ++i) {
            _toNextClose();
            int256 r = (i % 2 == 0) ? int256(100) : int256(-90);
            pb = uint256(int256(pb) + int256(pb) * r / 10_000);
            pa = uint256(int256(pa) - int256(pa) * r / 10_000);
            _setPrices(pa, pb);
            spread.recordClose(pairId);
        }
        vm.warp(block.timestamp + 8 days);
        spread.updateHedgeRatio(pairId);
        assertEq(spread.hedgeRatio(pairId), 0.5e18);
    }

    function test_adminSetters() public {
        vm.startPrank(admin);
        vm.expectRevert(SpreadOracle.InvalidWindow.selector);
        spread.setWindow(pairId, 5);
        vm.expectRevert(SpreadOracle.InvalidWindow.selector);
        spread.setWindow(pairId, 100);
        spread.setWindow(pairId, 20);
        assertEq(spread.getPair(pairId).window, 20);
        spread.setOracle(IPriceOracle(address(oracle)));
        vm.stopPrank();
        vm.expectRevert();
        spread.setWindow(pairId, 20);
        (address a, address b) = spread.pairTokens(pairId);
        assertEq(a, address(tokA));
        assertEq(b, address(tokB));
    }

    // ---------------------------------------------------------------- trustless seeding

    /// @dev Writes feed rounds so that round (base+i) is the last update before close of day i and
    ///      round (base+i)+1 lands after it. Returns the round ids per leg.
    function _writeRounds(uint256 n) internal returns (uint64[] memory ds, uint80[] memory ra, uint80[] memory rb) {
        ds = new uint64[](n);
        ra = new uint80[](n);
        rb = new uint80[](n);
        uint256 day = clock.etDay(block.timestamp) - 3 * n; // well in the past
        uint256 k;
        uint80 id = 1000;
        while (k < n) {
            day++;
            if (!clock.isTradingDay(day)) continue;
            uint256 c = clock.closeTimestamp(day);
            int256 pb = int256(50e8 + (k % 3) * 1e8);
            int256 pa = 2 * pb + int256((k % 2) * 1e8);
            feedA.setRound(id, pa, c - 60, c - 60, id);
            feedA.setRound(id + 1, pa, c + 60, c + 60, id + 1);
            feedB.setRound(id, pb, c - 30, c - 30, id);
            feedB.setRound(id + 1, pb, c + 30, c + 30, id + 1);
            ds[k] = uint64(day);
            ra[k] = id;
            rb[k] = id;
            id += 2;
            k++;
        }
        // restore a fresh latest round
        feedA.setRound(id, 100e8, block.timestamp, block.timestamp, id);
        feedB.setRound(id, 50e8, block.timestamp, block.timestamp, id);
    }

    function test_seedFromRounds() public {
        (uint64[] memory ds, uint80[] memory ra, uint80[] memory rb) = _writeRounds(12);
        vm.prank(keeper);
        spread.seedFromRounds(pairId, ds, ra, rb);
        assertEq(spread.getPair(pairId).count, 12);
        (, bool ok) = spread.zScore(pairId);
        assertTrue(ok);
        vm.prank(keeper);
        vm.expectRevert(SpreadOracle.AlreadySeeded.selector);
        spread.seedFromRounds(pairId, ds, ra, rb);
    }

    /// @dev A quiet feed (no update between two consecutive closes) serves the same round for both days.
    function test_seedQuietFeedReusesRound() public {
        (uint64[] memory ds, uint80[] memory ra, uint80[] memory rb) = _writeRounds(12);
        // find two consecutive entries whose closes are < 26h apart (ordinary weekdays)
        uint256 k = type(uint256).max;
        for (uint256 i; i + 1 < 12; ++i) {
            if (clock.closeTimestamp(ds[i + 1]) - clock.closeTimestamp(ds[i]) <= 25 hours) {
                k = i;
                break;
            }
        }
        assertTrue(k != type(uint256).max);
        // B's round for day k stays the latest until after day k+1's close
        uint256 ck1 = clock.closeTimestamp(ds[k + 1]);
        feedB.setRound(rb[k] + 1, 50e8, ck1 + 30, ck1 + 30, rb[k] + 1);
        rb[k + 1] = rb[k];
        vm.prank(keeper);
        spread.seedFromRounds(pairId, ds, ra, rb);
        assertEq(spread.getPair(pairId).count, 12);
    }

    function test_seedRejectsOldRound() public {
        (uint64[] memory ds, uint80[] memory ra,) = _writeRounds(12);
        // a round that "prevails" at a later close but is more than 26h old there
        uint256 c0 = clock.closeTimestamp(ds[0]);
        uint256 c3 = clock.closeTimestamp(ds[3]);
        feedA.setRound(ra[0] + 1, 100e8, c3 + 60, c3 + 60, ra[0] + 1);
        feedB.setRound(ra[0] + 1, 50e8, c3 + 60, c3 + 60, ra[0] + 1);
        assertGt(c3 - c0, 26 hours);
        uint64[] memory d = new uint64[](1);
        uint80[] memory a = new uint80[](1);
        d[0] = ds[3];
        a[0] = ra[0];
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, type(uint256).max));
        spread.seedFromRounds(pairId, d, a, a);
    }

    function test_seedRejectsCherryPicks() public {
        (uint64[] memory ds, uint80[] memory ra, uint80[] memory rb) = _writeRounds(12);
        uint80[] memory bad = new uint80[](12);
        for (uint256 i; i < 12; ++i) {
            bad[i] = ra[i] + 1; // the after-close round
        }
        vm.startPrank(keeper);
        vm.expectRevert();
        spread.seedFromRounds(pairId, ds, bad, rb);
        // B rounds belong to the following day
        uint80[] memory shifted = new uint80[](12);
        for (uint256 i; i < 11; ++i) {
            shifted[i] = rb[i + 1];
        }
        shifted[11] = rb[11];
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, type(uint256).max));
        spread.seedFromRounds(pairId, ds, ra, shifted);
        // non-increasing days
        uint64[] memory rdays = new uint64[](2);
        rdays[0] = ds[1];
        rdays[1] = ds[0];
        uint80[] memory r2 = new uint80[](2);
        r2[0] = ra[1];
        r2[1] = ra[0];
        uint80[] memory r2b = new uint80[](2);
        r2b[0] = rb[1];
        r2b[1] = rb[0];
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, 1));
        spread.seedFromRounds(pairId, rdays, r2, r2b);
        // today is rejected
        uint64[] memory future = new uint64[](1);
        future[0] = uint64(clock.etDay(block.timestamp));
        uint80[] memory one = new uint80[](1);
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, 0));
        spread.seedFromRounds(pairId, future, one, one);
        // length checks
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, 0));
        spread.seedFromRounds(pairId, ds, ra, new uint80[](1));
        vm.expectRevert(abi.encodeWithSelector(SpreadOracle.BadSeed.selector, 0));
        spread.seedFromRounds(pairId, new uint64[](0), new uint80[](0), new uint80[](0));
        vm.stopPrank();
        vm.expectRevert();
        spread.seedFromRounds(pairId, ds, ra, rb);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
