// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../utils/Fixture.sol";
import {PairVault} from "../../src/PairVault.sol";
import {StrategyEngine} from "../../src/StrategyEngine.sol";
import {SpreadOracle} from "../../src/SpreadOracle.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {LongAdapter} from "../../src/LongAdapter.sol";
import {ShortAdapter} from "../../src/ShortAdapter.sol";
import {IPairVault} from "../../src/interfaces/IPairwise.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";

contract VaultHandler is Test {
    PairVault public vault;
    StrategyEngine public engine;
    SpreadOracle public spread;
    MarketClock public clock;
    MockERC20 public usdg;
    MockAggregator public feedA;
    MockAggregator public feedB;
    MockAggregator public feedUsdg;
    address public keeper;
    uint256 public pairId;
    address[] public actors;

    // ghosts
    uint256 public positionActions;
    uint256 public bandViolations;
    uint256 public ltvViolations;
    uint256 public dilutions;
    uint256 public deposits;
    uint256 public redemptions;

    constructor(
        PairVault vault_,
        StrategyEngine engine_,
        SpreadOracle spread_,
        MarketClock clock_,
        MockERC20 usdg_,
        MockAggregator feedA_,
        MockAggregator feedB_,
        MockAggregator feedUsdg_,
        address keeper_
    ) {
        vault = vault_;
        engine = engine_;
        spread = spread_;
        clock = clock_;
        usdg = usdg_;
        feedA = feedA_;
        feedB = feedB_;
        feedUsdg = feedUsdg_;
        keeper = keeper_;
        pairId = vault_.pairId();
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    // ---------------------------------------------------------------- helpers

    function _pps() internal view returns (uint256) {
        return vault.convertToAssets(1e12);
    }

    function _refresh() internal {
        (, int256 a,,,) = feedA.latestRoundData();
        (, int256 b,,,) = feedB.latestRoundData();
        feedA.setPrice(a);
        feedB.setPrice(b);
        feedUsdg.setPrice(1e8);
    }

    function _checkPosition() internal {
        if (vault.state() == IPairVault.State.FLAT) return;
        positionActions++;
        (uint256 l, uint256 s, uint256 ltv, uint256 maxLtv) = vault.legs();
        (,,,,, uint16 band,,,,) = vault.config();
        uint256 hi = l > s ? l : s;
        uint256 diff = l > s ? l - s : s - l;
        if (diff * 10_000 > hi * band) bandViolations++;
        if (ltv > maxLtv) ltvViolations++;
    }

    // ---------------------------------------------------------------- actions

    function deposit(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 200_000e6);
        if (vault.maxDeposit(who) < amount) return;
        uint256 before = _pps();
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        try vault.deposit(amount, who) {
            deposits++;
            if (_pps() + 1 < before) dilutions++;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external {
        address who = actors[actorSeed % actors.length];
        uint256 maxSh = vault.maxRedeem(who);
        if (maxSh == 0) return;
        uint256 sh = maxSh * bound(fractionBps, 1, 10_000) / 10_000;
        if (sh == 0) return;
        uint256 before = _pps();
        bool partialExit = sh < vault.totalSupply();
        vm.prank(who);
        try vault.redeem(sh, who, who) {
            redemptions++;
            if (partialExit && _pps() + 1 < before) dilutions++;
            _checkPosition();
        } catch {}
    }

    function movePrices(int256 da, int256 db) external {
        da = bound(da, -300, 300); // +/- 3%
        db = bound(db, -300, 300);
        (, int256 a,,,) = feedA.latestRoundData();
        (, int256 b,,,) = feedB.latestRoundData();
        feedA.setPrice(a + a * da / 10_000);
        feedB.setPrice(b + b * db / 10_000);
        feedUsdg.setPrice(1e8);
    }

    function pushSignal(int256 zSeed) public {
        int256 z = bound(zSeed, -4e18, 4e18);
        (uint256 mean, uint256 std,) = spread.ratioStats(pairId);
        if (std == 0) return;
        (, int256 b,,,) = feedB.latestRoundData();
        int256 ratio = int256(mean) + z * int256(std) / 1e18;
        if (ratio <= 0) return;
        feedA.setPrice(b * ratio / 1e18);
        feedB.setPrice(b);
        feedUsdg.setPrice(1e8);
    }

    function _toOpen() internal {
        for (uint256 i; i < 24 * 8 && !clock.isMarketOpen(); ++i) {
            vm.warp(block.timestamp + 1 hours);
        }
        _refresh();
    }

    /// @dev Drives a full arm -> confirm -> enter sequence with a signal beyond the entry threshold.
    function openTrade(int256 zSeed) external {
        _toOpen();
        if (vault.state() != IPairVault.State.FLAT) return;
        int256 mag = bound(zSeed < 0 ? -zSeed : zSeed, 2.1e18, 3.4e18);
        this.pushSignal(zSeed < 0 ? -mag : mag);
        _tick();
        vm.warp(block.timestamp + 16 minutes);
        _toOpen();
        _tick();
    }

    function keeperTick() external {
        vm.warp(block.timestamp + 16 minutes);
        _toOpen();
        _tick();
    }

    function _tick() internal {
        if (!clock.isMarketOpen()) return;
        (StrategyEngine.Action a,,) = engine.check(address(vault));
        if (a == StrategyEngine.Action.NONE) return;
        vm.prank(keeper);
        try engine.execute(address(vault), block.timestamp + 10 minutes) {
            if (a == StrategyEngine.Action.ENTER || a == StrategyEngine.Action.REBALANCE) _checkPosition();
        } catch {}
    }

    function advanceTime(uint256 hoursSeed) external {
        vm.warp(block.timestamp + bound(hoursSeed, 1, 30) * 1 hours);
        _refresh();
    }
}

contract VaultInvariantTest is Fixture {
    VaultHandler handler;

    function setUp() public override {
        super.setUp();
        _seedHistory(30);
        _toNextOpen();
        vm.prank(admin);
        vault.setFees(0, 0); // isolate share-price accounting from fee dilution
        router.setSlippageBps(20); // realistic execution costs
        handler = new VaultHandler(vault, engine, spread, clock, usdg, feedA, feedB, feedUsdg, keeper);
        _deposit(alice, 100_000e6); // seed liquidity so trades can open from the first call
        targetContract(address(handler));
    }

    /// @notice After every entry/rebalance/redemption the legs are within the dollar-neutral band.
    function invariant_dollarNeutralBand() public view {
        assertEq(handler.bandViolations(), 0);
    }

    /// @notice After every position-changing action the short leg is at or under the venue's safe LTV.
    function invariant_shortLegUnderSafeLtv() public view {
        assertEq(handler.ltvViolations(), 0);
    }

    /// @notice Deposits and partial withdrawals never reduce the assets-per-share of remaining holders.
    function invariant_noDilution() public view {
        assertEq(handler.dilutions(), 0);
    }

    /// @notice When flat, every asset is USDG in the vault: nothing is stranded in the adapters.
    function invariant_flatHoldsOnlyCash() public view {
        if (vault.state() != IPairVault.State.FLAT) return;
        assertEq(vault.totalAssets(), usdg.balanceOf(address(vault)));
        assertEq(tokA.balanceOf(address(longAd)), 0);
        assertEq(tokB.balanceOf(address(longAd)), 0);
        assertEq(shortAd.borrowedAssets(address(tokA)), 0);
        assertEq(shortAd.borrowedAssets(address(tokB)), 0);
    }

    function afterInvariant() public {
        emit log_named_uint("position actions checked", handler.positionActions());
        emit log_named_uint("deposits", handler.deposits());
        emit log_named_uint("redemptions", handler.redemptions());
    }

    /// @notice Share supply is fully backed: converting all shares never exceeds total assets.
    function invariant_sharesBacked() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + 1);
    }
}
