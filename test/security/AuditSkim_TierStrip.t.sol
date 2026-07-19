// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2} from "../Lodestar.t.sol";

/// @notice Regression for the partial-release tier-strip fix. A loan's deadline is unchanged by a
///         partial repay, so a collateral release must be re-checked against the loan's OWN opening
///         LTV — never a caller-chosen, laxer tier. A borrower may pass a stricter tier to de-risk
///         further, but can never strip the position above the LTV it was underwritten at.
contract AuditSkimTierStrip is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    bytes21 constant XRP = bytes21("XRP/USD");

    address owner = address(this);
    address reserve = makeAddr("reserve");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50

        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);

        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));

        // TWO tiers on the SAME collateral: conservative (tier 0, 50%) and aggressive (tier 1, 70%).
        book.addTier(address(fxrp), 5000, 7 days, 200); // tier 0: 50% LTV
        book.addTier(address(fxrp), 7000, 7 days, 200); // tier 1: 70% LTV

        usdt0.mint(owner, 200_000e6);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(200_000e6, owner);
    }

    function _principal(uint256 id) internal view returns (uint256 p) {
        (,,, p,,,,,,,) = book.loans(id);
    }

    function _collAmount(uint256 id) internal view returns (uint256 c) {
        (,, c,,,,,,,,) = book.loans(id);
    }

    function test_PartialRepayCannotReleaseAgainstLaxerTier() public {
        // Open at the CONSERVATIVE tier 0 (50% LTV).
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 0); // $2500 coll, principal 1250e6 @ 50%
        vm.stopPrank();
        assertEq(_principal(id), 1_250e6);
        assertEq(book.openLtvBps(id), 5000, "opening LTV recorded");

        usdt0.mint(borrower, 250e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);

        // Releasing 300 XRP validated against tier 0 (50%) must revert (remainder 700 XRP = $1750,
        // *0.50 = $875 < principal 1000).
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.partialRepay(id, 250e6, 300e6, 0, 0);

        // The FIX: pointing at the laxer tier 1 (70%) no longer helps — the check is bounded to the
        // loan's OPENING LTV (50%), so this now reverts too instead of stripping to a 57% position.
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.partialRepay(id, 250e6, 300e6, 1, 0);
        vm.stopPrank();

        // Loan untouched by the reverted attempts.
        assertEq(_principal(id), 1_250e6);
        assertEq(_collAmount(id), 1_000e6, "no collateral stripped");
    }

    function test_PartialRepayStillAllowsHealthyReleaseAtOpeningLtv() public {
        // Same open at tier 0 (50%).
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 0); // principal 1250e6
        vm.stopPrank();

        // Pay down to 1000e6 and release 100 XRP: remainder 900 XRP = $2250, *0.50 = $1125 >= 1000.
        // A legitimate release that respects the opening LTV still succeeds.
        usdt0.mint(borrower, 250e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.partialRepay(id, 250e6, 100e6, 0, 0);
        vm.stopPrank();

        assertEq(_principal(id), 1_000e6);
        assertEq(_collAmount(id), 900e6, "healthy release at opening LTV allowed");
    }

    function test_PartialRepayCallerCanChooseStricterTier() public {
        // Open at the AGGRESSIVE tier 1 (70%): principal 1750e6 against $2500 collateral.
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 1); // 70% LTV
        vm.stopPrank();
        assertEq(_principal(id), 1_750e6);
        assertEq(book.openLtvBps(id), 7000);

        // Pay down to 1000e6. Passing the STRICTER tier 0 (50%) tightens the release check below the
        // opening 70%: remainder must be worth >= 1000/0.50 = $2000 => >= 800 XRP, so releasing 150
        // (remainder 850 XRP = $2125) passes at 50% and obviously at 70%. Stricter tier is honored.
        usdt0.mint(borrower, 750e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        // Releasing 250 (remainder 750 XRP = $1875) fails the stricter 50% check ($937.5 < 1000)...
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.partialRepay(id, 750e6, 250e6, 0, 0);
        // ...but a smaller release that satisfies the stricter tier succeeds.
        book.partialRepay(id, 750e6, 150e6, 0, 0);
        vm.stopPrank();
        assertEq(_collAmount(id), 850e6);
    }
}
