// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {SceptreRateAdapter} from "../../src/flare/SceptreRateAdapter.sol";
import {FirelightRateAdapter} from "../../src/flare/FirelightRateAdapter.sol";

/// @notice Forks Flare MAINNET and proves the exact oracle wiring the deploy script will use
///         (real FtsoV2 + real FXRP + real sFLR via the adapter) resolves sane USD prices.
///   forge test --match-path test/fork/MainnetWiring.t.sol --fork-url https://flare-api.flare.network/ext/C/rpc
contract MainnetWiringTest is Test {
    address constant FTSO = 0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20;
    address constant FXRP = 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE; // 6dp
    address constant SFLR = 0x12e605bc104e93B45e1aD99F9e555f659051c2BB; // 18dp
    address constant STXRP = 0x4C18Ff3C89632c3Dd62E796c0aFA5c07c4c1B2b3; // Firelight stXRP, 6dp (ERC4626 over FXRP)
    bytes21 constant FEED_XRP = 0x015852502f55534400000000000000000000000000;
    bytes21 constant FEED_FLR = 0x01464c522f55534400000000000000000000000000;

    function test_MainnetOracleResolvesSanePrices() public {
        // skip gracefully if not run against a fork
        if (FTSO.code.length == 0) {
            emit log("no fork (FtsoV2 has no code) - run with --fork-url; skipping");
            return;
        }
        LodestarOracle oracle = new LodestarOracle(FTSO, address(this));
        oracle.setFeed(FXRP, FEED_XRP, address(0), 1 hours, 0);
        SceptreRateAdapter adapter = new SceptreRateAdapter(SFLR);
        oracle.setFeed(SFLR, FEED_FLR, address(adapter), 1 hours, 300); // 3% haircut

        uint256 xrp = oracle.priceUsd18(FXRP);
        uint256 sflr = oracle.priceUsd18(SFLR);
        uint256 rate = adapter.underlyingPerShare();
        emit log_named_uint("XRP/USD  (1e18)", xrp);
        emit log_named_uint("sFLR/USD (1e18)", sflr);
        emit log_named_uint("sFLR->FLR rate (1e18)", rate);

        // XRP realistically $0.20 - $20
        assertGt(xrp, 0.2e18, "XRP price too low");
        assertLt(xrp, 20e18, "XRP price too high");
        // sFLR is FLR-denominated; FLR realistically $0.005 - $2, times a >=1.0 staking rate, times 0.97 haircut
        assertGt(sflr, 0.004e18, "sFLR price too low");
        assertLt(sflr, 5e18, "sFLR price too high");
        // sFLR must be worth strictly more FLR than 1 (it accrues), and adapter rate >= 1e18
        assertGe(rate, 1e18, "sFLR rate below 1.0 (adapter wrong?)");
        assertLt(rate, 3e18, "sFLR rate implausibly high");

        // usdValue18 of a whole token matches priceUsd18 (decimals handled right)
        assertApproxEqRel(oracle.usdValue18(FXRP, 1e6), xrp, 1e12, "FXRP usdValue18 decimals off");
        assertApproxEqRel(oracle.usdValue18(SFLR, 1e18), sflr, 1e12, "sFLR usdValue18 decimals off");
    }

    /// @notice v1.8 rate clamp against the REAL Sceptre adapter on mainnet state: arming anchors at
    ///         the live rate without moving the price, the poke works, and the clamp math holds on
    ///         real numbers — exactly what DeployMainnet now executes at wiring time.
    function test_MainnetRateClampArmsOnRealSceptre() public {
        if (FTSO.code.length == 0) {
            emit log("no fork; skipping");
            return;
        }
        LodestarOracle oracle = new LodestarOracle(FTSO, address(this));
        SceptreRateAdapter adapter = new SceptreRateAdapter(SFLR);
        oracle.setFeed(SFLR, FEED_FLR, address(adapter), 1 hours, 300);

        uint256 before = oracle.priceUsd18(SFLR);
        oracle.setRateClamp(SFLR, 20); // what DeployMainnet does
        (uint192 anchor,) = oracle.rateAnchors(SFLR);
        assertEq(uint256(anchor), adapter.underlyingPerShare(), "anchor = live Sceptre rate");
        assertEq(oracle.priceUsd18(SFLR), before, "arming must not move the price");

        oracle.pokeRateAnchor(SFLR); // permissionless keeper duty works against the real provider
        (uint192 anchor2,) = oracle.rateAnchors(SFLR);
        assertEq(uint256(anchor2), uint256(anchor), "same-block poke is a no-op ratchet");
        emit log_named_uint("armed anchor (sFLR->FLR, 1e18)", uint256(anchor));
    }

    function test_MainnetStxrpResolvesSanePrice() public {
        if (STXRP.code.length == 0) {
            emit log("no fork; skipping");
            return;
        }
        LodestarOracle oracle = new LodestarOracle(FTSO, address(this));
        oracle.setFeed(FXRP, FEED_XRP, address(0), 1 hours, 0); // reference XRP price via FXRP
        FirelightRateAdapter adapter = new FirelightRateAdapter(STXRP);
        // stXRP is FXRP-backed, and FXRP is XRP 1:1, so it prices off the XRP/USD feed via the vault rate.
        oracle.setFeed(STXRP, FEED_XRP, address(adapter), 1 hours, 300);

        uint256 xrp = oracle.priceUsd18(FXRP);
        uint256 sx = oracle.priceUsd18(STXRP);
        uint256 rate = adapter.underlyingPerShare();
        emit log_named_uint("XRP/USD   (1e18)", xrp);
        emit log_named_uint("stXRP/USD (1e18)", sx);
        emit log_named_uint("stXRP->FXRP rate (1e18)", rate);

        // stXRP accrues FXRP, so 1 stXRP >= 1 FXRP; rate in [1.0, 1.5)
        assertGe(rate, 1e18, "stXRP rate below 1.0 (adapter wrong?)");
        assertLt(rate, 1.5e18, "stXRP rate implausibly high");
        // priced off XRP with a 3% haircut and the >=1.0 rate: sx ~= xrp * rate * 0.97, sane band
        assertGt(sx, (xrp * 90) / 100, "stXRP price too low vs XRP");
        assertLt(sx, (xrp * 110) / 100, "stXRP price too high vs XRP");
        // stXRP is 6dp: usdValue18 of one whole token matches priceUsd18
        assertApproxEqRel(oracle.usdValue18(STXRP, 1e6), sx, 1e12, "stXRP usdValue18 decimals off");
    }
}
