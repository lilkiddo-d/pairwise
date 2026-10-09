// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LongAdapter} from "../src/LongAdapter.sol";
import {ShortAdapter} from "../src/ShortAdapter.sol";
import {IMorpho, Id, MarketParams} from "../src/interfaces/external/IMorpho.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20, MockVault4626, MockMorphoOracle} from "./mocks/Mocks.sol";

contract LongAdapterTest is Fixture {
    function test_initGuards() public {
        LongAdapter impl = new LongAdapter();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(1), IERC20(address(usdg)), venue, oracle, address(tokA), address(tokB));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        longAd.initialize(address(1), IERC20(address(usdg)), venue, oracle, address(tokA), address(tokB));
        LongAdapter c = LongAdapter(Clones.clone(address(impl)));
        vm.expectRevert(LongAdapter.BadParam.selector);
        c.initialize(address(0), IERC20(address(usdg)), venue, oracle, address(tokA), address(tokB));
    }

    function test_onlyVaultAndParams() public {
        vm.expectRevert(LongAdapter.OnlyVault.selector);
        longAd.increase(address(tokA), 1, 0, block.timestamp);
        vm.expectRevert(LongAdapter.OnlyVault.selector);
        longAd.decrease(address(tokA), 1, 0, block.timestamp);
        vm.expectRevert(LongAdapter.OnlyVault.selector);
        longAd.setOracle(oracle);
        vm.startPrank(address(vault));
        vm.expectRevert(LongAdapter.UnsupportedToken.selector);
        longAd.increase(address(usdg), 1, 0, block.timestamp);
        vm.expectRevert(LongAdapter.BadParam.selector);
        longAd.increase(address(tokA), 1, 501, block.timestamp);
        vm.expectRevert(LongAdapter.BadParam.selector);
        longAd.increase(address(tokA), 0, 0, block.timestamp);
        vm.expectRevert(LongAdapter.BadParam.selector);
        longAd.decrease(address(tokA), 0, 0, block.timestamp);
        vm.expectRevert(LongAdapter.BadParam.selector);
        longAd.decrease(address(tokA), 2e18, 0, block.timestamp);
        vm.expectRevert(LongAdapter.BadParam.selector);
        longAd.setOracle(IPriceOracle(address(0)));
        longAd.setOracle(oracle);
        assertEq(longAd.decrease(address(tokA), 1e18, 0, block.timestamp), 0); // nothing held
        vm.stopPrank();
    }

    function test_increaseDecrease() public {
        usdg.mint(address(longAd), 1_000e6);
        vm.startPrank(address(vault));
        uint256 got = longAd.increase(address(tokA), 1_000e6, 50, block.timestamp);
        assertEq(got, 10e18);
        assertEq(longAd.balance(address(tokA)), 10e18);
        assertEq(longAd.value(address(tokA)), 1_000e6);
        assertEq(longAd.value(address(tokB)), 0);
        uint256 out = longAd.decrease(address(tokA), 0.25e18, 50, block.timestamp);
        assertEq(out, 250e6);
        assertEq(usdg.balanceOf(address(vault)), 250e6);
        out = longAd.decrease(address(tokA), 1e18, 50, block.timestamp);
        assertEq(out, 750e6);
        assertEq(longAd.balance(address(tokA)), 0);
        vm.stopPrank();
    }

    function test_oracleBoundsExecution() public {
        usdg.mint(address(longAd), 1_000e6);
        router.setPriceSkewBps(100); // pool 1% worse than oracle
        vm.prank(address(vault));
        vm.expectRevert(bytes("Too little received"));
        longAd.increase(address(tokA), 1_000e6, 50, block.timestamp);
    }
}

contract ShortAdapterTest is Fixture {
    function _open(address token, uint256 notional, uint256 margin) internal {
        usdg.mint(address(shortAd), margin);
        vm.prank(address(vault));
        shortAd.increase(token, notional, margin, 50, block.timestamp);
    }

    function test_initGuards() public {
        ShortAdapter impl = new ShortAdapter();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            address(1), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(tokA), Id.wrap(0), address(tokB), Id.wrap(0)
        );
        ShortAdapter c = ShortAdapter(Clones.clone(address(impl)));
        Id idA = morpho.idOf(mpA);
        Id idB = morpho.idOf(mpB);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        c.initialize(address(0), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(tokA), idA, address(tokB), idB);
        // loan token mismatch
        vm.expectRevert(ShortAdapter.BadMarket.selector);
        c.initialize(address(1), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(tokB), idA, address(tokA), idB);
        // collateral is neither USDG nor a USDG ERC-4626
        MockERC20 other = new MockERC20("O", "O", 18);
        MockVault4626 badWrapper = new MockVault4626(IERC20(address(other)));
        MarketParams memory bad = MarketParams(address(tokA), address(badWrapper), address(morphoOracleA), address(irm), 0.77e18);
        morpho.createMarket(bad);
        Id badId = morpho.idOf(bad);
        vm.expectRevert(ShortAdapter.BadMarket.selector);
        c.initialize(address(1), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(tokA), badId, address(tokB), idB);
        // unknown market (lltv 0)
        vm.expectRevert(ShortAdapter.BadMarket.selector);
        c.initialize(address(1), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(0), Id.wrap(bytes32(uint256(1))), address(tokB), idB);
    }

    function test_onlyVault() public {
        vm.expectRevert(ShortAdapter.OnlyVault.selector);
        shortAd.increase(address(tokA), 1, 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.OnlyVault.selector);
        shortAd.decrease(address(tokA), 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.OnlyVault.selector);
        shortAd.deleverage(address(tokA), 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.OnlyVault.selector);
        shortAd.addCollateral(address(tokA), 1);
        vm.expectRevert(ShortAdapter.OnlyVault.selector);
        shortAd.setOracle(oracle);
        vm.expectRevert(ShortAdapter.UnauthorizedCallback.selector);
        shortAd.onMorphoFlashLoan(1, "");
        vm.expectRevert(ShortAdapter.UnauthorizedCallback.selector);
        shortAd.onMorphoSupplyCollateral(1, "");
        vm.startPrank(address(morpho));
        vm.expectRevert(ShortAdapter.UnauthorizedCallback.selector);
        shortAd.onMorphoFlashLoan(1, "");
        vm.expectRevert(ShortAdapter.UnauthorizedCallback.selector);
        shortAd.onMorphoSupplyCollateral(1, "");
        vm.stopPrank();
    }

    function test_paramGuards() public {
        vm.startPrank(address(vault));
        vm.expectRevert(ShortAdapter.UnsupportedToken.selector);
        shortAd.increase(address(usdg), 1, 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.increase(address(tokA), 1, 1, 501, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.increase(address(tokA), 0, 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.decrease(address(tokA), 0, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.decrease(address(tokA), 1e18 + 1, 0, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.decrease(address(tokA), 1e18, 501, block.timestamp);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.addCollateral(address(tokA), 0);
        vm.expectRevert(ShortAdapter.BadParam.selector);
        shortAd.setOracle(IPriceOracle(address(0)));
        shortAd.setOracle(oracle);
        vm.stopPrank();
        assertTrue(shortAd.supportsToken(address(tokA)));
        assertFalse(shortAd.supportsToken(address(usdg)));
        (MarketParams memory p, Id id, address w) = shortAd.marketConfig(address(tokB));
        assertEq(p.loanToken, address(tokB));
        assertEq(Id.unwrap(id), Id.unwrap(morpho.idOf(mpB)));
        assertEq(w, address(wrapper));
    }

    function test_openPlainCollateral_andViews() public {
        _open(address(tokA), 10_000e6, 10_000e6);
        assertEq(shortAd.borrowedAssets(address(tokA)), 100e18);
        assertEq(shortAd.debtValue(address(tokA)), 10_000e6);
        assertEq(shortAd.collateralValue(address(tokA)), 20_000e6);
        assertEq(shortAd.equity(address(tokA)), 10_000e6);
        assertApproxEqRel(shortAd.ltv(address(tokA)), 0.5e18, 1e12);
        assertEq(shortAd.lltv(address(tokA)), 0.77e18);
        assertEq(usdg.balanceOf(address(shortAd)), 0);
        assertGt(shortAd.capacityUsdg(address(tokA)), 0);
        assertEq(shortAd.borrowRatePerSecond(address(tokA)), uint256(0.05e18) / 365 days);

        // interest accrues into the debt view without a state change
        vm.warp(block.timestamp + 365 days);
        feedA.setPrice(100e8);
        feedUsdg.setPrice(1e8);
        assertApproxEqRel(shortAd.borrowedAssets(address(tokA)), 105.127e18, 0.001e18);
    }

    function test_openWrappedCollateral() public {
        _open(address(tokB), 5_000e6, 6_000e6);
        assertEq(shortAd.borrowedAssets(address(tokB)), 100e18);
        assertApproxEqAbs(shortAd.collateralValue(address(tokB)), 11_000e6, 2);
        assertEq(wrapper.balanceOf(address(shortAd)), 0, "no idle wrapper shares");
        assertLe(shortAd.ltv(address(tokB)), 0.46e18);
    }

    function test_executionSurplusIsPosted() public {
        router.setSlippageBps(0);
        _open(address(tokA), 10_000e6, 10_000e6);
        // minOut was 99.5% of notional; the 0.5% surplus must also be collateral
        assertEq(shortAd.collateralValue(address(tokA)), 20_000e6);
    }

    function test_decreaseFundedByVault_noFlash() public {
        _open(address(tokA), 10_000e6, 10_000e6);
        usdg.mint(address(shortAd), 6_000e6); // vault-sent buyback funds
        vm.prank(address(vault));
        uint256 out = shortAd.decrease(address(tokA), 0.5e18, 50, block.timestamp);
        assertApproxEqAbs(shortAd.borrowedAssets(address(tokA)), 50e18, 1);
        assertApproxEqAbs(out, 6_000e6 - 5_000e6 + 10_000e6, 2);
        assertEq(usdg.balanceOf(address(vault)), out);
    }

    function test_decreaseWithFlashLoan_fullClose() public {
        _open(address(tokB), 5_000e6, 5_000e6);
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        vm.prank(address(vault));
        uint256 out = shortAd.decrease(address(tokB), 1e18, 50, block.timestamp);
        assertEq(shortAd.borrowedAssets(address(tokB)), 0);
        assertEq(shortAd.collateralBalance(address(tokB)), 0);
        assertApproxEqAbs(out, 5_000e6, 2);
        assertEq(usdg.balanceOf(address(vault)) - vaultBefore, out);
        assertEq(shortAd.ltv(address(tokB)), 0);
        // nothing left: a second close is a no-op that returns 0
        vm.prank(address(vault));
        assertEq(shortAd.decrease(address(tokB), 1e18, 50, block.timestamp), 0);
    }

    function test_deleverageAndAddCollateral() public {
        _open(address(tokA), 10_000e6, 10_000e6);
        uint256 ltv0 = shortAd.ltv(address(tokA));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(ShortAdapter.InsufficientFunds.selector, 0, 2_010_000_001));
        shortAd.deleverage(address(tokA), 0.2e18, 50, block.timestamp);

        usdg.mint(address(shortAd), 2_100e6);
        vm.prank(address(vault));
        shortAd.deleverage(address(tokA), 0.2e18, 50, block.timestamp);
        assertApproxEqAbs(shortAd.borrowedAssets(address(tokA)), 80e18, 1);
        assertLt(shortAd.ltv(address(tokA)), ltv0);
        assertEq(shortAd.collateralValue(address(tokA)), 20_000e6); // collateral untouched

        usdg.mint(address(shortAd), 1_000e6);
        vm.prank(address(vault));
        shortAd.addCollateral(address(tokA), 1_000e6);
        assertEq(shortAd.collateralValue(address(tokA)), 21_000e6);
    }

    function test_ltvInfiniteWhenOracleZero() public {
        _open(address(tokA), 10_000e6, 10_000e6);
        morphoOracleA.setOverride(1); // collateral worth ~0 in loan units
        assertEq(shortAd.ltv(address(tokA)), type(uint256).max);
    }

    function test_capacityZeroWhenFullyBorrowed() public {
        uint256 cap = shortAd.capacityUsdg(address(tokA));
        assertEq(cap, 1_000_000e6); // 10k AAA at $100
        // borrow almost everything from another account
        _open(address(tokA), 990_000e6, 990_000e6);
        assertEq(shortAd.capacityUsdg(address(tokA)), 10_000e6);
        vm.prank(lender);
        morpho.withdraw(mpA, 100e18, lender, lender); // "recall" the remaining idle liquidity
        assertEq(shortAd.capacityUsdg(address(tokA)), 0);
    }

    function test_irmlessMarket() public {
        MarketParams memory p0 = MarketParams(address(tokA), address(usdg), address(morphoOracleA), address(0), 0.77e18);
        morpho.createMarket(p0);
        ShortAdapter c = ShortAdapter(Clones.clone(address(new ShortAdapter())));
        c.initialize(address(this), IMorpho(address(morpho)), IERC20(address(usdg)), venue, oracle, address(tokA), morpho.idOf(p0), address(tokB), morpho.idOf(mpB));
        assertEq(c.borrowRatePerSecond(address(tokA)), 0);
    }
}
