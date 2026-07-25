// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {MockERC20, MockFtsoV2, MockRate} from "../Lodestar.t.sol";

/// @notice Regression for the 2026-07-25 audit finding: repeated permissionless `pokeRateAnchor`
///         used to reset the allowance window every call, compounding the valuation anchor up the
///         slope with NO cumulative ceiling (proven: 20 bps/day -> +19.7% at-90d, +107% at-365d,
///         unbounded in time — `MAX_CLAMP_WINDOW` only bounds a SINGLE read). The fix caps the anchor
///         and every read at a FIXED arm-epoch envelope (`armedRate/armedAt`, `MAX_TOTAL_CLAMP_WINDOW`).
contract AuditPokeCompound is Test {
    MockERC20 sflr;
    MockFtsoV2 ftso;
    MockRate rate;
    LodestarOracle oracle;
    bytes21 constant FLR = bytes21("FLR/USD");
    address owner = address(this);

    function setUp() public {
        sflr = new MockERC20("sFLR", "sFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(FLR, 5_000_000, 8); // $0.05
        rate = new MockRate(); // 1e18
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(sflr), FLR, address(rate), 1 hours, 0);
    }

    /// A compromised provider poked daily can no longer compound past the fixed cumulative envelope.
    function test_PokeCannotCompoundPastCumulativeEnvelope() public {
        oracle.setRateClamp(address(sflr), 20); // 20 bps/day, anchor = armedRate = 1e18
        uint256 base = oracle.priceUsd18(address(sflr)); // $0.05 at rate 1.0

        rate.set(type(uint128).max); // compromised provider reports a huge rate forever

        // Poke daily for 365 days. The envelope at day D is armedRate*(1 + 20bps*D).
        for (uint256 d = 0; d < 365; d++) {
            vm.warp(block.timestamp + 1 days);
            oracle.pokeRateAnchor(address(sflr));
            uint256 pd = oracle.priceUsd18(address(sflr));
            uint256 envBps = 10_000 + 20 * (d + 1); // linear envelope, +20 bps per day
            // valuation must never exceed the fixed linear envelope (was compounding e^(g*t) before)
            assertLe(pd, (base * envBps) / 10_000 + 2, "exceeded cumulative envelope");
        }

        uint256 p365 = oracle.priceUsd18(address(sflr));
        emit log_named_uint("over-valuation bps vs base at-365d (was 10735 pre-fix)", (p365 * 10_000) / base - 10_000);
        // Old compounding hit +107% (2.07x) at 365d; the fixed linear envelope caps at 20bps*365d = +73%.
        assertApproxEqRel(p365, (base * 17_300) / 10_000, 0.01e18, "365d should hit the +73% linear cap, not +107%");

        // Beyond MAX_TOTAL_CLAMP_WINDOW (365d) the envelope stops growing: more time + pokes add nothing.
        for (uint256 d = 0; d < 400; d++) {
            vm.warp(block.timestamp + 1 days);
            oracle.pokeRateAnchor(address(sflr));
        }
        uint256 pLater = oracle.priceUsd18(address(sflr));
        assertApproxEqRel(pLater, p365, 0.001e18, "envelope must be frozen past MAX_TOTAL_CLAMP_WINDOW");

        // SEVERITY: worst-ever over-valuation (1.73x) stays below the tightest launch bad-debt
        // threshold (50% LTV = 2x), so a compromised+poked provider can never mint bad debt.
        assertLt(pLater, base * 2, "must stay under the 2x (50% LTV) bad-debt threshold forever");
    }

    /// The cumulative cap must NOT clamp legitimate staking yield (honest provider, real growth).
    function test_LegitYieldStillPassesUnderCap() public {
        oracle.setRateClamp(address(sflr), 20);
        uint256 base = oracle.priceUsd18(address(sflr));
        // ~7%/yr real yield over 200 days, honest provider, keeper pokes monthly.
        for (uint256 m = 0; m < 6; m++) {
            vm.warp(block.timestamp + 30 days);
            uint256 realRate = 1e18 + (uint256(7e16) * (m + 1) * 30) / 365; // linear ~7%/yr
            rate.set(realRate);
            oracle.pokeRateAnchor(address(sflr));
            // honest yield is far under the 20bps/day envelope, so it passes through unclamped
            assertApproxEqRel(oracle.priceUsd18(address(sflr)), (base * realRate) / 1e18, 0.001e18, "legit yield clamped");
        }
    }
}
