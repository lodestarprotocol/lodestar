// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter, MockRate} from "../Lodestar.t.sol";

/// @dev Collateral token that re-enters the book on transfer (ERC777-style hook) to prove the
///      nonReentrant guards hold even for a hookable collateral released mid-call.
contract ReentrantToken is MockERC20 {
    LodestarLoanBook public book;
    bool public armed;

    constructor() MockERC20("REENT", "REENT", 18) {}

    function arm(LodestarLoanBook _b) external {
        book = _b;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && address(book) != address(0) && from == address(book)) {
            armed = false; // one shot: try to re-enter the guarded book during the release transfer
            book.impair(1);
        }
    }
}

/// @notice Adversarial suite for partialRepay. Every test tries to break a stated invariant and
///         asserts it cannot. See PARTIAL_REPAY_SPEC.md (invariants I1-I12, tests T1-T15).
contract LodestarPartialRepayTest is Test {
    MockERC20 usdt0; // 6dp stable
    MockERC20 fxrp; // 6dp collateral (XRP, 1:1, no rate provider)
    MockERC20 sflr; // 18dp collateral (LST, rate provider)
    MockFtsoV2 ftso;
    MockRouter router;
    MockRate sflrRate;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    bytes21 constant XRP = bytes21("XRP/USD");
    bytes21 constant FLR = bytes21("FLR/USD");

    address owner = address(this);
    address reserve = makeAddr("reserve");
    address attacker = makeAddr("attacker");
    address borrower = makeAddr("borrower");
    address helper = makeAddr("helper"); // third-party payer

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        sflr = new MockERC20("SFLR", "SFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        ftso.set(FLR, 2_000_000, 8); // $0.02
        sflrRate = new MockRate(); // 1e18 = 1:1 to start

        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        oracle.setFeed(address(sflr), FLR, address(sflrRate), 1 hours, 0);

        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, owner, owner);
        pool.setLoanBook(address(book));
        book.setReserve(reserve);
        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200); // 50% LTV, 7d, 2% fee
        book.addTier(address(sflr), 5000, 7 days, 200);

        usdt0.mint(owner, 200_000e6);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(200_000e6, owner);
        usdt0.mint(address(router), 1_000_000e6);
    }

    // ------------------------------------------------------------------ helpers
    function _borrowFxrp(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), coll);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    function _borrowSflr(address who, uint256 coll) internal returns (uint256 id) {
        sflr.mint(who, coll);
        vm.startPrank(who);
        sflr.approve(address(book), coll);
        id = book.open(address(sflr), coll, 0);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amt) internal {
        usdt0.mint(who, amt);
        vm.prank(who);
        usdt0.approve(address(book), type(uint256).max);
        vm.prank(who);
        usdt0.approve(address(pool), type(uint256).max);
    }

    // Loan = (borrower, collateral, collAmount, principal, fee, principalUsd18, openedAt, dueAt,
    //         active, openRate, impairedLoss) -> 11 fields.
    function _principal(uint256 id) internal view returns (uint256 p) {
        (,,, p,,,,,,,) = book.loans(id);
    }

    function _collAmount(uint256 id) internal view returns (uint256 c) {
        (,, c,,,,,,,,) = book.loans(id);
    }

    function _active(uint256 id) internal view returns (bool a) {
        (,,,,,,,, a,,) = book.loans(id);
    }

    // ------------------------------------------------------------------ T1: paydown happy path
    function test_T1_PaydownReducesPrincipalKeepsCollateral() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6, coll 1000e6
        assertEq(_principal(id), 1_250e6);
        uint256 poOut0 = pool.principalOut();
        uint256 coll0 = _collAmount(id);

        _fund(borrower, 500e6);
        vm.prank(borrower);
        book.partialRepay(id, 500e6, 0, 0, 0);

        assertEq(_principal(id), 750e6, "principal not paid down");
        assertEq(_collAmount(id), coll0, "collateral moved on a pure paydown");
        assertEq(pool.principalOut(), poOut0 - 500e6, "principalOut not reduced by exactly repay");

        // borrower can still fully close and reclaim ALL collateral afterwards
        _fund(borrower, 750e6);
        vm.prank(borrower);
        book.repay(id);
        assertEq(fxrp.balanceOf(borrower), 1_000e6, "collateral not fully returned at close");
    }

    // ------------------------------------------------------------------ T2: release happy path
    function test_T2_ReleaseReturnsBoundedCollateral() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6
        _fund(borrower, 500e6);
        // after -> principal 750e6; at 50% LTV need remColl value >= 1500usd => >=600 XRP; release up to 400
        vm.prank(borrower);
        book.partialRepay(id, 500e6, 300e6, 0, 0);
        assertEq(_principal(id), 750e6);
        assertEq(_collAmount(id), 700e6, "remaining collateral wrong");
        assertEq(fxrp.balanceOf(borrower), 300e6, "borrower did not receive released collateral");
    }

    // ------------------------------------------------------------------ T3: strip attack
    function test_T3_CannotStripBelowLTV() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6);
        _fund(borrower, 500e6);
        // releasing 500 leaves 500 XRP = 1250usd; *0.5 = 625 < 750 principal -> revert
        vm.prank(borrower);
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.partialRepay(id, 500e6, 500e6, 0, 0);
    }

    function test_T3b_UnderwaterLoanCannotReleaseAnyCollateral() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6);
        ftso.set(XRP, 50_000_000, 8); // crash to $0.50 -> deeply underwater
        _fund(borrower, 100e6);
        vm.prank(borrower);
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.partialRepay(id, 100e6, 1, 0, 0); // even 1 unit of release must fail
    }

    // ------------------------------------------------------------------ T4: dust / bounds
    function test_T4_BoundsRejected() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6, minPrincipal 10e6
        _fund(borrower, 2_000e6);
        vm.startPrank(borrower);
        vm.expectRevert(LodestarLoanBook.BadParam.selector); // zero
        book.partialRepay(id, 0, 0, 0, 0);
        vm.expectRevert(LodestarLoanBook.BadParam.selector); // == full principal
        book.partialRepay(id, 1_250e6, 0, 0, 0);
        vm.expectRevert(LodestarLoanBook.BadParam.selector); // > full principal
        book.partialRepay(id, 1_251e6, 0, 0, 0);
        vm.expectRevert(LodestarLoanBook.BadParam.selector); // leaves dust < minPrincipal (10e6)
        book.partialRepay(id, 1_245e6, 0, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ T5: impairment skim
    function test_T5_PartialRepayCannotSkimShareholders() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6
        ftso.set(XRP, 50_000_000, 8); // crash -> underwater
        book.impair(id); // mark the loss into the pool

        // attacker becomes a big lender, then tries to profit by paying down the marked loan.
        // Measure the FULL round trip against the attacker's true starting funds: nothing else
        // is minted to them, so ending with more than they started == a skim.
        _fund(attacker, 150_500e6);
        uint256 startBal = usdt0.balanceOf(attacker); // 150_500e6, pre-deposit
        vm.prank(attacker);
        uint256 shares = pool.deposit(150_000e6, attacker);

        vm.prank(attacker);
        book.partialRepay(id, 500e6, 0, 0, 0); // pays 500 to lift the mark

        vm.prank(attacker);
        pool.redeem(shares, attacker, attacker);

        assertLe(usdt0.balanceOf(attacker), startBal, "attacker profited from a partial-repay round trip");
    }

    // ------------------------------------------------------------------ T6: impairment true-up
    function test_T6_ImpairmentReducedByRealizedCashOnly() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6
        ftso.set(XRP, 50_000_000, 8); // $0.50 -> underwater
        book.impair(id);
        uint256 marked0 = pool.impairedLoss();
        assertGt(marked0, 0, "loan should be marked");

        _fund(borrower, 300e6);
        vm.prank(borrower);
        book.partialRepay(id, 300e6, 0, 0, 0);
        // realized-only: mark falls by exactly min(mark, 300)
        assertEq(pool.impairedLoss(), marked0 - 300e6, "mark not reduced by exactly the realized cash");

        // closing later must reverse the remaining mark with no underflow
        _fund(borrower, 950e6);
        vm.prank(borrower);
        book.repay(id);
        assertEq(pool.impairedLoss(), 0, "residual mark not cleared at close");
    }

    // ------------------------------------------------------------------ T7: exposure / cap accounting
    function test_T7_ExposureFreedProportionally() public {
        book.setExposureCap(address(fxrp), 1_250e18); // exactly one max loan of usd exposure
        uint256 id = _borrowFxrp(borrower, 1_000e6); // uses full 1250e18 cap
        assertEq(book.exposureUsd18(address(fxrp)), 1_250e18);

        _fund(borrower, 500e6);
        vm.prank(borrower);
        book.partialRepay(id, 500e6, 0, 0, 0); // frees 1250e18 * 500/1250 = 500e18
        assertEq(book.exposureUsd18(address(fxrp)), 750e18, "exposure not freed proportionally");

        // the freed cap is exactly reusable by a fresh borrow
        uint256 id2 = _borrowFxrp(attacker, 400e6); // 400 XRP -> 1000usd *0.5 = 500e18 principalUsd18
        assertEq(book.exposureUsd18(address(fxrp)), 1_250e18, "freed cap not reusable");

        // full close of both zeroes exposure exactly (no drift)
        _fund(borrower, 750e6);
        vm.prank(borrower);
        book.repay(id);
        _fund(attacker, 500e6);
        vm.prank(attacker);
        book.repay(id2);
        assertEq(book.exposureUsd18(address(fxrp)), 0, "exposure did not net to zero");
    }

    // ------------------------------------------------------------------ T8: skim not dodgeable
    function test_T8_ReleaseSkimNotDodgeableViaChunks() public {
        book.setYieldSkimBps(1000); // 10%
        // two identical LST loans; one released in one shot, one in three chunks
        uint256 idA = _borrowSflr(borrower, 100_000e18); // principal 1000e6
        uint256 idB = _borrowSflr(helper, 100_000e18);
        sflrRate.set(1.1e18); // 10% appreciation, constant for both paths (price -> $0.022)

        // Both paths end at principal 750e6 / remaining 70_000 sflr (value $1540, *0.5=770 >= 750).
        // A: pay 250 down, single release of 30_000.
        _fund(borrower, 250e6);
        vm.prank(borrower);
        book.partialRepay(idA, 250e6, 30_000e18, 0, 0);
        uint256 skimA = sflr.balanceOf(reserve);

        // B: same 250 down + 30_000 out, split into three LTV-legal chunks.
        _fund(helper, 250e6);
        vm.startPrank(helper);
        book.partialRepay(idB, 100e6, 10_000e18, 0, 0); // -> p900 / 90_000 (990>=900)
        book.partialRepay(idB, 100e6, 10_000e18, 0, 0); // -> p800 / 80_000 (880>=800)
        book.partialRepay(idB, 50e6, 10_000e18, 0, 0); //  -> p750 / 70_000 (770>=750)
        vm.stopPrank();
        uint256 skimB = sflr.balanceOf(reserve) - skimA;

        assertApproxEqAbs(skimA, skimB, 10, "chunked release dodged the yield skim");
        assertGt(skimA, 0, "no skim taken on appreciated collateral");
    }

    // ------------------------------------------------------------------ T9: oracle-down liveness
    function test_T9_PaydownWorksOracleDownReleaseDoesNot() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6);
        ftso.set(XRP, 0, 8); // FTSO down -> usdValue18 reverts
        _fund(borrower, 500e6);

        // pure paydown must still work (no oracle read)
        vm.prank(borrower);
        book.partialRepay(id, 500e6, 0, 0, 0);
        assertEq(_principal(id), 750e6);

        // release must revert while the oracle is down
        _fund(borrower, 100e6);
        vm.prank(borrower);
        vm.expectRevert(); // BadPrice from the oracle
        book.partialRepay(id, 100e6, 100e6, 0, 0);
    }

    // ------------------------------------------------------------------ T10: post-default
    function test_T10_PostDefaultPaydownYesReleaseNo() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1); // past due + grace = defaulted
        assertTrue(book.isDefaulted(id));
        _fund(borrower, 600e6);

        // paydown (cure) still allowed
        vm.prank(borrower);
        book.partialRepay(id, 500e6, 0, 0, 0);
        assertEq(_principal(id), 750e6);

        // release forbidden once defaulted
        vm.prank(borrower);
        vm.expectRevert(LodestarLoanBook.Defaulted.selector);
        book.partialRepay(id, 100e6, 1, 0, 0);
    }

    // ------------------------------------------------------------------ T11: reentrancy
    function test_T11_HookableCollateralCannotReenter() public {
        ReentrantToken rt = new ReentrantToken();
        oracle.setFeed(address(rt), XRP, address(0), 1 hours, 0);
        book.addTier(address(rt), 5000, 7 days, 200);
        rt.mint(borrower, 1_000e18);
        vm.startPrank(borrower);
        rt.approve(address(book), 1_000e18);
        uint256 id = book.open(address(rt), 1_000e18, 0);
        vm.stopPrank();

        rt.arm(book); // next transfer FROM the book re-enters book.impair()
        _fund(borrower, 500e6);
        vm.prank(borrower);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        book.partialRepay(id, 500e6, 100e18, 0, 0); // release triggers the hook
    }

    // ------------------------------------------------------------------ T12: precision fuzz
    function testFuzz_T12_LifecycleNetsToBaseline(uint256 r1, uint256 r2) public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6
        uint256 poBase = pool.principalOut() - 1_250e6; // baseline before this loan
        r1 = bound(r1, 1, 600e6);
        r2 = bound(r2, 1, 300e6);
        // keep each step above the dust floor on the remainder
        vm.assume(1_250e6 - r1 >= 10e6);
        vm.assume(1_250e6 - r1 - r2 >= 10e6);

        _fund(borrower, 5_000e6);
        vm.startPrank(borrower);
        book.partialRepay(id, r1, 0, 0, 0);
        book.partialRepay(id, r2, 0, 0, 0);
        book.repay(id);
        vm.stopPrank();

        assertEq(pool.principalOut(), poBase, "principalOut drifted over the lifecycle");
        assertEq(book.exposureUsd18(address(fxrp)), 0, "exposure drifted over the lifecycle");
        assertEq(pool.impairedLoss(), 0, "impairment drifted over the lifecycle");
        assertEq(fxrp.balanceOf(borrower), 1_000e6, "collateral not fully recovered");
    }

    // ------------------------------------------------------------------ T13: third-party payer
    function test_T13_ThirdPartyPayerCannotTakeCollateral() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6);
        _fund(helper, 500e6);
        vm.prank(helper);
        book.partialRepay(id, 500e6, 300e6, 0, 0); // helper pays + releases
        assertEq(fxrp.balanceOf(borrower), 300e6, "released collateral did not go to the borrower");
        assertEq(fxrp.balanceOf(helper), 0, "third-party payer received collateral");
    }

    // ------------------------------------------------------------------ T14: slippage guard
    function test_T14_MinCollateralReceivedGuard() public {
        book.setYieldSkimBps(1000);
        uint256 id = _borrowSflr(borrower, 100_000e18);
        sflrRate.set(1.1e18); // skim will apply -> net < gross
        _fund(borrower, 100e6);
        vm.prank(borrower);
        vm.expectRevert(LodestarLoanBook.Slippage.selector);
        book.partialRepay(id, 100e6, 10_000e18, 0, 10_000e18); // demand full gross despite the skim
    }

    // ------------------------------------------------------------------ T15: settlement race
    function test_T15_PartialThenSettleReconciles() public {
        uint256 id = _borrowFxrp(borrower, 1_000e6); // principal 1250e6
        _fund(borrower, 250e6);
        vm.prank(borrower);
        book.partialRepay(id, 250e6, 0, 0, 0); // principal -> 1000e6
        assertEq(_principal(id), 1_000e6);

        vm.warp(block.timestamp + 7 days + 48 hours + 1); // default
        uint256 poBefore = pool.principalOut();
        // keeper settles the remainder via buyout at the floor
        uint256 cost = book.buyoutCost(id);
        _fund(attacker, cost + 1);
        vm.prank(attacker);
        book.buyout(id, cost);

        assertFalse(_active(id), "loan still active after settlement");
        assertEq(pool.principalOut(), poBefore - 1_000e6, "principalOut not reduced by the remaining principal");
        assertEq(fxrp.balanceOf(attacker), 1_000e6, "buyer did not receive the remaining collateral");
    }
}
