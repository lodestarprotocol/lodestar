// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2} from "../Lodestar.t.sol";

/// @notice `open()` with a slippage bound and a deadline.
///
/// Without them, the terms of a borrow are decided at execution time by whoever submits the
/// transaction. For a wallet user that window is seconds. For an XRPL user signing a payment that
/// some executor relays to Flare later, it is unbounded: collateral is priced at the FTSO reading at
/// the moment of inclusion, so a submitter can wait for a local low and underwrite the loan smaller.
/// There is no direct profit in doing so, which makes it free griefing rather than theft -- but
/// "you know your terms up front" is a core claim of this protocol, and without these it is false.
///
/// The properties that matter:
///   - the 3-argument form is unchanged, so every existing caller behaves exactly as before
///   - zero means unconstrained for both parameters, which is what makes that delegation exact
///   - minOut is measured on what the borrower RECEIVES (principal - fee), not on principal
contract OpenGuardsTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address bob = address(0xB0B);

    bytes21 constant XRP_USD = bytes21("XRP/USD");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP_USD, 250_000_000, 8); // $2.50
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP_USD, address(0), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));
        book.addTier(address(fxrp), 5000, 7 days, 200); // 50% LTV, 7d, 2% fee

        usdt0.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e6, lender);
        vm.stopPrank();

        fxrp.mint(bob, 1_000_000e6);
        vm.prank(bob);
        fxrp.approve(address(book), type(uint256).max);
    }

    // 1,000 FXRP @ $2.50 = $2,500; 50% LTV -> $1,250 principal; 2% fee -> $1,225 received.
    uint256 constant COLL = 1_000e6;
    uint256 constant EXPECT_PRINCIPAL = 1_250e6;
    uint256 constant EXPECT_RECEIVED = 1_225e6;

    // ---------------------------------------------------------------- deadline

    function test_DeadlineInFutureIsAccepted() public {
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0, 0, block.timestamp + 300);
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        assertEq(uint256(principal), EXPECT_PRINCIPAL, "principal");
    }

    function test_ExpiredDeadlineReverts() public {
        vm.warp(1_000_000);
        vm.prank(bob);
        vm.expectRevert(LodestarLoanBook.Expired.selector);
        book.open(address(fxrp), COLL, 0, 0, block.timestamp - 1);
    }

    /// @dev Exactly at the deadline must still work: `>` not `>=`, so a borrow included in the very
    ///      block the user nominated is honoured rather than rejected.
    function test_DeadlineExactlyNowIsAccepted() public {
        vm.warp(1_000_000);
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0, 0, block.timestamp);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertTrue(active, "a borrow at exactly the deadline must be honoured");
    }

    function test_ZeroDeadlineMeansNoDeadline() public {
        vm.warp(10_000_000_000); // far future
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0, 0, 0);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertTrue(active, "0 must disable the deadline check");
    }

    // ---------------------------------------------------------------- slippage

    function test_MinOutMetIsAccepted() public {
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0, EXPECT_RECEIVED, 0);
        assertEq(usdt0.balanceOf(bob), EXPECT_RECEIVED, "borrower receives principal net of fee");
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        assertEq(uint256(principal), EXPECT_PRINCIPAL, "and owes the gross principal");
    }

    function test_MinOutOneWeiAboveReceivedReverts() public {
        vm.prank(bob);
        vm.expectRevert(LodestarLoanBook.Slippage.selector);
        book.open(address(fxrp), COLL, 0, EXPECT_RECEIVED + 1, 0);
    }

    /// @dev THE case this exists for: the price drops between quote and execution.
    function test_PriceDropBetweenQuoteAndExecutionIsRefused() public {
        // quoted at $2.50
        uint256 quoted = EXPECT_RECEIVED;
        // executed at $2.00 -> principal $1,000, received $980
        ftso.set(XRP_USD, 200_000_000, 8);
        vm.prank(bob);
        vm.expectRevert(LodestarLoanBook.Slippage.selector);
        book.open(address(fxrp), COLL, 0, quoted, 0);

        // and with the guard disabled the same borrow silently goes through at the worse size,
        // which is exactly the exposure being closed
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0);
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        assertEq(uint256(principal), 1_000e6, "unguarded borrow accepts the moved price");
    }

    /// @dev minOut is on the RECEIVED amount, not the principal. Asserting the distinction, because
    ///      binding it to principal would silently under-protect by the fee.
    function test_MinOutIsMeasuredOnReceivedNotPrincipal() public {
        // sits between received (1,225) and principal (1,250): must revert if measured correctly
        vm.prank(bob);
        vm.expectRevert(LodestarLoanBook.Slippage.selector);
        book.open(address(fxrp), COLL, 0, 1_240e6, 0);
    }

    function test_ZeroMinOutMeansNoBound() public {
        ftso.set(XRP_USD, 100_000_000, 8); // halve the price
        vm.prank(bob);
        uint256 id = book.open(address(fxrp), COLL, 0, 0, 0);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertTrue(active, "0 must disable the slippage check");
    }

    // ---------------------------------------------------------------- back-compat

    /// @dev The 3-argument form must behave exactly as the 5-argument form with both guards off.
    function test_ThreeArgFormIsIdenticalToUnconstrainedFiveArg() public {
        vm.prank(bob);
        uint256 a = book.open(address(fxrp), COLL, 0);
        vm.prank(bob);
        uint256 b = book.open(address(fxrp), COLL, 0, 0, 0);
        (address ba,, uint256 ca, uint128 pa, uint128 fa,,,,,,) = book.loans(a);
        (address bb,, uint256 cb, uint128 pb, uint128 fb,,,,,,) = book.loans(b);
        assertEq(ba, bb, "borrower");
        assertEq(ca, cb, "collateral");
        assertEq(pa, pb, "principal");
        assertEq(fa, fb, "fee");
    }

    /// @dev Both entrypoints are nonReentrant and share one internal body. If one delegated to the
    ///      other the guard would re-enter and every call would revert; this proves it does not.
    function test_BothEntrypointsWorkBackToBack() public {
        vm.prank(bob);
        book.open(address(fxrp), COLL, 0);
        vm.prank(bob);
        book.open(address(fxrp), COLL, 0, 1e6, block.timestamp + 60);
        assertEq(book.activeLoanCount(), 2, "both forms must be callable");
    }
}
