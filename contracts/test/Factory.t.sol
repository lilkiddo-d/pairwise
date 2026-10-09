// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PairVaultFactory} from "../src/PairVaultFactory.sol";
import {PairVault} from "../src/PairVault.sol";
import {Id, MarketParams} from "../src/interfaces/external/IMorpho.sol";
import {MockERC20, MockAggregator, MockMorphoOracle, MockVault4626} from "./mocks/Mocks.sol";

contract FactoryTest is Fixture {
    function test_wiring() public view {
        assertEq(factory.vaultCount(), 1);
        PairVaultFactory.VaultRecord memory r = factory.vaultAt(0);
        assertEq(r.vault, address(vault));
        assertEq(r.longAdapter, address(longAd));
        assertEq(r.shortAdapter, address(shortAd));
        assertEq(r.pairId, pairId);
        assertEq(factory.allVaults().length, 1);
        assertEq(factory.vaultFor(address(tokA), address(tokB)), address(vault));
        assertEq(longAd.vault(), address(vault));
        assertEq(shortAd.vault(), address(vault));
        assertEq(vault.engine(), address(engine));
        assertTrue(feeCollector.isVault(address(vault)));
        (bool reg,,,) = engine.vaultInfo(address(vault));
        assertTrue(reg);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian));
        assertEq(factory.shared().vaultAdmin, admin);
        assertEq(factory.defaultConfig().deployBps, 9_000);
        assertEq(factory.defaultManagementFeeBps(), 100);
        assertEq(factory.defaultPerformanceFeeBps(), 1_500);
    }

    function test_listSecondPair_andDuplicates() public {
        MockERC20 tokC = new MockERC20("C", "CCC", 18);
        MockAggregator feedC = new MockAggregator(8, 25e8);
        vm.prank(admin);
        oracle.setFeed(address(tokC), address(feedC), 26 hours, address(0), 0);
        MockMorphoOracle mo = new MockMorphoOracle(oracle, address(usdg), address(tokC), MockVault4626(address(0)));
        MarketParams memory mpC = MarketParams(address(tokC), address(usdg), address(mo), address(irm), 0.77e18);
        morpho.createMarket(mpC);

        PairVaultFactory.VaultSpec memory spec = PairVaultFactory.VaultSpec({
            tokenA: address(tokA),
            tokenB: address(tokC),
            marketIdA: Id.unwrap(morpho.idOf(mpA)),
            marketIdB: Id.unwrap(morpho.idOf(mpC)),
            window: 40,
            name: "Pairwise AAA/CCC",
            symbol: "pwAC"
        });
        vm.expectRevert();
        factory.createVault(spec);
        vm.prank(admin);
        (address v2,,) = factory.createVault(spec);
        assertEq(PairVault(v2).pairId(), 2);
        assertEq(factory.vaultCount(), 2);
        vm.prank(admin);
        vm.expectRevert(PairVaultFactory.PairExists.selector);
        factory.createVault(spec);
        // reversed order is also a duplicate
        (spec.tokenA, spec.tokenB) = (spec.tokenB, spec.tokenA);
        (spec.marketIdA, spec.marketIdB) = (spec.marketIdB, spec.marketIdA);
        vm.prank(admin);
        vm.expectRevert(PairVaultFactory.PairExists.selector);
        factory.createVault(spec);
    }

    function test_adminSetters() public {
        PairVaultFactory.Shared memory s = factory.shared();
        vm.startPrank(admin);
        factory.setShared(s);
        s.engine = address(0);
        vm.expectRevert(PairVaultFactory.BadParam.selector);
        factory.setShared(s);
        vm.expectRevert(PairVaultFactory.BadParam.selector);
        factory.setDefaults(defaultConfig(), 101, 0);
        vm.expectRevert(PairVaultFactory.BadParam.selector);
        factory.setDefaults(defaultConfig(), 0, 1_501);
        factory.setDefaults(defaultConfig(), 50, 1_000);
        vm.stopPrank();
        assertEq(factory.defaultManagementFeeBps(), 50);
        vm.expectRevert();
        factory.setDefaults(defaultConfig(), 50, 1_000);
    }

    function test_constructorGuards() public {
        PairVaultFactory.Shared memory s = factory.shared();
        vm.expectRevert(PairVaultFactory.BadParam.selector);
        new PairVaultFactory(admin, address(0), address(1), address(1), s, defaultConfig(), 100, 1_500);
    }
}
