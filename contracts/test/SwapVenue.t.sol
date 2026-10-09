// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {UniswapV3SwapVenue} from "../src/UniswapV3SwapVenue.sol";
import {ISwapRouter02} from "../src/interfaces/external/ISwapRouter02.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev Router that reports success but under-delivers, to prove the venue's own balance checks.
contract LyingRouter is ISwapRouter02 {
    function exactInput(ExactInputParams calldata p) external payable returns (uint256) {
        return p.amountOutMinimum; // sends nothing
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        return 0; // sends nothing
    }
}

contract SwapVenueTest is Fixture {
    function test_routeValidation() public {
        address[] memory t = new address[](2);
        uint24[] memory f = new uint24[](1);
        t[0] = address(tokA);
        t[1] = address(usdg);
        f[0] = 500;
        vm.startPrank(admin);
        vm.expectRevert(UniswapV3SwapVenue.InvalidRoute.selector);
        venue.setRoute(t, new uint24[](0));
        vm.expectRevert(UniswapV3SwapVenue.InvalidRoute.selector);
        venue.setRoute(new address[](5), new uint24[](4));
        vm.expectRevert(UniswapV3SwapVenue.InvalidRoute.selector);
        venue.setRoute(new address[](3), f);
        address[] memory same = new address[](2);
        same[0] = address(tokA);
        same[1] = address(tokA);
        vm.expectRevert(UniswapV3SwapVenue.InvalidRoute.selector);
        venue.setRoute(same, f);
        address[] memory zero = new address[](2);
        zero[1] = address(tokA);
        vm.expectRevert(UniswapV3SwapVenue.InvalidRoute.selector);
        venue.setRoute(zero, f);
        vm.stopPrank();
        vm.expectRevert();
        venue.setRoute(t, f);
    }

    function test_multiHopEncoding() public {
        address weth = makeAddr("weth");
        address[] memory t = new address[](3);
        t[0] = address(tokA);
        t[1] = weth;
        t[2] = address(usdg);
        uint24[] memory f = new uint24[](2);
        f[0] = 3000;
        f[1] = 500;
        vm.prank(admin);
        venue.setRoute(t, f);
        assertEq(venue.routes(address(tokA), address(usdg)), abi.encodePacked(address(tokA), uint24(3000), weth, uint24(500), address(usdg)));
        assertEq(venue.routes(address(usdg), address(tokA)), abi.encodePacked(address(usdg), uint24(500), weth, uint24(3000), address(tokA)));
        assertTrue(venue.hasRoute(address(usdg), address(tokA)));
        assertFalse(venue.hasRoute(address(tokA), address(tokB)));
    }

    function test_exactInAndOut() public {
        usdg.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdg.approve(address(venue), type(uint256).max);
        uint256 out = venue.swapExactIn(address(usdg), address(tokA), 1_000e6, 9.9e18, alice, block.timestamp);
        assertEq(out, 10e18);
        assertEq(tokA.balanceOf(alice), 10e18);

        uint256 spent = venue.swapExactOut(address(usdg), address(tokB), 4e18, 500e6, alice, block.timestamp);
        assertEq(spent, 200e6 + 1);
        assertEq(tokB.balanceOf(alice), 4e18);
        assertEq(usdg.balanceOf(alice), 10_000e6 - 1_000e6 - spent); // leftover refunded
        assertEq(usdg.balanceOf(address(venue)), 0);
        vm.stopPrank();
    }

    function test_swapGuards() public {
        usdg.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdg.approve(address(venue), type(uint256).max);
        vm.expectRevert(UniswapV3SwapVenue.Expired.selector);
        venue.swapExactIn(address(usdg), address(tokA), 1e6, 0, alice, block.timestamp - 1);
        vm.expectRevert(UniswapV3SwapVenue.ZeroAmount.selector);
        venue.swapExactIn(address(usdg), address(tokA), 0, 0, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapVenue.NoRoute.selector, address(tokA), address(tokB)));
        venue.swapExactIn(address(tokA), address(tokB), 1, 0, alice, block.timestamp);
        vm.expectRevert(UniswapV3SwapVenue.Expired.selector);
        venue.swapExactOut(address(usdg), address(tokA), 1e18, 1e9, alice, block.timestamp - 1);
        vm.expectRevert(UniswapV3SwapVenue.ZeroAmount.selector);
        venue.swapExactOut(address(usdg), address(tokA), 0, 1e9, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapVenue.NoRoute.selector, address(tokA), address(tokB)));
        venue.swapExactOut(address(tokA), address(tokB), 1, 1, alice, block.timestamp);
        // slippage bound enforced by the router
        router.setSlippageBps(100);
        vm.expectRevert(bytes("Too little received"));
        venue.swapExactIn(address(usdg), address(tokA), 1_000e6, 9.95e18, alice, block.timestamp);
        vm.expectRevert(bytes("Too much requested"));
        venue.swapExactOut(address(usdg), address(tokA), 10e18, 1_005e6, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_venueChecksActualDelivery() public {
        UniswapV3SwapVenue liar = new UniswapV3SwapVenue(admin, new LyingRouter());
        address[] memory t = new address[](2);
        t[0] = address(tokA);
        t[1] = address(usdg);
        uint24[] memory f = new uint24[](1);
        f[0] = 500;
        vm.prank(admin);
        liar.setRoute(t, f);
        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(liar), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapVenue.InsufficientOutput.selector, 0, 1));
        liar.swapExactIn(address(usdg), address(tokA), 100e6, 1, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapVenue.InsufficientOutput.selector, 0, 1e18));
        liar.swapExactOut(address(usdg), address(tokA), 1e18, 100e6, alice, block.timestamp);
        vm.stopPrank();
    }
}
