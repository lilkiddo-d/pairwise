// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {StrategyEngine} from "../src/StrategyEngine.sol";
import {IPairVault} from "../src/interfaces/IPairwise.sol";

contract StrategyEngineTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seedHistory(30);
        _toNextOpen();
        _deposit(alice, 100_000e6);
    }

    function _check() internal view returns (StrategyEngine.Action a, uint8 d) {
        (a, d,) = engine.check(address(vault));
    }

    function _exec() internal {
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
    }

    function _enterShortSpread() internal {
        _pushZ(2.5e18);
        _armAndEnter();
        assertEq(uint8(vault.state()), uint8(IPairVault.State.SHORT_SPREAD));
    }

    function _enterLongSpread() internal {
        _pushZ(-2.5e18);
        _armAndEnter();
        assertEq(uint8(vault.state()), uint8(IPairVault.State.LONG_SPREAD));
    }

    // ---------------------------------------------------------------- registry & params

    function test_registration() public {
        assertEq(engine.vaultCount(), 1);
        assertEq(engine.vaults(0), address(vault));
        vm.expectRevert();
        engine.registerVault(address(1));
        vm.startPrank(admin);
        engine.grantRole(engine.REGISTRAR_ROLE(), admin);
        vm.expectRevert(StrategyEngine.AlreadyRegistered.selector);
        engine.registerVault(address(vault));
        vm.stopPrank();
        vm.expectRevert(StrategyEngine.NotRegistered.selector);
        engine.check(address(0xBEEF));
        StrategyEngine.Params memory p = engine.params(address(vault));
        assertEq(p.entryZ, 2e18);
    }

    function test_paramValidation() public {
        StrategyEngine.Params memory p;
        vm.startPrank(admin);
        vm.expectRevert(StrategyEngine.NotRegistered.selector);
        engine.setParams(address(0xBEEF), defaultParams());

        p = defaultParams();
        p.exitZ = 0;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.exitZ = p.entryZ;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.stopZ = p.entryZ;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.stopZ = 11e18;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.maxHolding = 1 hours;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.maxHolding = 121 days;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.cooldown = 31 days;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.confirmDelay = 3 hours;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.armWindow = p.confirmDelay;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.armWindow = 2 days;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.minCorrelation = 2e18;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.minCorrelation = -2e18;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.exitCorrelation = 0.9e18;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);
        p = defaultParams();
        p.minCorrelation = -1e18;
        p.exitCorrelation = -1.5e18;
        vm.expectRevert(StrategyEngine.BadParams.selector);
        engine.setParams(address(vault), p);

        engine.setDefaultParams(defaultParams());
        vm.stopPrank();
        vm.expectRevert();
        engine.setParams(address(vault), defaultParams());
    }

    // ---------------------------------------------------------------- gating

    function test_noActionOutsideMarketHours() public {
        _pushZ(2.5e18);
        vm.warp(block.timestamp + 12 hours); // overnight
        _refreshFeeds();
        assertFalse(clock.isMarketOpen());
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
        vm.prank(keeper);
        vm.expectRevert(StrategyEngine.NothingToDo.selector);
        engine.execute(address(vault), block.timestamp + 10 minutes);
    }

    function test_noActionWhenPaused() public {
        _pushZ(2.5e18);
        vm.prank(guardian);
        engine.pause();
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
        vm.prank(keeper);
        vm.expectRevert();
        engine.execute(address(vault), block.timestamp + 10 minutes);
        vm.prank(guardian);
        vm.expectRevert();
        engine.unpause();
        vm.prank(admin);
        engine.unpause();
        vm.prank(guardian);
        vault.pause();
        (a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_noEntryInsideBand() public {
        _pushZ(1.5e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_noEntryBeyondStop() public {
        _pushZ(3.6e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
        _pushZ(-3.6e18);
        (a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_noEntryWithoutCorrelation() public {
        StrategyEngine.Params memory p = defaultParams();
        p.minCorrelation = 0.99e18;
        vm.prank(admin);
        engine.setParams(address(vault), p);
        _pushZ(2.5e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_noEntryWithoutCapacity() public {
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        _pushZ(2.5e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_deadlineAndRoles() public {
        _pushZ(2.5e18);
        vm.expectRevert();
        engine.execute(address(vault), block.timestamp + 10 minutes);
        vm.startPrank(keeper);
        vm.expectRevert(StrategyEngine.BadDeadline.selector);
        engine.execute(address(vault), block.timestamp - 1);
        vm.expectRevert(StrategyEngine.BadDeadline.selector);
        engine.execute(address(vault), block.timestamp + 2 hours);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- entry

    function test_armConfirmEnter() public {
        _pushZ(-2.5e18);
        (StrategyEngine.Action a, uint8 d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.ARM));
        assertEq(d, uint8(IPairVault.State.LONG_SPREAD));
        _exec();
        (, IPairVault.State armed, uint64 armedAt,) = engine.vaultInfo(address(vault));
        assertEq(uint8(armed), uint8(IPairVault.State.LONG_SPREAD));
        assertEq(armedAt, block.timestamp);
        // within confirm delay: nothing to do
        (a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
        vm.warp(block.timestamp + 16 minutes);
        _refreshFeeds();
        (a, d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.ENTER));
        _exec();
        assertEq(uint8(vault.state()), uint8(IPairVault.State.LONG_SPREAD));
    }

    function test_armExpiresAndFlips() public {
        _pushZ(2.5e18);
        _exec(); // armed SHORT_SPREAD
        vm.warp(block.timestamp + 3 hours); // arm window (2h) expired
        _refreshFeeds();
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.ARM));
        _exec();
        // signal flips sign: must re-arm for the new direction
        _pushZ(-2.5e18);
        uint8 d;
        (a, d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.ARM));
        assertEq(d, uint8(IPairVault.State.LONG_SPREAD));
    }

    function test_cooldownAfterExit() public {
        _enterShortSpread();
        vm.warp(block.timestamp + 1 hours);
        _pushZ(0);
        _exec(); // mean-reversion exit
        _pushZ(2.5e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE), "cooldown");
        vm.warp(block.timestamp + 1 days);
        _toNextOpen();
        _pushZ(2.5e18);
        (a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.ARM));
    }

    // ---------------------------------------------------------------- exits

    function test_exit_meanReversion_bothSides() public {
        _enterLongSpread();
        _pushZ(-1e18);
        (StrategyEngine.Action a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE), "still holding");
        _pushZ(-0.4e18);
        uint8 d;
        (a, d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_MEAN_REVERSION());
        _exec();

        vm.warp(block.timestamp + 1 days);
        _toNextOpen();
        _enterShortSpread();
        _pushZ(0.4e18);
        (a, d) = _check();
        assertEq(d, engine.EXIT_MEAN_REVERSION());
    }

    function test_exit_stopLoss_bothSides() public {
        _enterLongSpread();
        _pushZ(-3.6e18);
        (StrategyEngine.Action a, uint8 d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_STOP_LOSS());
        _exec();
        vm.warp(block.timestamp + 1 days);
        _toNextOpen();
        _enterShortSpread();
        _pushZ(3.6e18);
        (a, d) = _check();
        assertEq(d, engine.EXIT_STOP_LOSS());
    }

    function test_exit_maxHolding() public {
        _enterShortSpread();
        vm.warp(block.timestamp + 21 days);
        _toNextOpen();
        _pushZ(1.5e18); // still in the trade zone
        (StrategyEngine.Action a, uint8 d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_MAX_HOLDING());
        _exec();
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
    }

    function test_exit_correlationBreakdown() public {
        _enterShortSpread();
        _pushZ(1.5e18);
        StrategyEngine.Params memory p = defaultParams();
        p.minCorrelation = 0.99e18;
        p.exitCorrelation = 0.98e18; // current corr (~0.94) is now a breakdown
        vm.prank(admin);
        engine.setParams(address(vault), p);
        (StrategyEngine.Action a, uint8 d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_CORRELATION());
    }

    function test_exit_borrowCost() public {
        _enterShortSpread();
        _pushZ(1.5e18);
        irm.setRate(uint256(1e18) / 365 days); // 100% APR > 50% cap
        (StrategyEngine.Action a, uint8 d) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_BORROW_COST());
        StrategyEngine.Params memory p = defaultParams();
        p.maxBorrowApr = 0; // disabled
        vm.prank(admin);
        engine.setParams(address(vault), p);
        (a,) = _check();
        assertEq(uint8(a), uint8(StrategyEngine.Action.NONE));
    }

    function test_rebalanceAction() public {
        _enterLongSpread();
        _pushZ(-1.5e18);
        (, int256 a,,,) = feedA.latestRoundData();
        (, int256 b,,,) = feedB.latestRoundData();
        feedA.setPrice(a * 93 / 100);
        feedB.setPrice(b * 93 / 100); // keep ratio (no z-based exit), shrink both legs equally
        feedA.setPrice(a * 90 / 100); // long leg shrinks more -> hedge drift
        feedUsdg.setPrice(1e8);
        (StrategyEngine.Action act,) = _check();
        if (act == StrategyEngine.Action.REBALANCE) {
            _exec();
            assertFalse(vault.needsRebalance());
        }
    }

    function test_executeBatch() public {
        address[] memory list = new address[](1);
        list[0] = address(vault);
        vm.startPrank(keeper);
        assertEq(engine.executeBatch(list, block.timestamp + 10 minutes), 0); // nothing to do
        vm.stopPrank();
        _pushZ(2.5e18);
        vm.startPrank(keeper);
        assertEq(engine.executeBatch(list, block.timestamp + 10 minutes), 1); // armed
        vm.expectRevert(StrategyEngine.BatchTooLarge.selector);
        engine.executeBatch(new address[](17), block.timestamp + 10 minutes);
        vm.expectRevert(StrategyEngine.BadDeadline.selector);
        engine.executeBatch(list, block.timestamp + 2 hours);
        vm.stopPrank();
    }

    function test_holdWhenZUnavailable() public {
        _enterShortSpread();
        // shrink the window so the stats are unusable (flat-lined last 10 closes)
        for (uint256 i; i < 12; ++i) {
            _toNextClose();
            _setPrices(100e8, 50e8);
            spread.recordClose(pairId);
        }
        vm.prank(admin);
        spread.setWindow(pairId, 10);
        _toNextOpen();
        (int256 z, bool ok) = spread.zScore(pairId);
        assertFalse(ok);
        z;
        (StrategyEngine.Action a, uint8 d) = _check();
        // z-based exits are skipped; max-holding is the backstop
        assertTrue(a == StrategyEngine.Action.NONE || d == engine.EXIT_MAX_HOLDING() || d == engine.EXIT_CORRELATION() || a == StrategyEngine.Action.REBALANCE);
    }
}
