// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {PairwiseTimelock} from "../src/PairwiseTimelock.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev $PAIR is never deployed by Pairwise; tests use a MockERC20 stand-in.
contract TokenAndFeesTest is Fixture {
    MockERC20 pair;

    function setUp() public override {
        super.setUp();
        pair = new MockERC20("Pairwise (mock)", "PAIR", 18);
    }

    function _setToken() internal {
        vm.prank(admin);
        hooks.setProjectToken(address(pair));
    }

    function _stake(address who, uint256 amount) internal {
        pair.mint(who, amount);
        vm.startPrank(who);
        pair.approve(address(hooks), amount);
        hooks.stake(amount);
        vm.stopPrank();
    }

    function _generateFees() internal {
        _deposit(alice, 100_000e6);
        usdg.mint(address(vault), 10_000e6); // +10% gain
        vm.warp(block.timestamp + 30 days);
        vault.accrueFees();
    }

    // ---------------------------------------------------------------- token off (default)

    function test_tokenFeaturesDisabledUntilSet() public {
        assertFalse(hooks.rewardsActive());
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.unstake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.proposePair(address(tokA), address(tokB), "x");
        assertEq(hooks.claim(), 0);

        // protocol fully works: all fees go to treasury
        _generateFees();
        uint256 got = feeCollector.harvest(address(vault), 0);
        assertGt(got, 0);
        assertEq(feeCollector.treasuryBalance(), got);
        assertEq(usdg.balanceOf(address(hooks)), 0);
    }

    function test_setProjectTokenOnceByTimelockOnly() public {
        vm.expectRevert();
        hooks.setProjectToken(address(pair));
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProjectToken(makeAddr("eoa")); // no code
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProjectToken(address(usdg)); // reward token
        hooks.setProjectToken(address(pair));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(tokA));
        vm.stopPrank();
        assertEq(address(hooks.projectToken()), address(pair));
    }

    // ---------------------------------------------------------------- staking rewards

    function test_stakersEarnShareOfPerformanceFees() public {
        _setToken();
        _stake(bob, 1_000e18);
        assertTrue(hooks.rewardsActive());
        _generateFees();
        uint256 perfShares = feeCollector.pendingPerformanceShares(address(vault));
        uint256 mgmtShares = feeCollector.pendingManagementShares(address(vault));
        assertGt(perfShares, 0);
        assertGt(mgmtShares, 0);

        uint256 assets = feeCollector.harvest(address(vault), 0);
        uint256 perfAssets = assets * perfShares / (perfShares + mgmtShares);
        uint256 toStakers = perfAssets * 5_000 / 10_000;
        assertEq(usdg.balanceOf(address(hooks)), toStakers);
        assertEq(feeCollector.treasuryBalance(), assets - toStakers);

        // streamed over 7 days
        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqRel(hooks.earned(bob), toStakers / 2, 0.001e18);
        vm.warp(block.timestamp + 10 days);
        vm.prank(bob);
        uint256 claimed = hooks.claim();
        assertApproxEqAbs(claimed, toStakers, 10);
        assertEq(usdg.balanceOf(bob), claimed);
    }

    function test_rewardsSplitProRataAndNoSniping() public {
        _setToken();
        _stake(alice, 3_000e18);
        _stake(bob, 1_000e18);
        usdg.mint(address(feeCollector), 0);
        // notify 7,000 USDG directly as the fee notifier
        usdg.mint(address(feeCollector), 7_000e6);
        vm.startPrank(address(feeCollector));
        usdg.approve(address(hooks), 7_000e6);
        hooks.notifyRewards(7_000e6);
        vm.stopPrank();
        // a sniper staking right after the notify only earns from then on
        vm.warp(block.timestamp + 6 days);
        address sniper = makeAddr("sniper");
        _stake(sniper, 4_000e18);
        vm.warp(block.timestamp + 2 days);
        assertApproxEqRel(hooks.earned(alice), 4_500e6 + 375e6, 0.001e18);
        assertApproxEqRel(hooks.earned(bob), 1_500e6 + 125e6, 0.001e18);
        assertApproxEqRel(hooks.earned(sniper), 500e6, 0.001e18);
        // topping up mid-stream carries over the remainder
        usdg.mint(address(feeCollector), 700e6);
        vm.startPrank(address(feeCollector));
        usdg.approve(address(hooks), 700e6);
        hooks.notifyRewards(700e6);
        vm.stopPrank();
        assertGt(hooks.periodFinish(), block.timestamp);
    }

    function test_notifyWithoutStakersIsCarried() public {
        _setToken();
        usdg.mint(address(feeCollector), 1_000e6);
        vm.startPrank(address(feeCollector));
        usdg.approve(address(hooks), 1_000e6);
        hooks.notifyRewards(1_000e6);
        vm.stopPrank();
        assertEq(hooks.undistributed(), 1_000e6);
        _stake(bob, 1e18);
        usdg.mint(address(feeCollector), 1);
        vm.startPrank(address(feeCollector));
        usdg.approve(address(hooks), 1);
        hooks.notifyRewards(1);
        vm.stopPrank();
        assertEq(hooks.undistributed(), 0);
        vm.warp(block.timestamp + 8 days);
        assertApproxEqAbs(hooks.earned(bob), 1_000e6 + 1, 10);
        vm.expectRevert();
        hooks.notifyRewards(1); // only the FeeCollector
    }

    function test_unstakeAndGuards() public {
        _setToken();
        _stake(bob, 100e18);
        vm.startPrank(bob);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.unstake(0);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.unstake(101e18);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.stake(0);
        hooks.unstake(40e18);
        vm.stopPrank();
        assertEq(hooks.staked(bob), 60e18);
        assertEq(pair.balanceOf(bob), 40e18);
        // pause blocks staking/proposals, never unstaking
        vm.prank(guardian);
        hooks.pause();
        pair.mint(bob, 1e18);
        vm.startPrank(bob);
        pair.approve(address(hooks), 1e18);
        vm.expectRevert();
        hooks.stake(1e18);
        hooks.unstake(60e18);
        vm.stopPrank();
        vm.prank(admin);
        hooks.unpause();
    }

    // ---------------------------------------------------------------- proposals

    function test_pairProposals() public {
        _setToken();
        _stake(bob, 999e18);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.BelowThreshold.selector);
        hooks.proposePair(address(tokA), address(tokB), "below");
        _stake(bob, 1e18);
        vm.startPrank(bob);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.proposePair(address(tokA), address(tokA), "same");
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.proposePair(address(0), address(tokA), "zero");
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.proposePair(address(tokA), address(tokB), string(new bytes(1_025)));
        uint256 id = hooks.proposePair(address(tokA), address(tokB), "Same sector, cointegrated");
        vm.expectRevert(ProjectTokenHooks.ProposalCooldown.selector);
        hooks.proposePair(address(tokB), address(tokA), "again");
        vm.stopPrank();
        assertEq(id, 1);
        (address proposer,,,, ProjectTokenHooks.ProposalStatus st,) = hooks.proposals(1);
        assertEq(proposer, bob);
        assertEq(uint8(st), uint8(ProjectTokenHooks.ProposalStatus.OPEN));

        vm.startPrank(admin);
        hooks.setProposalStatus(1, ProjectTokenHooks.ProposalStatus.LISTED);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProposalStatus(2, ProjectTokenHooks.ProposalStatus.LISTED);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProposalStatus(1, ProjectTokenHooks.ProposalStatus.NONE);
        hooks.setProposalThreshold(5e18);
        vm.stopPrank();
        assertEq(hooks.proposalThreshold(), 5e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        assertEq(hooks.proposePair(address(tokB), address(tokA), "after cooldown"), 2);
    }

    function test_complianceOnHooks() public {
        _setToken();
        vm.startPrank(admin);
        hooks.setCompliance(address(compliance));
        compliance.setEnabled(true);
        vm.stopPrank();
        pair.mint(bob, 1e18);
        vm.startPrank(bob);
        pair.approve(address(hooks), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ProjectTokenHooks.NotAllowed.selector, bob));
        hooks.stake(1e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fee collector

    function test_feeCollectorGuards() public {
        vm.expectRevert(FeeCollector.NotVault.selector);
        feeCollector.onFeesMinted(1, 1);
        vm.expectRevert(FeeCollector.NotVault.selector);
        feeCollector.harvest(address(0xBEEF), 0);
        vm.expectRevert(FeeCollector.NothingToHarvest.selector);
        feeCollector.harvest(address(vault), 0);
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.BadParam.selector);
        feeCollector.setStakerShareBps(5_001);
        feeCollector.setStakerShareBps(2_000);
        vm.stopPrank();
        assertEq(feeCollector.stakerShareBps(), 2_000);
        vm.expectRevert();
        feeCollector.setHooks(address(0));
        vm.expectRevert();
        feeCollector.registerVault(address(1));
    }

    function test_feeCollectorRejectsHighStakerShare() public {
        vm.expectRevert(FeeCollector.BadParam.selector);
        new FeeCollector(admin, IERC20(address(usdg)), 5_001);
    }

    function test_harvestMinAssetsAndTreasury() public {
        _generateFees();
        vm.expectRevert(FeeCollector.BadParam.selector);
        feeCollector.harvest(address(vault), 1e30);
        uint256 got = feeCollector.harvest(address(vault), 0);
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.InsufficientTreasury.selector);
        feeCollector.withdrawTreasury(admin, got + 1);
        feeCollector.withdrawTreasury(admin, got);
        vm.stopPrank();
        assertEq(usdg.balanceOf(admin), got);
        vm.expectRevert();
        feeCollector.withdrawTreasury(alice, 0);
    }

    function test_harvestWithoutHooks() public {
        _setToken();
        _stake(bob, 1_000e18);
        vm.prank(admin);
        feeCollector.setHooks(address(0));
        _generateFees();
        uint256 got = feeCollector.harvest(address(vault), 0);
        assertEq(feeCollector.treasuryBalance(), got);
    }

    // ---------------------------------------------------------------- compliance registry

    function test_complianceRegistry() public {
        assertTrue(compliance.isAllowed(bob)); // off by default
        vm.prank(admin);
        compliance.setEnabled(true);
        assertFalse(compliance.isAllowed(bob));
        address[] memory l = new address[](1);
        l[0] = bob;
        vm.prank(admin);
        compliance.setAllowlisted(l, true);
        assertTrue(compliance.isAllowed(bob));
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        compliance.setAllowlisted(new address[](201), true);
        vm.expectRevert();
        compliance.setEnabled(false);
        vm.expectRevert();
        compliance.setAllowlisted(l, false);
    }

    // ---------------------------------------------------------------- timelock

    function test_timelockRejectsShortDelay() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        vm.expectRevert(PairwiseTimelock.DelayTooShort.selector);
        new PairwiseTimelock(47 hours, p, p);
    }

    function test_timelockEnforces48h() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        PairwiseTimelock tl = new PairwiseTimelock(48 hours, p, p);
        assertEq(tl.getMinDelay(), 48 hours);

        // a Timelock-owned setProjectToken can only execute after 48h
        bytes32 adminRole = hooks.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        hooks.grantRole(adminRole, address(tl));
        bytes memory data = abi.encodeCall(hooks.setProjectToken, (address(pair)));
        vm.prank(admin);
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.prank(admin);
        vm.expectRevert();
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        assertEq(address(hooks.projectToken()), address(pair));
    }
}
