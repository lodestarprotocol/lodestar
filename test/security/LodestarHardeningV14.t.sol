// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter, MockRate} from "../Lodestar.t.sol";

/// @notice Regressions for the v1.4 deep-audit hardening pass. Each test locks in one fix from
///         the six-agent adversarial review (stale-mark skim, phantom solvency, retroactive
///         params, oracle haircut/staleness, buffer front-run, donation recovery).
contract LodestarHardeningV14Test is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockERC20 sflr;
    MockFtsoV2 ftso;
    MockRouter router;
    MockRate sflrRate;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant XRP = bytes21("XRP/USD");
    bytes21 constant FLR = bytes21("FLR/USD");

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address lp2 = address(0x1E7E);
    address borrower = address(0xB0B);
    address attacker = makeAddr("attacker");
    address keeper = address(0xC0FFEE);

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        sflr = new MockERC20("Staked FLR", "sFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        ftso.set(FLR, 2_000_000, 8); // $0.02
        sflrRate = new MockRate();
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        oracle.setFeed(address(sflr), FLR, address(sflrRate), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.addTier(address(sflr), 5500, 30 days, 300);
        usdt0.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lender);
        vm.stopPrank();
        usdt0.mint(address(router), 1_000_000e6);
    }

    function _openFxrp(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), type(uint256).max);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    // ---- Fix 1: monotonic impair kills the atomic stale-mark skim ---------------------------
    function test_AtomicStaleMarkSkimIsBlocked() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        // crash, mark the loss, then the price fully recovers
        ftso.set(XRP, 25_000_000, 8);
        book.impair(id);
        assertGt(pool.impairedLoss(), 0, "loss not marked");
        ftso.set(XRP, 250_000_000, 8); // recovered, but mark is stale (monotonic keeps it)

        // attacker tries deposit -> impair(recovered) -> redeem to skim the reversal in one flow
        usdt0.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(100_000e6, attacker);
        book.impair(id); // monotonic: does NOT lower the mark, so no reversal to capture
        uint256 got = pool.redeem(shares, attacker, attacker);
        vm.stopPrank();
        assertLe(got, 100_000e6, "attacker skimmed the stale-mark reversal");
    }

    // ---- v1.5: phantom-solvency window closed ON-CHAIN (withdraw self-marks the book) --------
    function test_WithdrawMarksUnmarkedUnderwaterLoan_NoParExit() public {
        // second lender joins so there's a victim to dump losses on
        usdt0.mint(lp2, 100_000e6);
        vm.startPrank(lp2);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lp2);
        vm.stopPrank();

        // a loan goes deeply underwater, and NOBODY calls impair
        uint256 id = _openFxrp(borrower, 40_000e6); // $100k coll -> $50k principal
        ftso.set(XRP, 25_000_000, 8); // 90% crash: coll now ~$10k vs $50k owed
        assertEq(pool.impairedLoss(), 0, "precondition: loss is unmarked");

        // the informed lender tries to exit at par before anyone marks the loss
        uint256 idle = pool.available();
        uint256 shares = pool.balanceOf(lender);
        vm.startPrank(lender);
        uint256 got = pool.redeem(pool.maxRedeem(lender), lender, lender);
        vm.stopPrank();

        // the withdraw itself marked the book, so the exit was priced BELOW par, not at it
        assertGt(pool.impairedLoss(), 0, "withdraw did not mark the underwater loan");
        // lender got their (now marked-down) share of idle, strictly less than a par exit
        assertLt(got, shares / 1e6, "lender escaped at (near) par despite an unmarked loss");
        assertLe(got, idle, "exit exceeded idle liquidity");
    }

    function test_ActiveLoanArrayTracksOpenLoans() public {
        assertEq(book.activeLoanCount(), 0);
        uint256 a = _openFxrp(borrower, 1000e6);
        uint256 b = _openFxrp(borrower, 1000e6);
        assertEq(book.activeLoanCount(), 2);
        usdt0.mint(borrower, 2500e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(a);
        vm.stopPrank();
        assertEq(book.activeLoanCount(), 1, "closed loan not removed from sweep set");
        // the surviving id is still active and sweeps fine
        book.impair(b);
        assertEq(book.activeLoanCount(), 1);
    }

    function test_MaxActiveLoansCapEnforced() public {
        book.setMaxActiveLoans(50); // bound
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setMaxActiveLoans(10); // below the floor
        // opening within the cap works; the cap itself is exercised by the invariant fuzz
        uint256 id = _openFxrp(borrower, 1000e6);
        assertEq(book.activeLoanCount(), 1);
        assertGt(id, 0);
    }

    // ---- v1.6: loan-slot-exhaustion DoS is priced out by a meaningful minPrincipal -----------
    function test_SlotExhaustionRequiresRealCapital() public {
        // With a mainnet-grade minPrincipal, filling the loan cap costs real, locked capital.
        book.setMaxActiveLoans(50); // small cap for a fast test
        book.setMinPrincipal(uint128(100e6)); // $100 min loan (mainnet-style, not the $10 testnet)
        // a $100 principal at 50% LTV needs $200 collateral = 80 FXRP; filling 50 slots = $10k locked
        uint256 fxrpNeeded = 80e6;
        for (uint256 i; i < 50; i++) {
            address b = address(uint160(0xDEAD00 + i));
            fxrp.mint(b, fxrpNeeded);
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), fxrpNeeded, 0);
            vm.stopPrank();
        }
        assertEq(book.activeLoanCount(), 50, "cap not reached");
        // the 51st open is blocked (the DoS state) — but it cost the griefer $10k of locked FXRP
        fxrp.mint(borrower, fxrpNeeded);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.TooManyActiveLoans.selector);
        book.open(address(fxrp), fxrpNeeded, 0);
        vm.stopPrank();
        // custody proves the capital is genuinely locked (50 * 80 FXRP), i.e. the attack has a cost
        assertEq(fxrp.balanceOf(address(book)), 50 * fxrpNeeded, "griefer capital not locked");
    }

    function test_MaxActiveLoansSetterBounded() public {
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setMaxActiveLoans(401); // above the block-gas-safe ceiling
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setMaxActiveLoans(49); // below floor
        book.setMaxActiveLoans(400); // exactly at the safe max is fine
        assertEq(book.maxActiveLoans(), 400);
    }

    // ---- Fix 2: phantom-solvency window is closable in one batch call ------------------------
    function test_ImpairManyBatchMarksWholeBook() public {
        uint256 a = _openFxrp(borrower, 1000e6);
        uint256 b = _openFxrp(borrower, 1000e6);
        ftso.set(XRP, 25_000_000, 8); // 90% crash, both loans underwater, unmarked
        assertEq(pool.impairedLoss(), 0, "should be unmarked pre-batch");
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = 999; // nonexistent/inactive id must be skipped, not revert
        book.impairMany(ids);
        assertGt(pool.impairedLoss(), 0, "batch did not mark the book");
    }

    // ---- Fix 3a: yieldSkim snapshot — owner can't retroactively confiscate ------------------
    function test_YieldSkimSnapshotBlocksRetroConfiscation() public {
        // loan opens under skim = 0 (borrower keeps all appreciation)
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();
        sflrRate.set(1.1e18); // 10% appreciation during the term

        // owner flips skim to the 50% cap right before repay — must NOT affect this loan
        book.setYieldSkimBps(5000);

        usdt0.mint(borrower, 40e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(sflr.balanceOf(borrower), 100_000e18, "retroactive skim confiscated appreciation");
        assertEq(sflr.balanceOf(reserve), 0, "reserve wrongly skimmed a pre-existing loan");
    }

    // ---- Fix 3b: grace snapshot — owner can't erase an existing loan's cure window ----------
    function test_GraceSnapshotBlocksInstantDefault() public {
        uint256 id = _openFxrp(borrower, 1000e6); // 48h grace snapshotted
        vm.warp(block.timestamp + 7 days + 1); // past due, 1s into grace
        book.setRiskParams(0, 500, 500, 2000); // owner drops global grace to 0
        assertFalse(book.isDefaulted(id), "existing loan pushed into instant default");
        vm.warp(block.timestamp + 48 hours); // its OWN 48h grace elapses
        assertTrue(book.isDefaulted(id), "loan should default on its snapshotted grace");
    }

    // ---- Fix 3c: settle-curve snapshot — owner can't lower the floor on an existing default --
    function test_SettleCurveSnapshotFixesFloor() public {
        uint256 id = _openFxrp(borrower, 1000e6); // curve 100->85% snapshotted
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 costBefore = book.buyoutCost(id);
        // owner slams the global floor to the 50% minimum
        book.setSettleCurve(5000, 5000, 1 hours);
        uint256 costAfter = book.buyoutCost(id);
        assertEq(costAfter, costBefore, "existing loan's floor was retroactively lowered");
    }

    // new loans DO pick up the new (owner-set) defaults
    function test_NewLoanUsesNewDefaults() public {
        book.setRiskParams(24 hours, 500, 500, 2000); // grace 24h for new loans
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 24 hours + 1);
        assertTrue(book.isDefaulted(id), "new loan didn't take the new 24h grace");
    }

    // ---- Fix 4: oracle haircut lowers realizable value everywhere ---------------------------
    function test_HaircutLowersValuation() public {
        uint256 full = oracle.usdValue18(address(fxrp), 1000e6); // no haircut
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 1000); // 10% haircut
        uint256 cut = oracle.usdValue18(address(fxrp), 1000e6);
        assertApproxEqRel(cut, (full * 9000) / 10_000, 1e15, "haircut not applied");
    }

    function test_MaxStaleBoundTightened() public {
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.setFeed(address(fxrp), XRP, address(0), 2 hours, 0); // > 1h forbidden
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 6000); // haircut > 50% forbidden
    }

    // ---- Fix 5: withdrawReserve can't drain the buffer earmarked against marked losses ------
    function test_WithdrawReserveCannotDrainEarmarkedBuffer() public {
        // build a buffer via a fee-paying loan
        uint256 id0 = _openFxrp(address(0xFEE), 1000e6);
        usdt0.mint(address(0xFEE), 1250e6);
        vm.startPrank(address(0xFEE));
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6, "buffer not funded");

        // a loan defaults underwater and is marked
        uint256 id = _openFxrp(borrower, 1000e6);
        ftso.set(XRP, 50_000_000, 8);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        book.impair(id);
        assertGt(pool.impairedLoss(), book.reserveBalance(), "loss should exceed buffer");

        // owner cannot pull the buffer while it is earmarked against the marked loss
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.withdrawReserve(5e6);
    }

    // ---- withdrawReserve syncs impairment first, so the guard holds even on an UNMARKED bad loan --
    function test_WithdrawReserveSyncsBeforeGuard_BlocksDrainAheadOfUnmarkedLoss() public {
        // fund the buffer
        uint256 id0 = _openFxrp(address(0xFEE), 1000e6);
        usdt0.mint(address(0xFEE), 1250e6);
        vm.startPrank(address(0xFEE));
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6);

        // a loan goes deeply underwater and defaults, but NOBODY marks it (impairedLoss stays 0)
        _openFxrp(borrower, 1000e6);
        ftso.set(XRP, 50_000_000, 8);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        assertEq(pool.impairedLoss(), 0, "loss deliberately left unmarked");

        // Before the fix this drained the buffer ahead of the known-bad loan (the guard read the
        // stale impairedLoss()==0). Now withdrawReserve runs _syncAll() first, so the guard sees the
        // real earmark and reverts. (The sync's state change rolls back with the revert, so it is
        // unobservable after — the revert itself is the proof the earmark was raised in-call.)
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.withdrawReserve(5e6);
    }

    // Positive control: with NO underwater loan, the identical drain succeeds — proving the revert
    // above is caused by the in-call sync marking the loss, not by an unconditional block.
    function test_WithdrawReserveStillWorksWhenBookIsHealthy() public {
        uint256 id0 = _openFxrp(address(0xFEE), 1000e6);
        usdt0.mint(address(0xFEE), 1250e6);
        vm.startPrank(address(0xFEE));
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6);

        // an open, healthy (not underwater, not defaulted) loan exists — sync marks zero loss
        _openFxrp(borrower, 1000e6);
        uint256 bufBefore = book.reserveBalance();
        uint256 reserveBefore = usdt0.balanceOf(reserve);
        book.withdrawReserve(5e6);
        assertEq(book.reserveBalance(), bufBefore - 5e6, "healthy book: buffer withdrawable");
        assertEq(usdt0.balanceOf(reserve), reserveBefore + 5e6, "reserve received the withdrawal");
    }

    // ---- Fix 6: donated stable is recoverable, never stranded -------------------------------
    function test_SweepStableDonations() public {
        usdt0.mint(attacker, 1_000e6);
        vm.prank(attacker);
        usdt0.transfer(address(book), 1_000e6); // gift, breaks == but not solvency
        assertGt(usdt0.balanceOf(address(book)), book.reserveBalance());
        book.sweepStableDonations(reserve);
        assertEq(usdt0.balanceOf(address(book)), book.reserveBalance(), "donation not swept back to buffer parity");
        assertEq(usdt0.balanceOf(reserve), 1_000e6, "donation not recovered");
    }

    // ---- Fix: exit liquidity is honestly reported and cleanly bounded -----------------------
    function test_MaxWithdrawClampedToLiquidity() public {
        // lend 100k, then lock most of it in a loan so idle < share value
        _openFxrp(borrower, 48_000e6); // $120k coll -> $60k principal (60% util, funds cleanly)
        uint256 idle = pool.available();
        uint256 mw = pool.maxWithdraw(lender);
        assertLe(mw, idle, "maxWithdraw over-reports vs idle liquidity");

        // a redeem beyond idle reverts with the pool's own semantic error, not a raw underflow
        uint256 shares = pool.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(LodestarPool.InsufficientLiquidity.selector);
        pool.redeem(shares, lender, lender);
    }
}
