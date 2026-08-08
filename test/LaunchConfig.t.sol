// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployMainnet} from "../script/DeployMainnet.s.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";

/// @notice The numbers Lodestar publishes must be the numbers it deploys.
///
/// Grace, the Dutch curve, the fee split and the $100 floor appear in the docs, in the dapp and in
/// the audit scope. Until now several of them reached mainnet only because nobody had changed a
/// default in `src/` — a silent dependency, where editing a default would ship a protocol different
/// from the documented one with nothing in the deploy path to catch it. `DeployMainnet` now sets
/// them explicitly; this pins those constants so a change to either side has to be deliberate.
///
/// No fork needed: these are compile-time constants, read through inheritance. This test is
/// deliberately dumb — it exists to fail loudly when a number moves, not to prove anything clever.
contract LaunchConfigTest is Test, DeployMainnet {
    function test_PublishedRiskNumbersMatchTheDeployScript() public pure {
        // "repay by the deadline, plus 48 hours of grace before anyone can settle"
        assertEq(GRACE_PERIOD, 48 hours, "grace period is published as 48h");
        // "a Dutch floor decaying from 100% to 85% of the oracle price over 24 hours"
        assertEq(SETTLE_START_BPS, 10_000, "Dutch floor starts at 100%");
        assertEq(SETTLE_FLOOR_MIN_BPS, 8_500, "and decays to 85%");
        assertEq(SETTLE_DECAY_PERIOD, 24 hours, "over 24 hours");
        // "80% of every fee is lender yield; 20% builds the first-loss reserve"
        assertEq(FEE_RESERVE_BPS, 2000, "20% of each fee to the reserve");
        // settlement incentives
        assertEq(KEEPER_BPS, 500, "5% of collateral to the settling keeper");
        assertEq(PENALTY_BPS, 500, "5% of principal to the reserve on default");
        // "borrow from $100"
        assertEq(MIN_PRINCIPAL, 100e6, "$100 minimum loan, USDT0 at 6dp");
    }

    /// @dev Every value above must also be ACCEPTED by the setter it is passed to. A constant that
    ///      violates a bound would revert the whole mainnet deploy — after the immutable oracle,
    ///      pool and book have already been created, and after gas has been spent on them.
    function test_EveryLaunchConstantPassesItsOwnBound() public pure {
        assertTrue(KEEPER_BPS <= 1000 && PENALTY_BPS <= 2000, "setRiskParams bounds");
        assertTrue(FEE_RESERVE_BPS <= 10_000 && GRACE_PERIOD <= 14 days, "setRiskParams bounds");
        assertTrue(SETTLE_FLOOR_MIN_BPS >= 5000, "setSettleCurve: floor >= 50%");
        assertTrue(SETTLE_START_BPS >= SETTLE_FLOOR_MIN_BPS && SETTLE_START_BPS <= 10_500, "setSettleCurve");
        assertTrue(SETTLE_DECAY_PERIOD >= 1 hours && SETTLE_DECAY_PERIOD <= 7 days, "setSettleCurve");
        // setMaxActiveLoans is bounded [50, 400]; 400 is the ceiling the exit-sweep gas measurement
        // in test/SweepGasCeiling.t.sol supports (~9.9M gas in a mass crash, 35% of a 28M block).
        assertTrue(MAX_ACTIVE_LOANS >= 50 && MAX_ACTIVE_LOANS <= 400, "setMaxActiveLoans bounds");
    }

    /// @dev The exposure cap is what actually binds at launch, not the slot ceiling. Stated as a
    ///      test so the relationship is checked rather than asserted in a comment: the cap runs out
    ///      after ~250 loans of MIN_PRINCIPAL, well before the 400 slots do.
    function test_ExposureCapBindsBeforeTheSlotCeiling() public pure {
        // CAP_LAUNCH_USD18 is 18dp; MIN_PRINCIPAL is the 6dp pool asset.
        uint256 loansToExhaustCap = CAP_LAUNCH_USD18 / (uint256(MIN_PRINCIPAL) * 1e12);
        assertLt(loansToExhaustCap, MAX_ACTIVE_LOANS, "the exposure cap must bind first at launch");
        assertEq(loansToExhaustCap, 250, "25k / $100");
    }
}
