// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {UniswapV3SwapVenue} from "../../src/UniswapV3SwapVenue.sol";
import {ShortAdapter} from "../../src/ShortAdapter.sol";
import {PairVault} from "../../src/PairVault.sol";
import {SpreadOracle} from "../../src/SpreadOracle.sol";
import {StrategyEngine} from "../../src/StrategyEngine.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {IMorpho, Id} from "../../src/interfaces/external/IMorpho.sol";
import {IAggregatorV3} from "../../src/interfaces/external/IAggregatorV3.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {IPairVault} from "../../src/interfaces/IPairwise.sol";

interface IUniV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// @notice Fork tests against Robinhood Chain mainnet with the real token, feed, Uniswap and Morpho addresses from
///         config/robinhood-mainnet.json. Enabled with RUN_FORK_TESTS=true (needs network access):
///           RUN_FORK_TESTS=true forge test --match-path "test/fork/*" -vv
contract RobinhoodForkTest is Test {
    string json;
    address usdg;
    address morpho;

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        json = vm.readFile("../config/robinhood-mainnet.json");
        assertEq(block.chainid, 4663, "not Robinhood Chain mainnet");
        usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        morpho = vm.parseJsonAddress(json, ".morpho.blue");
    }

    // ---------------------------------------------------------------- helpers

    function _addr(string memory path) internal view returns (address) {
        return vm.parseJsonAddress(json, path);
    }

    function _stock(string memory sym, string memory field) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".stocks.", sym, ".", field));
    }

    function _token(string memory sym) internal view returns (address) {
        if (vm.keyExistsJson(json, string.concat(".tokens.", sym))) return _addr(string.concat(".tokens.", sym, ".address"));
        return _stock(sym, "address");
    }

    /// @dev Real USDG from the largest on-chain holder we know (Morpho Blue) — avoids storage-slot guessing.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(morpho);
        IERC20(usdg).transfer(to, amount);
    }

    function _liveOracle() internal returns (OracleAdapter o) {
        o = new OracleAdapter(address(this));
        o.setFeed(usdg, _addr(".chainlink.USDG.feed"), 4 days, address(0), 0);
        string[] memory stocks = vm.parseJsonKeys(json, ".stocks");
        for (uint256 i; i < stocks.length; ++i) {
            o.setFeed(_stock(stocks[i], "address"), _stock(stocks[i], "feed"), 4 days, address(0), 0);
        }
    }

    // ---------------------------------------------------------------- 1. config is real

    function test_fork_configAddressesAreLive() public view {
        assertGt(usdg.code.length, 0, "USDG");
        assertEq(IERC20Metadata(usdg).decimals(), 6);
        assertGt(_addr(".tokens.WETH.address").code.length, 0, "WETH");
        address steak = _addr(".tokens.steakUSDG.address");
        assertEq(IERC4626(steak).asset(), usdg, "steakUSDG asset");
        assertGt(_addr(".uniswapV3.swapRouter02").code.length, 0, "router");
        assertGt(morpho.code.length, 0, "morpho");
        assertEq(IAggregatorV3(_addr(".chainlink.USDG.feed")).decimals(), 8);

        IUniV3Factory uf = IUniV3Factory(_addr(".uniswapV3.factory"));
        string[] memory stocks = vm.parseJsonKeys(json, ".stocks");
        for (uint256 i; i < stocks.length; ++i) {
            string memory s = stocks[i];
            address tok = _stock(s, "address");
            assertEq(IERC20Metadata(tok).decimals(), 18, s);
            assertEq(IAggregatorV3(_stock(s, "feed")).decimals(), 8, s);
            (address loan, address coll,,, uint256 lltv) = IMorpho(morpho).idToMarketParams(
                Id.wrap(vm.parseJsonBytes32(json, string.concat(".stocks.", s, ".morphoMarketId")))
            );
            assertEq(loan, tok, string.concat(s, " morpho loan token"));
            assertEq(coll, steak, string.concat(s, " morpho collateral"));
            assertGt(lltv, 0);
            string[] memory hops = vm.parseJsonStringArray(json, string.concat(".stocks.", s, ".route.tokens"));
            uint256[] memory fees = vm.parseJsonUintArray(json, string.concat(".stocks.", s, ".route.fees"));
            for (uint256 j; j < fees.length; ++j) {
                assertTrue(uf.getPool(_token(hops[j]), _token(hops[j + 1]), uint24(fees[j])) != address(0), s);
            }
            console2.log(s, IAggregatorV3(_stock(s, "feed")).description());
        }
    }

    // ---------------------------------------------------------------- 2. live oracle

    function test_fork_liveChainlinkPrices() public {
        OracleAdapter o = _liveOracle();
        uint256 pu = o.getPrice(usdg);
        assertApproxEqRel(pu, 1e18, 0.02e18, "USDG ~ $1");
        string[] memory stocks = vm.parseJsonKeys(json, ".stocks");
        for (uint256 i; i < stocks.length; ++i) {
            uint256 p = o.getPrice(_stock(stocks[i], "address"));
            assertGt(p, 1e18, stocks[i]);
            console2.log(stocks[i], p / 1e16);
        }
    }

    // ---------------------------------------------------------------- 3. real Uniswap execution

    function test_fork_swapVenueRoundTrip() public {
        OracleAdapter o = _liveOracle();
        UniswapV3SwapVenue venue = new UniswapV3SwapVenue(address(this), ISwapRouter02(_addr(".uniswapV3.swapRouter02")));
        address nvda = _stock("NVDA", "address");
        address[] memory path = new address[](2);
        path[0] = nvda;
        path[1] = usdg;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        venue.setRoute(path, fees);

        _fundUsdg(address(this), 1_000e6);
        IERC20(usdg).approve(address(venue), type(uint256).max);
        uint256 expected = o.convert(usdg, 500e6, nvda);
        uint256 got = venue.swapExactIn(usdg, nvda, 500e6, expected * 98 / 100, address(this), block.timestamp);
        assertApproxEqRel(got, expected, 0.02e18, "pool within 2% of Chainlink");
        IERC20(nvda).approve(address(venue), type(uint256).max);
        uint256 back = venue.swapExactIn(nvda, usdg, got, 480e6, address(this), block.timestamp);
        assertGt(back, 490e6);
        uint256 spent = venue.swapExactOut(usdg, nvda, 0.5e18, 200e6, address(this), block.timestamp);
        assertGt(spent, 0);
        console2.log("round trip 500 USDG ->", back);
    }

    // ---------------------------------------------------------------- 4. real Morpho short leg

    function test_fork_shortLegOnLiveMorpho() public {
        OracleAdapter o = _liveOracle();
        UniswapV3SwapVenue venue = new UniswapV3SwapVenue(address(this), ISwapRouter02(_addr(".uniswapV3.swapRouter02")));
        address nvda = _stock("NVDA", "address");
        address qqq = _stock("QQQ", "address");
        address[] memory path = new address[](2);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        (path[0], path[1]) = (nvda, usdg);
        venue.setRoute(path, fees);
        (path[0], path[1]) = (qqq, usdg);
        venue.setRoute(path, fees);

        ShortAdapter s = ShortAdapter(Clones.clone(address(new ShortAdapter())));
        s.initialize(
            address(this),
            IMorpho(morpho),
            IERC20(usdg),
            venue,
            o,
            nvda,
            Id.wrap(vm.parseJsonBytes32(json, ".stocks.NVDA.morphoMarketId")),
            qqq,
            Id.wrap(vm.parseJsonBytes32(json, ".stocks.QQQ.morphoMarketId"))
        );
        uint256 cap = s.capacityUsdg(nvda);
        console2.log("live NVDA borrow capacity (USDG)", cap);
        uint256 notional = cap * 60 / 100;
        if (notional > 300e6) notional = 300e6;
        assertGt(notional, 10e6, "no NVDA borrow liquidity on Morpho");

        _fundUsdg(address(s), notional);
        s.increase(nvda, notional, notional, 100, block.timestamp);
        uint256 ltv = s.ltv(nvda);
        console2.log("ltv", ltv);
        assertLt(ltv, s.lltv(nvda) * 80 / 100);
        assertApproxEqRel(s.debtValue(nvda), notional, 0.02e18);

        uint256 before = IERC20(usdg).balanceOf(address(this));
        uint256 out = s.decrease(nvda, 1e18, 150, block.timestamp); // flash-loan funded full close
        assertEq(s.borrowedAssets(nvda), 0);
        assertEq(IERC20(usdg).balanceOf(address(this)) - before, out);
        assertGt(out, notional * 95 / 100, "round-trip cost < 5% of margin");
        console2.log("margin in / out", notional, out);
    }

    // ---------------------------------------------------------------- 5. Deploy.s.sol + a full trade on real venues

    // state for the end-to-end test (kept in storage to stay under the stack limit)
    PairVault vault;
    SpreadOracle spread;
    StrategyEngine engine;
    MarketClock clock;
    address keeper;
    address fa;
    address fb;
    address fu;
    int256 pa;
    int256 pb;

    function test_fork_deployScriptAndTradeCycle() public {
        Deploy script = new Deploy();
        keeper = makeAddr("keeper");
        Deploy.Deployment memory d = script.deployWithConfig(
            json,
            Deploy.Roles({
                deployer: address(script), keeper: keeper, guardian: makeAddr("guardian"), timelockAdmin: makeAddr("safe")
            })
        );
        assertEq(d.vaults.length, 4);
        vault = PairVault(d.vaults[2]); // NVDA/QQQ
        assertEq(vault.tokenA(), _stock("NVDA", "address"));
        assertEq(vault.tokenB(), _stock("QQQ", "address"));
        spread = SpreadOracle(d.spreadOracle);
        engine = StrategyEngine(d.engine);
        clock = MarketClock(d.clock);
        fa = _stock("NVDA", "feed");
        fb = _stock("QQQ", "feed");
        fu = _addr(".chainlink.USDG.feed");
        (, pa,,,) = IAggregatorV3(fa).latestRoundData();
        (, pb,,,) = IAggregatorV3(fb).latestRoundData();

        _syntheticHistory();
        _deposit();
        _armAndEnter();
        _exitAndCheck();
    }

    /// @dev 30 synthetic daily closes around the *real* prices; the live ratio sits ~+2.5 sigma above their mean.
    function _syntheticHistory() internal {
        uint256 n;
        while (n < 30) {
            vm.warp(block.timestamp + 6 hours);
            if (!clock.isAfterCloseOnTradingDay(block.timestamp)) continue;
            if (spread.getPair(vault.pairId()).lastDay >= clock.etDay(block.timestamp)) continue;
            int256 common = int256(uint256(keccak256(abi.encode(n))) % 401) - 200; // +/-2%
            int256 noise = n % 2 == 0 ? int256(80) : int256(-80); // +/-0.8% ratio wiggle
            int256 b = pb + pb * common / 10_000;
            int256 a = (pa * b / pb) * (10_000 - 200 + noise) / 10_000;
            _mockFeed(fa, a);
            _mockFeed(fb, b);
            _mockFeed(fu, 1e8);
            spread.recordClose(vault.pairId());
            n++;
        }
        while (!clock.isMarketOpen()) vm.warp(block.timestamp + 30 minutes);
        _livePrices();
        (int256 z,) = spread.zScore(vault.pairId());
        console2.log("live z (1e18)", z);
    }

    function _livePrices() internal {
        _mockFeed(fa, pa);
        _mockFeed(fb, pb);
        _mockFeed(fu, 1e8);
    }

    function _deposit() internal {
        address lp = makeAddr("lp");
        _fundUsdg(lp, 2_000e6);
        vm.startPrank(lp);
        IERC20(usdg).approve(address(vault), type(uint256).max);
        vault.deposit(2_000e6, lp);
        vm.stopPrank();
    }

    function _armAndEnter() internal {
        (StrategyEngine.Action act, uint8 dir,) = engine.check(address(vault));
        assertEq(uint8(act), uint8(StrategyEngine.Action.ARM), "signal arms");
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        vm.warp(block.timestamp + 16 minutes);
        _livePrices();
        vm.prank(keeper);
        engine.execute(address(vault), block.timestamp + 10 minutes);
        assertEq(uint8(vault.state()), dir, "entered on real Uniswap + Morpho");
        (uint256 l, uint256 s, uint256 ltv, uint256 maxLtv) = vault.legs();
        console2.log("long value", l);
        console2.log("short value", s);
        console2.log("ltv / max", ltv, maxLtv);
        assertLe(ltv, maxLtv);
        assertApproxEqRel(l, s, 0.1e18);
    }

    function _exitAndCheck() internal {
        vm.prank(address(engine));
        vault.exit(1, 0, block.timestamp + 10 minutes);
        assertEq(uint8(vault.state()), uint8(IPairVault.State.FLAT));
        uint256 nav = vault.totalAssets();
        console2.log("NAV after round trip", nav);
        assertGt(nav, 2_000e6 * 97 / 100, "round-trip cost < 3% of NAV");
    }

    function _mockFeed(address feed, int256 answer) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
