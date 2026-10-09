// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";

contract OracleAdapterTest is Test {
    OracleAdapter oracle;
    OracleAdapter secondary;
    MockAggregator feed;
    MockAggregator feed2;
    MockAggregator usdgFeed;
    MockAggregator seq;
    MockERC20 tok;
    MockERC20 usdg;
    address admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_800_000_000);
        tok = new MockERC20("T", "T", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregator(8, 200e8);
        feed2 = new MockAggregator(8, 201e8);
        usdgFeed = new MockAggregator(8, 1e8);
        oracle = new OracleAdapter(admin);
        secondary = new OracleAdapter(admin);
        vm.startPrank(admin);
        oracle.setFeed(address(tok), address(feed), 1 hours, address(0), 0);
        oracle.setFeed(address(usdg), address(usdgFeed), 1 hours, address(0), 0);
        secondary.setFeed(address(tok), address(feed2), 1 hours, address(0), 0);
        vm.stopPrank();
    }

    function test_priceAndConvert() public view {
        assertEq(oracle.getPrice(address(tok)), 200e18);
        assertTrue(oracle.hasFeed(address(tok)));
        assertFalse(oracle.hasFeed(address(0xBEEF)));
        // 1.5 tokens -> 300 USDG (6 decimals)
        assertEq(oracle.convert(address(tok), 1.5e18, address(usdg)), 300e6);
        assertEq(oracle.convert(address(usdg), 300e6, address(tok)), 1.5e18);
        assertEq(oracle.convert(address(usdg), 0, address(tok)), 0);
    }

    function test_revertsOnBadData() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(0xBEEF)));
        oracle.getPrice(address(0xBEEF));

        feed.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tok)));
        oracle.getPrice(address(tok));

        feed.setPrice(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tok)));
        oracle.getPrice(address(tok));

        // incomplete round
        feed.setRound(50, 200e8, block.timestamp, block.timestamp, 49);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tok)));
        oracle.getPrice(address(tok));

        // stale
        feed.setRound(51, 200e8, block.timestamp - 2 hours, block.timestamp - 2 hours, 51);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(tok), block.timestamp - 2 hours));
        oracle.getPrice(address(tok));

        // future timestamp
        feed.setRound(52, 200e8, block.timestamp + 1, block.timestamp + 1, 52);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(tok), block.timestamp + 1));
        oracle.getPrice(address(tok));
    }

    function test_sequencerCheck() public {
        seq = new MockAggregator(0, 0);
        seq.setRound(1, 0, block.timestamp - 2 hours, block.timestamp - 2 hours, 1);
        vm.prank(admin);
        oracle.setSequencerUptimeFeed(address(seq));
        assertEq(oracle.getPrice(address(tok)), 200e18);

        seq.setRound(2, 1, block.timestamp, block.timestamp, 2); // down
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(tok));

        seq.setRound(3, 0, block.timestamp - 10 minutes, block.timestamp, 3); // up but in grace period
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(tok));
    }

    function test_secondaryDeviation() public {
        vm.prank(admin);
        oracle.setFeed(address(tok), address(feed), 1 hours, address(secondary), 100); // 1%
        assertEq(oracle.getPrice(address(tok)), 200e18); // 0.5% apart

        feed2.setPrice(210e8); // ~4.8% apart
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceDeviation.selector, address(tok), 200e18, 210e18));
        oracle.getPrice(address(tok));
    }

    function test_setFeedValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(0), address(feed), 1 hours, address(0), 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(tok), address(feed), 10, address(0), 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(tok), address(feed), 5 days, address(0), 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(tok), address(feed), 1 hours, address(0), 2_001);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(tok), address(feed), 1 hours, address(secondary), 0);
        MockAggregator weird = new MockAggregator(19, 1);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(tok), address(weird), 1 hours, address(0), 0);
        vm.stopPrank();

        vm.expectRevert();
        oracle.setFeed(address(tok), address(feed), 1 hours, address(0), 0);
        vm.expectRevert();
        oracle.setSequencerUptimeFeed(address(0));
    }

    function test_roundPrice() public {
        feed.setPrice(210e8);
        (uint256 p, uint256 t) = oracle.getRoundPrice(address(tok), 1);
        assertEq(p, 200e18);
        assertEq(t, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(0xBEEF)));
        oracle.getRoundPrice(address(0xBEEF), 1);
        feed.setRound(9, -5, 1, 1, 9);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(tok)));
        oracle.getRoundPrice(address(tok), 9);
    }

    function testFuzz_convertRoundTrip(uint256 amount, uint256 price8) public {
        amount = bound(amount, 1e6, 1e30);
        price8 = bound(price8, 1e6, 1e14); // $0.01 .. $1M
        feed.setPrice(int256(price8));
        uint256 usd = oracle.convert(address(tok), amount, address(usdg));
        uint256 back = oracle.convert(address(usdg), usd, address(tok));
        assertLe(back, amount); // rounding never creates value
    }
}
