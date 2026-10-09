// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {PairVault} from "../src/PairVault.sol";
import {StrategyEngine} from "../src/StrategyEngine.sol";
import {IPairVault} from "../src/interfaces/IPairwise.sol";

contract LifecycleTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seedHistory(30);
        _toNextOpen();
    }

    function test_fullCycle_shortSpread_meanReversion() public {
        _deposit(alice, 100_000e6);
        (int256 z0, bool ok0) = spread.zScore(pairId);
        assertTrue(ok0, "z ok");
        emit log_named_int("z0", z0);
        (int256 corr,) = spread.correlation(pairId);
        emit log_named_int("corr", corr);

        _pushZ(2.5e18);
        (StrategyEngine.Action a, uint8 d,) = engine.check(address(vault));
        assertEq(uint8(a), uint8(StrategyEngine.Action.ARM));
        assertEq(d, uint8(IPairVault.State.SHORT_SPREAD));
        _armAndEnter();
        assertEq(uint8(vault.state()), uint8(IPairVault.State.SHORT_SPREAD));

        (uint256 l, uint256 s, uint256 ltv, uint256 maxLtv) = vault.legs();
        emit log_named_uint("long", l);
        emit log_named_uint("short", s);
        emit log_named_uint("ltv", ltv);
        assertLe(ltv, maxLtv);
        uint256 navIn = vault.totalAssets();

        // ratio reverts to the mean -> exit
        vm.warp(block.timestamp + 1 days);
        _pushZ(0);
        (a, d,) = engine.check(address(vault));
        assertEq(uint8(a), uint8(StrategyEngine.Action.EXIT));
        assertEq(d, engine.EXIT_MEAN_REVERSION());
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        emit log_named_uint("nav in", navIn);
        emit log_named_uint("nav out", vault.totalAssets());
        assertGt(vault.totalAssets(), 100_000e6, "profitable trade");
    }
}
