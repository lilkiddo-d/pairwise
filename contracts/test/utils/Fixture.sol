// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {SpreadOracle} from "../../src/SpreadOracle.sol";
import {UniswapV3SwapVenue} from "../../src/UniswapV3SwapVenue.sol";
import {LongAdapter} from "../../src/LongAdapter.sol";
import {ShortAdapter} from "../../src/ShortAdapter.sol";
import {PairVault} from "../../src/PairVault.sol";
import {StrategyEngine} from "../../src/StrategyEngine.sol";
import {PairVaultFactory} from "../../src/PairVaultFactory.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IMorpho, Id, MarketParams} from "../../src/interfaces/external/IMorpho.sol";
import {ISpreadOracle} from "../../src/interfaces/IPairwise.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {
    MockERC20,
    MockAggregator,
    MockSwapRouter,
    MockIrm,
    MockMorphoOracle,
    MockVault4626,
    MockMorpho
} from "../mocks/Mocks.sol";

/// @dev Full protocol on mocks. Pair: AAA (~$100) vs BBB (~$50).
///      AAA borrow market: plain USDG collateral, LLTV 77%. BBB borrow market: ERC-4626-wrapped USDG, LLTV 62.5%.
abstract contract Fixture is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MON_OPEN = 1791208800; // Mon 2026-10-05 14:00 UTC == 10:00 EDT

    address internal admin = makeAddr("admin"); // stands in for the Timelock
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal lender = makeAddr("lender");

    MockERC20 internal usdg;
    MockERC20 internal tokA;
    MockERC20 internal tokB;
    MockAggregator internal feedUsdg;
    MockAggregator internal feedA;
    MockAggregator internal feedB;
    MockVault4626 internal wrapper;
    MockMorpho internal morpho;
    MockIrm internal irm;
    MockSwapRouter internal router;
    MockMorphoOracle internal morphoOracleA;
    MockMorphoOracle internal morphoOracleB;
    MarketParams internal mpA;
    MarketParams internal mpB;

    MarketClock internal clock;
    OracleAdapter internal oracle;
    SpreadOracle internal spread;
    UniswapV3SwapVenue internal venue;
    StrategyEngine internal engine;
    FeeCollector internal feeCollector;
    ProjectTokenHooks internal hooks;
    ComplianceRegistry internal compliance;
    PairVaultFactory internal factory;

    PairVault internal vault;
    LongAdapter internal longAd;
    ShortAdapter internal shortAd;
    uint256 internal pairId;

    function setUp() public virtual {
        vm.warp(MON_OPEN);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        tokA = new MockERC20("Stock A", "AAA", 18);
        tokB = new MockERC20("Stock B", "BBB", 18);
        feedUsdg = new MockAggregator(8, 1e8);
        feedA = new MockAggregator(8, 100e8);
        feedB = new MockAggregator(8, 50e8);

        clock = new MarketClock(admin, admin);
        oracle = new OracleAdapter(admin);
        vm.startPrank(admin);
        oracle.setFeed(address(usdg), address(feedUsdg), 26 hours, address(0), 0);
        oracle.setFeed(address(tokA), address(feedA), 26 hours, address(0), 0);
        oracle.setFeed(address(tokB), address(feedB), 26 hours, address(0), 0);
        vm.stopPrank();

        // venue + mock Uniswap router priced off the oracle
        router = new MockSwapRouter(oracle);
        venue = new UniswapV3SwapVenue(admin, ISwapRouter02(address(router)));
        vm.startPrank(admin);
        _route(address(tokA), address(usdg));
        _route(address(tokB), address(usdg));
        vm.stopPrank();

        // Morpho markets
        morpho = new MockMorpho();
        irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days); // 5% APR
        wrapper = new MockVault4626(IERC20(address(usdg)));
        morphoOracleA = new MockMorphoOracle(oracle, address(usdg), address(tokA), MockVault4626(address(0)));
        morphoOracleB = new MockMorphoOracle(oracle, address(usdg), address(tokB), wrapper);
        mpA = MarketParams(address(tokA), address(usdg), address(morphoOracleA), address(irm), 0.77e18);
        mpB = MarketParams(address(tokB), address(wrapper), address(morphoOracleB), address(irm), 0.625e18);
        morpho.createMarket(mpA);
        morpho.createMarket(mpB);
        _supplyLiquidity(10_000e18, 20_000e18);
        usdg.mint(address(morpho), 10_000_000e6); // flash-loanable USDG

        spread = new SpreadOracle(admin, oracle, clock);
        engine = new StrategyEngine(admin, ISpreadOracle(address(spread)), IMarketClock(address(clock)), defaultParams());
        feeCollector = new FeeCollector(admin, IERC20(address(usdg)), 5_000);
        hooks = new ProjectTokenHooks(admin, IERC20(address(usdg)), guardian, 1_000e18);
        compliance = new ComplianceRegistry(admin, admin);

        factory = new PairVaultFactory(
            admin,
            address(new PairVault()),
            address(new LongAdapter()),
            address(new ShortAdapter()),
            PairVaultFactory.Shared({
                usdg: IERC20(address(usdg)),
                morpho: IMorpho(address(morpho)),
                venue: ISwapVenue(address(venue)),
                oracle: IPriceOracle(address(oracle)),
                spreadOracle: ISpreadOracle(address(spread)),
                clock: IMarketClock(address(clock)),
                engine: address(engine),
                feeCollector: address(feeCollector),
                compliance: address(compliance),
                vaultAdmin: admin,
                guardian: guardian
            }),
            defaultConfig(),
            100,
            1_500
        );

        vm.startPrank(admin);
        spread.grantRole(spread.REGISTRAR_ROLE(), address(factory));
        spread.grantRole(spread.SEEDER_ROLE(), keeper);
        engine.grantRole(engine.REGISTRAR_ROLE(), address(factory));
        engine.grantRole(engine.KEEPER_ROLE(), keeper);
        engine.grantRole(engine.GUARDIAN_ROLE(), guardian);
        feeCollector.grantRole(feeCollector.REGISTRAR_ROLE(), address(factory));
        feeCollector.setHooks(address(hooks));
        hooks.grantRole(hooks.FEE_NOTIFIER_ROLE(), address(feeCollector));
        factory.grantRole(factory.LISTER_ROLE(), admin);
        (address v, address l, address s) = factory.createVault(
            PairVaultFactory.VaultSpec({
                tokenA: address(tokA),
                tokenB: address(tokB),
                marketIdA: Id.unwrap(morpho.idOf(mpA)),
                marketIdB: Id.unwrap(morpho.idOf(mpB)),
                window: 30,
                name: "Pairwise AAA/BBB",
                symbol: "pwAB"
            })
        );
        vm.stopPrank();
        vault = PairVault(v);
        longAd = LongAdapter(l);
        shortAd = ShortAdapter(s);
        pairId = vault.pairId();

        vm.label(address(vault), "vault");
        vm.label(address(longAd), "longAdapter");
        vm.label(address(shortAd), "shortAdapter");
    }

    // ---------------------------------------------------------------- defaults

    function defaultConfig() internal pure returns (PairVault.Config memory) {
        return PairVault.Config({
            maxSlippageBps: 50,
            deployBps: 9_000,
            targetLtvBps: 6_500,
            rebalanceLtvBps: 7_500,
            maxLtvBps: 8_000,
            bandBps: 1_000,
            rebalanceTriggerBps: 500,
            maxTiltBps: 500,
            maxNotionalUsdg: 0,
            depositCap: 0
        });
    }

    function defaultParams() internal pure returns (StrategyEngine.Params memory) {
        return StrategyEngine.Params({
            entryZ: 2e18,
            exitZ: 0.5e18,
            stopZ: 3.5e18,
            maxHolding: 20 days,
            cooldown: 1 days,
            confirmDelay: 15 minutes,
            armWindow: 2 hours,
            minCorrelation: 0.5e18,
            exitCorrelation: 0.2e18,
            maxBorrowApr: 0.5e18
        });
    }

    // ---------------------------------------------------------------- helpers

    function _route(address a, address b) internal {
        address[] memory t = new address[](2);
        t[0] = a;
        t[1] = b;
        uint24[] memory f = new uint24[](1);
        f[0] = 500;
        venue.setRoute(t, f);
    }

    function _supplyLiquidity(uint256 amountA, uint256 amountB) internal {
        tokA.mint(lender, amountA);
        tokB.mint(lender, amountB);
        vm.startPrank(lender);
        tokA.approve(address(morpho), amountA);
        tokB.approve(address(morpho), amountB);
        morpho.supply(mpA, amountA, lender);
        morpho.supply(mpB, amountB, lender);
        vm.stopPrank();
    }

    function _setPrices(uint256 pa8, uint256 pb8) internal {
        feedA.setPrice(int256(pa8));
        feedB.setPrice(int256(pb8));
        feedUsdg.setPrice(1e8);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Advances to the next moment the regular session is open (at least 1 hour ahead), refreshing feeds.
    function _toNextOpen() internal {
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < 24 * 8 && !clock.isMarketOpen(); ++i) {
            vm.warp(block.timestamp + 1 hours);
        }
        require(clock.isMarketOpen(), "no open found");
        _refreshFeeds();
    }

    function _toNextClose() internal {
        uint256 last = spread.getPair(pairId).lastDay;
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < 24 * 8; ++i) {
            if (clock.isAfterCloseOnTradingDay(block.timestamp) && clock.etDay(block.timestamp) > last) break;
            vm.warp(block.timestamp + 1 hours);
        }
    }

    function _refreshFeeds() internal {
        (, int256 a,,,) = feedA.latestRoundData();
        (, int256 b,,,) = feedB.latestRoundData();
        feedA.setPrice(a);
        feedB.setPrice(b);
        feedUsdg.setPrice(1e8);
    }

    /// @dev Records `n` daily closes of a correlated random walk with a mean-reverting ratio of ~2.0.
    function _seedHistory(uint256 n) internal {
        uint256 pb = 50e8;
        for (uint256 i; i < n; ++i) {
            _toNextClose();
            uint256 h = uint256(keccak256(abi.encode("walk", i)));
            // common factor: +/- up to 2%
            int256 common = int256(h % 401) - 200;
            pb = uint256(int256(pb) + int256(pb) * common / 10_000);
            // idiosyncratic ratio wiggle: +/- 0.5%
            int256 idio = int256((h >> 32) % 101) - 50;
            uint256 pa = uint256(int256(2 * pb) + int256(2 * pb) * idio / 10_000);
            _setPrices(pa, pb);
            spread.recordClose(pairId);
        }
    }

    /// @dev Sets A so the live ratio sits `zTimes` (1e18-scaled, signed) standard deviations from the mean.
    function _pushZ(int256 zTimes) internal {
        (uint256 mean, uint256 std,) = spread.ratioStats(pairId);
        (, int256 b,,,) = feedB.latestRoundData();
        int256 ratio = int256(mean) + zTimes * int256(std) / int256(WAD);
        int256 a = b * ratio / int256(WAD);
        feedA.setPrice(a);
        feedB.setPrice(b);
        feedUsdg.setPrice(1e8);
    }

    /// @dev Arms then (after the confirm delay) executes an entry. Returns the direction entered.
    function _armAndEnter() internal {
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        vm.warp(block.timestamp + 16 minutes);
        _refreshFeeds();
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
    }
}
