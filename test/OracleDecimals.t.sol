// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {MockERC20, MockFtsoV2} from "./Lodestar.t.sol";

/// @notice Locks in that FTSO's per-feed decimals (seen live: BTC=2, XRP=6, FLR=8) are always
///         normalised to 1e18 exactly. A hardcoded-decimals oracle would badly misprice feeds.
contract OracleDecimalsTest is Test {
    MockFtsoV2 ftso;
    MockERC20 token6;
    MockERC20 token18;
    LodestarOracle oracle;
    bytes21 constant FEED = bytes21("X/USD");

    function setUp() public {
        ftso = new MockFtsoV2();
        token6 = new MockERC20("T6", "T6", 6);
        token18 = new MockERC20("T18", "T18", 18);
        oracle = new LodestarOracle(address(ftso), address(this));
        oracle.setFeed(address(token6), FEED, address(0), 1 days);
        oracle.setFeed(address(token18), FEED, address(0), 1 days);
    }

    /// Any (raw value, decimals) pair normalises to raw * 10**(18-decimals), for all decimals 0..18.
    function testFuzz_priceNormalisesExactly(uint256 raw, uint8 dRaw) public {
        uint8 d = uint8(bound(dRaw, 0, 18));
        raw = bound(raw, 1, 1e15);
        ftso.set(FEED, raw, int8(d));
        uint256 expected = raw * (10 ** (18 - uint256(d)));
        assertEq(oracle.priceUsd18(address(token6)), expected, "decimal scaling wrong");
    }

    /// Concrete real-world feed shapes: BTC(2dp), XRP(6dp), FLR(8dp) all price correctly.
    function test_realFeedShapes() public {
        ftso.set(FEED, 6_411_866, 2); // $64,118.66 BTC-style
        assertEq(oracle.priceUsd18(address(token6)), 64_118_660_000_000_000_000_000);
        ftso.set(FEED, 1_095_700, 6); // $1.0957 XRP-style
        assertEq(oracle.priceUsd18(address(token6)), 1_095_700_000_000_000_000);
        ftso.set(FEED, 667_000, 8); // $0.00667 FLR-style
        assertEq(oracle.priceUsd18(address(token6)), 6_670_000_000_000_000);
    }

    /// usdValue18 accounts for the token's own decimals independent of the feed's decimals.
    function test_usdValueUsesTokenDecimals() public {
        ftso.set(FEED, 2_500_000, 6); // $2.50
        // 1000 units of a 6dp token = $2,500
        assertEq(oracle.usdValue18(address(token6), 1000e6), 2_500e18);
        // 1000 units of an 18dp token = $2,500
        assertEq(oracle.usdValue18(address(token18), 1000e18), 2_500e18);
    }

    /// A zero/blank feed is rejected rather than silently pricing collateral at 0.
    function test_zeroPriceReverts() public {
        ftso.set(FEED, 0, 6);
        vm.expectRevert(LodestarOracle.BadPrice.selector);
        oracle.priceUsd18(address(token6));
    }
}
