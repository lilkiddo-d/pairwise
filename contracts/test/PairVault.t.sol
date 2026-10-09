// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PairVault} from "../src/PairVault.sol";
import {IPairVault} from "../src/interfaces/IPairwise.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";

contract PairVaultTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seedHistory(30);
        _toNextOpen();
    }

    // ---------------------------------------------------------------- helpers

    function _enter(int256 z) internal {
        _pushZ(z);
        _armAndEnter();
        assertTrue(vault.state() != IPairVault.State.FLAT, "entered");
    }

    function _toWeekend() internal {
        // move to the next Saturday noon UTC
        uint256 day = block.timestamp / 1 days;
        uint256 wd = (day + 4) % 7;
        uint256 toSat = (6 + 7 - wd) % 7;
        if (toSat == 0) toSat = 7;
        vm.warp((day + toSat) * 1 days + 12 hours);
        _refreshFeeds();
    }

    function _pps() internal view returns (uint256) {
        return vault.totalAssets() * 1e18 / (vault.totalSupply() + 1);
    }

    // ---------------------------------------------------------------- flat accounting

    function test_metadata() public view {
        assertEq(vault.decimals(), 12);
        assertEq(vault.asset(), address(usdg));
        assertEq(vault.name(), "Pairwise AAA/BBB");
        assertEq(vault.tokenA(), address(tokA));
        assertEq(vault.tokenB(), address(tokB));
        assertEq(vault.shortToken(), address(0));
        assertEq(vault.longToken(), address(0));
        assertEq(vault.capacityUsdg(IPairVault.State.FLAT), 0);
        assertFalse(vault.needsRebalance());
        (uint256 l, uint256 s, uint256 ltv, uint256 m) = vault.legs();
        assertEq(l + s + ltv + m, 0);
    }

    function test_initOnlyOnce() public {
        PairVault.InitParams memory p;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(p);
        PairVault impl = new PairVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    function test_flatDepositRedeemAnytime() public {
        vm.prank(admin);
        vault.setFees(0, 0);
        uint256 shares = _deposit(alice, 1_000e6);
        assertEq(shares, 1_000e6 * 1e6);
        assertEq(vault.totalAssets(), 1_000e6);
        _toWeekend();
        assertFalse(clock.isMarketOpen());
        vm.prank(alice);
        uint256 out = vault.redeem(shares / 2, alice, alice);
        assertEq(out, 500e6);
        vm.prank(alice);
        uint256 burned = vault.withdraw(100e6, alice, alice);
        assertEq(burned, 100e6 * 1e6);
        assertEq(usdg.balanceOf(alice), 600e6);
        uint256 a = vault.mint(0, alice); // mint path with zero is allowed
        assertEq(a, 0);
    }

    function test_mintPath() public {
        usdg.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdg.approve(address(vault), type(uint256).max);
        uint256 assets = vault.mint(500e12, bob);
        vm.stopPrank();
        assertEq(assets, 500e6);
        assertEq(vault.maxMint(bob), type(uint256).max);
    }

    function test_inflationAttackMitigated() public {
        // attacker: 1 wei deposit + large donation; victim still gets fair value
        vm.prank(admin);
        vault.setFees(0, 0); // a donation is otherwise (correctly) charged as performance
        _deposit(bob, 1);
        usdg.mint(address(vault), 10_000e6);
        _deposit(alice, 10_000e6);
        uint256 victimValue = vault.convertToAssets(vault.balanceOf(alice));
        assertGt(victimValue, 9_999e6);
    }

    function test_depositCapAndMaxDeposit() public {
        PairVault.Config memory c = defaultConfig();
        c.depositCap = 1_000e6;
        vm.prank(admin);
        vault.setConfig(c);
        assertEq(vault.maxDeposit(alice), 1_000e6);
        _deposit(alice, 600e6);
        assertEq(vault.maxDeposit(alice), 400e6);
        assertEq(vault.maxMint(alice), 400e6 * 1e6);
        usdg.mint(alice, 500e6);
        vm.startPrank(alice);
        usdg.approve(address(vault), 500e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 500e6, 400e6));
        vault.deposit(500e6, alice);
        vm.stopPrank();
        usdg.mint(address(vault), 1_000e6);
        assertEq(vault.maxDeposit(alice), 0);
    }

    // ---------------------------------------------------------------- positions

    function test_enterLongSpread_invariants() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.LONG_SPREAD));
        assertEq(vault.longToken(), address(tokA));
        assertEq(vault.shortToken(), address(tokB));
        (uint256 l, uint256 s, uint256 ltv, uint256 maxLtv) = vault.legs();
        assertApproxEqRel(l, s, 0.01e18);
        assertLe(ltv, maxLtv);
        // capital: notional = 90% * NAV * targetLtv(0.65 * 0.625)
        assertApproxEqRel(l, 100_000e6 * 9 / 10 * 40625 / 100000, 0.001e18);
        assertApproxEqAbs(vault.totalAssets(), 100_000e6, 2);
        assertGt(vault.entryTime(), 0);
        assertEq(vault.entryZ() < 0, true);
        assertGt(vault.capacityUsdg(IPairVault.State.SHORT_SPREAD), 0);
    }

    function test_enterGuards() public {
        vm.expectRevert(PairVault.OnlyEngine.selector);
        vault.enter(IPairVault.State.LONG_SPREAD, 0, block.timestamp);
        vm.expectRevert(PairVault.OnlyEngine.selector);
        vault.exit(1, 0, block.timestamp);
        vm.expectRevert(PairVault.OnlyEngine.selector);
        vault.rebalance(block.timestamp);
        vm.startPrank(address(engine));
        vm.expectRevert(PairVault.BadState.selector);
        vault.enter(IPairVault.State.FLAT, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PairVault.NotionalTooSmall.selector, 0));
        vault.enter(IPairVault.State.LONG_SPREAD, 0, block.timestamp);
        vm.expectRevert(PairVault.BadState.selector);
        vault.exit(1, 0, block.timestamp);
        vm.expectRevert(PairVault.BadState.selector);
        vault.rebalance(block.timestamp);
        vm.stopPrank();
        _deposit(alice, 10_000e6);
        vm.prank(address(engine));
        vault.enter(IPairVault.State.LONG_SPREAD, 0, block.timestamp);
        vm.prank(address(engine));
        vm.expectRevert(PairVault.BadState.selector);
        vault.enter(IPairVault.State.SHORT_SPREAD, 0, block.timestamp);
    }

    function test_entryRespectsMaxNotionalAndCapacity() public {
        PairVault.Config memory c = defaultConfig();
        c.maxNotionalUsdg = 5_000e6;
        vm.prank(admin);
        vault.setConfig(c);
        _deposit(alice, 100_000e6);
        assertEq(vault.capacityUsdg(IPairVault.State.LONG_SPREAD), 5_000e6);
        c.maxNotionalUsdg = 0;
        vm.prank(admin);
        vault.setConfig(c);
        // B liquidity is 20k BBB; cap at 90% of venue liquidity
        _deposit(bob, 10_000_000e6);
        assertEq(vault.capacityUsdg(IPairVault.State.LONG_SPREAD), oracle.convert(address(tokB), 20_000e18, address(usdg)) * 9 / 10);
    }

    function test_inPositionDeposit_noDilution() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        uint256 ppsBefore = _pps();
        _deposit(bob, 50_000e6);
        assertGe(_pps() + 1, ppsBefore, "no dilution on deposit");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(bob)), 50_000e6, 1e12);
        assertEq(vault.netFlowsSinceEntry(), int256(50_000e6));
    }

    function test_inPositionDepositRequiresOpenMarket() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        _toWeekend();
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxRedeem(alice), 0);
        usdg.mint(bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(vault), 1e6);
        vm.expectRevert(PairVault.MarketClosed.selector);
        vault.deposit(1e6, bob);
        vm.expectRevert(PairVault.MarketClosed.selector);
        vault.mint(1e12, bob);
        vm.stopPrank();
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, alice, sh, 0));
        vault.redeem(sh, alice, alice);
    }

    function test_inPositionRedeem_proRata_noDilution() public {
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _enter(2.5e18);
        router.setSlippageBps(30); // real execution cost on the way out
        uint256 ppsBefore = _pps();
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 preview = vault.previewRedeem(sh);
        vm.prank(alice);
        uint256 got = vault.redeem(sh, alice, alice, preview);
        assertGe(got, preview, "preview is a lower bound");
        assertLt(got, 50_000e6, "redeemer pays own execution");
        assertGe(_pps() + 1, ppsBefore, "remaining holders not diluted");
        (uint256 l, uint256 s, uint256 ltv, uint256 maxLtv) = vault.legs();
        assertApproxEqRel(l, s, 0.02e18);
        assertLe(ltv, maxLtv);
    }

    function test_inPositionRedeem_minAssets() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        uint256 sh = vault.balanceOf(alice) / 4;
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(sh, alice, alice, 25_001e6);
    }

    function test_inPositionWithdrawExact() public {
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _enter(-2.5e18);
        uint256 ppsBefore = _pps();
        vm.prank(alice);
        uint256 burned = vault.withdraw(10_000e6, alice, alice);
        assertEq(usdg.balanceOf(alice), 10_000e6);
        assertGt(burned, 0);
        assertGe(_pps() + 1, ppsBefore);
        assertEq(vault.maxWithdraw(alice), vault.previewRedeem(vault.balanceOf(alice)));
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1_000_000e6, alice, alice);
    }

    function test_inPositionWithdraw_slippageRevert() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        // execution worse than the preview haircut allows -> swap bounds revert
        router.setSlippageBps(80);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(10_000e6, alice, alice);
    }

    function test_fullRedemptionGoesFlat() public {
        vm.prank(admin);
        vault.setFees(0, 0);
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(sh, alice, alice);
        assertApproxEqRel(got, 100_000e6, 0.001e18);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        assertEq(vault.totalSupply(), 0);
    }

    function test_exitRealizesPnl() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18);
        vm.warp(block.timestamp + 1 days);
        _pushZ(0);
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        assertGt(vault.totalAssets(), 100_000e6);
        assertEq(usdg.balanceOf(address(longAd)), 0);
        assertEq(usdg.balanceOf(address(shortAd)), 0);
        assertEq(tokA.balanceOf(address(longAd)), 0);
    }

    function test_emergencyExit() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        _toWeekend();
        vm.prank(guardian);
        vault.pause();
        vm.expectRevert();
        vault.emergencyExit(100, block.timestamp);
        vm.startPrank(guardian);
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.emergencyExit(501, block.timestamp);
        vault.emergencyExit(100, block.timestamp);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        vm.expectRevert(PairVault.BadState.selector);
        vault.emergencyExit(100, block.timestamp);
        vm.stopPrank();
        // flat + paused: withdrawals still work
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        assertGt(vault.redeem(sh, alice, alice), 99_000e6);
    }

    function test_pauseBlocksDepositsAndInPositionExits() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
        vm.prank(guardian);
        vault.pause();
        assertEq(vault.maxDeposit(bob), 0);
        usdg.mint(bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(vault), 1e6);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(1e6, bob);
        vm.stopPrank();
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
        vm.prank(admin);
        vault.unpause();
        assertGt(vault.maxRedeem(alice), 0);
    }

    // ---------------------------------------------------------------- rebalancing

    function test_rebalance_topUpCollateral() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // long A, short B
        (, int256 b,,,) = feedB.latestRoundData();
        (, int256 a,,,) = feedA.latestRoundData();
        // B (short) +16% and A +16%: LTV drifts above 75% of LLTV, hedge unchanged
        feedB.setPrice(b * 116 / 100);
        feedA.setPrice(a * 116 / 100);
        feedUsdg.setPrice(1e8);
        (,, uint256 ltv0,) = vault.legs();
        assertGt(ltv0, uint256(0.625e18) * 75 / 100);
        assertTrue(vault.needsRebalance());
        vm.prank(address(engine));
        vault.rebalance(block.timestamp);
        (,, uint256 ltv1,) = vault.legs();
        assertApproxEqRel(ltv1, uint256(0.625e18) * 65 / 100, 0.01e18);
        assertFalse(vault.needsRebalance());
    }

    function test_rebalance_deleverageWhenReserveTooSmall() public {
        PairVault.Config memory c = defaultConfig();
        c.deployBps = 9_500;
        vm.prank(admin);
        vault.setConfig(c);
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // long A, short B
        (, int256 b,,,) = feedB.latestRoundData();
        (, int256 a,,,) = feedA.latestRoundData();
        feedB.setPrice(b * 120 / 100);
        feedA.setPrice(a * 120 / 100);
        feedUsdg.setPrice(1e8);
        (uint256 l0,,,) = vault.legs();
        vm.prank(address(engine));
        vault.rebalance(block.timestamp);
        (uint256 l1, uint256 s1, uint256 ltv1, uint256 maxLtv) = vault.legs();
        assertLt(l1, l0, "both legs cut");
        assertLe(ltv1, maxLtv);
        assertApproxEqRel(l1, s1, 0.06e18);
    }

    function test_rebalance_trimShortWhenOverHedged() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // long A ($A), short B
        (, int256 a,,,) = feedA.latestRoundData();
        feedA.setPrice(a * 93 / 100); // long leg shrinks 7%
        _refreshFeeds();
        assertTrue(vault.needsRebalance());
        vm.prank(address(engine));
        vault.rebalance(block.timestamp);
        (uint256 l, uint256 s,,) = vault.legs();
        assertApproxEqRel(l, s, 0.03e18);
        assertFalse(vault.needsRebalance());
    }

    function test_rebalance_trimLongWhenUnderHedged() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // long A, short B
        (, int256 a,,,) = feedA.latestRoundData();
        feedA.setPrice(a * 107 / 100); // long leg grows 7%
        _refreshFeeds();
        vm.prank(address(engine));
        vault.rebalance(block.timestamp);
        (uint256 l, uint256 s,,) = vault.legs();
        assertApproxEqRel(l, s, 0.03e18);
    }

    function test_rebalance_shortSpreadTrimsLongB() public {
        _deposit(alice, 100_000e6);
        _enter(2.5e18); // short A, long B
        (, int256 b,,,) = feedB.latestRoundData();
        feedB.setPrice(b * 108 / 100); // long B leg grows
        _refreshFeeds();
        assertTrue(vault.needsRebalance());
        vm.prank(address(engine));
        vault.rebalance(block.timestamp);
        (uint256 l, uint256 s,,) = vault.legs();
        assertApproxEqRel(l, s, 0.03e18);
    }

    function test_bandBreachReverts() public {
        // a pool far worse than the oracle cannot push the vault outside the band: it reverts on slippage instead
        _deposit(alice, 100_000e6);
        _pushZ(2.5e18);
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        vm.warp(block.timestamp + 16 minutes);
        _refreshFeeds();
        router.setPriceSkewBps(200);
        vm.prank(keeper);
        vm.expectRevert();
        engine.execute(address(vault), block.timestamp + 10 minutes);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
    }

    function test_liquidatedShortStillExits() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // short B
        (, int256 b,,,) = feedB.latestRoundData();
        feedB.setPrice(b * 180 / 100);
        _refreshFeeds();
        // liquidator takes the short position
        address liq = makeAddr("liq");
        tokB.mint(liq, 10_000e18);
        vm.startPrank(liq);
        tokB.approve(address(morpho), type(uint256).max);
        morpho.liquidate(mpB, address(shortAd));
        vm.stopPrank();
        assertEq(shortAd.borrowedAssets(address(tokB)), 0);
        assertEq(shortAd.ltv(address(tokB)), 0);
        uint256 navAfterLiq = vault.totalAssets();
        assertLt(navAfterLiq, 100_000e6);
        vm.prank(guardian);
        vault.emergencyExit(100, block.timestamp);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        assertApproxEqRel(vault.totalAssets(), navAfterLiq, 0.01e18);
    }

    function test_totalAssetsFloorsAtZero() public {
        _deposit(alice, 100_000e6);
        _enter(-2.5e18); // short B
        // drain idle + long so the short's negative equity dominates
        uint256 idle = usdg.balanceOf(address(vault));
        vm.prank(address(vault));
        usdg.transfer(address(0xdead), idle);
        (, int256 b,,,) = feedB.latestRoundData();
        (, int256 a,,,) = feedA.latestRoundData();
        feedA.setPrice(a / 1000);
        feedB.setPrice(b * 10);
        feedUsdg.setPrice(1e8);
        assertLt(shortAd.equity(address(tokB)), 0);
        assertEq(vault.totalAssets(), 0);
    }

    // ---------------------------------------------------------------- fees

    function test_managementFee() public {
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();
        uint256 fcAssets = vault.convertToAssets(vault.balanceOf(address(feeCollector)));
        assertApproxEqRel(fcAssets, 1_000e6, 0.001e18);
        assertEq(feeCollector.pendingManagementShares(address(vault)), vault.balanceOf(address(feeCollector)));
        assertEq(feeCollector.pendingPerformanceShares(address(vault)), 0);
        // second accrual in the same block is a no-op
        uint256 bal = vault.balanceOf(address(feeCollector));
        vault.accrueFees();
        assertEq(vault.balanceOf(address(feeCollector)), bal);
    }

    function test_performanceFeeOverHighWaterMark() public {
        vm.prank(admin);
        vault.setFees(0, 1_500);
        _deposit(alice, 100_000e6);
        uint256 hwm0 = vault.highWaterMark();
        usdg.mint(address(vault), 10_000e6); // +10% gain
        vm.warp(block.timestamp + 1);
        vault.accrueFees();
        uint256 fee = vault.convertToAssets(vault.balanceOf(address(feeCollector)));
        assertApproxEqRel(fee, 1_500e6, 0.001e18);
        assertGt(vault.highWaterMark(), hwm0);
        // loss then partial recovery below HWM: no new perf fee
        vm.prank(address(vault));
        usdg.transfer(address(0xdead), 5_000e6);
        vm.warp(block.timestamp + 1);
        vault.accrueFees();
        usdg.mint(address(vault), 2_000e6);
        vm.warp(block.timestamp + 1);
        uint256 before = vault.balanceOf(address(feeCollector));
        vault.accrueFees();
        assertEq(vault.balanceOf(address(feeCollector)), before);
    }

    function test_previewsIncludePendingFees() public {
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 180 days);
        uint256 preview = vault.previewDeposit(1_000e6);
        uint256 got = _deposit(bob, 1_000e6);
        assertEq(got, preview);
    }

    function test_feeCapsAndSetters() public {
        vm.startPrank(admin);
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setFees(101, 0);
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setFees(0, 1_501);
        vault.setFees(50, 1_000);
        assertEq(vault.managementFeeBps(), 50);
        vault.setFeeCollector(address(0));
        assertEq(vault.feeCollector(), address(0));
        vm.stopPrank();
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();
        assertEq(vault.totalSupply(), vault.balanceOf(alice)); // no fees without a collector
        vm.expectRevert();
        vault.setFees(0, 0);
    }

    // ---------------------------------------------------------------- admin

    function test_configValidation() public {
        PairVault.Config memory c;
        vm.startPrank(admin);
        c = defaultConfig();
        c.maxSlippageBps = 301;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.deployBps = 0;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.deployBps = 9_501;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.targetLtvBps = 0;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.targetLtvBps = 7_600;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.rebalanceLtvBps = 8_100;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.maxLtvBps = 9_100;
        c.rebalanceLtvBps = 9_050;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.bandBps = 0;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.bandBps = 2_001;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.maxTiltBps = 1_000;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.rebalanceTriggerBps = 0;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        c = defaultConfig();
        c.rebalanceTriggerBps = 1_000;
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setConfig(c);
        vm.stopPrank();
        vm.expectRevert();
        vault.setConfig(defaultConfig());
    }

    function test_adminSetters() public {
        vm.startPrank(admin);
        vault.setEngine(address(0xE));
        assertEq(vault.engine(), address(0xE));
        vault.setEngine(address(engine));
        OracleAdapter o2 = new OracleAdapter(admin);
        vault.setOracle(IPriceOracle(address(o2)));
        assertEq(address(vault.oracle()), address(o2));
        assertEq(address(longAd.oracle()), address(o2));
        assertEq(address(shortAd.oracle()), address(o2));
        vm.expectRevert(PairVault.BadConfig.selector);
        vault.setOracle(IPriceOracle(address(0)));
        vm.stopPrank();
        vm.expectRevert();
        vault.setEngine(address(0));
        vm.expectRevert();
        vault.setCompliance(address(0));
    }

    function test_complianceGatesDepositsAndTransfersOnly() public {
        _deposit(alice, 1_000e6);
        vm.startPrank(admin);
        compliance.setEnabled(true);
        address[] memory list = new address[](1);
        list[0] = alice;
        compliance.setAllowlisted(list, true);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0);
        usdg.mint(bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(PairVault.NotAllowed.selector, bob));
        vault.deposit(1e6, bob);
        vm.stopPrank();
        // allowlisted caller depositing for a non-allowlisted receiver
        usdg.mint(alice, 1e6);
        vm.startPrank(alice);
        usdg.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(PairVault.NotAllowed.selector, bob));
        vault.deposit(1e6, bob);
        vm.expectRevert(abi.encodeWithSelector(PairVault.NotAllowed.selector, bob));
        vault.transfer(bob, 1);
        // withdrawals are never gated, even to a non-allowlisted receiver
        vault.redeem(vault.balanceOf(alice), bob, alice);
        vm.stopPrank();
        assertEq(usdg.balanceOf(bob), 1_000e6 + 1e6);

        // disabling the registry restores open access
        vm.prank(admin);
        vault.setCompliance(address(0));
        _deposit(bob, 1e6);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_flatRoundTripNeverProfits(uint256 a, uint256 b) public {
        a = bound(a, 1, 1e15);
        b = bound(b, 1, 1e15);
        _deposit(alice, a);
        uint256 sh = _deposit(bob, b);
        vm.prank(bob);
        uint256 out = vault.redeem(sh, bob, bob);
        assertLe(out, b);
        assertGe(vault.convertToAssets(vault.balanceOf(alice)) + 1, a > 0 ? a - 1 : 0);
    }

    function testFuzz_inPositionRedeemNoDilution(uint256 frac, uint256 slipBps) public {
        vm.prank(admin);
        vault.setFees(0, 0);
        _deposit(alice, 100_000e6);
        _deposit(bob, 50_000e6);
        _enter(2.5e18);
        router.setSlippageBps(bound(slipBps, 0, 50));
        uint256 sh = vault.balanceOf(bob) * bound(frac, 1, 9_999) / 10_000;
        uint256 before = vault.convertToAssets(1e12);
        uint256 preview = vault.previewRedeem(sh);
        vm.prank(bob);
        uint256 got = vault.redeem(sh, bob, bob);
        assertGe(got, preview);
        assertGe(vault.convertToAssets(1e12) + 1, before);
        (,, uint256 ltv, uint256 maxLtv) = vault.legs();
        assertLe(ltv, maxLtv);
    }
}
