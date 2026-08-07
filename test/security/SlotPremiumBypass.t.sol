// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2} from "../Lodestar.t.sol";

/// @notice Does the slot premium actually cost an attacker capital, or is it refundable?
///
/// The premium raises the minimum loan as the book fills, on the theory that occupying every slot
/// then costs the integral under that ramp. `partialRepay` deliberately keeps the FLAT `minPrincipal`
/// floor, which was justified as borrower safety: paying a loan down consumes no slot and must never
/// be blocked because strangers filled the book.
///
/// This tests whether that exemption is also an exit. `partialRepay` can release collateral
/// (`collateralOut`) whenever the remainder is healthy at the loan's opening LTV, and it does NOT
/// free the slot. So an attacker can open at the ramped floor, immediately pay back down to the flat
/// floor while withdrawing the collateral, keep the slot, and recycle the same capital into the next
/// one. If that works, the premium is a fee multiplier, not a capital wall, and the commit that
/// introduced it overstates its effect.
contract SlotPremiumBypassTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address attacker = address(0xBAD);

    bytes21 constant XRP_USD = bytes21("XRP/USD");
    uint256 constant CAP = 50;

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
        book.addTier(address(fxrp), 5000, 7 days, 200); // 50% LTV, 7d, 2%
        book.setMinPrincipal(uint128(100e6)); // $100
        book.setMaxActiveLoans(uint32(CAP));

        usdt0.mint(lender, 5_000_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e6, lender);
        vm.stopPrank();
    }

    /// @dev collateral for a target principal at $2.50 and 50% LTV, plus rounding headroom
    function _collFor(uint256 principal) internal pure returns (uint256) {
        return (principal * 8) / 10 + 1e6;
    }

    /// @notice REGRESSION. The bypass that made the premium refundable must stay closed.
    ///
    /// Before the fix: open at the ramped floor, immediately partialRepay down to the FLAT floor
    /// while withdrawing the collateral, keep the slot, recycle the capital into the next one. That
    /// filled 50 slots for 4,050 FXRP locked -- identical to the pre-premium flat attack -- while a
    /// naive filler paid 3.87x. The premium was a fee multiplier, not a capital wall.
    ///
    /// After the fix, releasing collateral must leave the loan above the RAMPED floor, so the claw
    /// back reverts and the capital stays locked.
    function test_BypassIsClosed_CannotStripCollateralBackToFlatFloor() public {
        // get the book meaningfully full so the ramp is clearly above the flat floor
        for (uint256 i; i < 20; i++) {
            address b = address(uint160(0xF00000 + i));
            uint256 c = _collFor(book.effectiveMinPrincipal());
            fxrp.mint(b, c);
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), c, 0);
            vm.stopPrank();
        }
        uint256 ramped = book.effectiveMinPrincipal();
        assertGt(ramped, 100e6, "ramp not engaged");

        uint256 coll = _collFor(ramped * 3); // big enough to pay down and still clear the ramped floor
        fxrp.mint(attacker, coll);
        vm.startPrank(attacker);
        fxrp.approve(address(book), type(uint256).max);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
        (,,, uint128 principal,,,,,,,) = book.loans(id);

        // the exact move that used to work: shrink to the flat floor AND pull the collateral out.
        // Single-shot prank per call: vm.expectRevert inside an active startPrank confuses the
        // cheatcode depth check and reports "didn't revert at a lower depth".
        uint256 keep = _collFor(100e6);
        vm.prank(attacker);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.partialRepay(id, uint256(principal) - 100e6, coll - keep, 0, 0);

        // The fix must not be over-broad: a release that leaves the loan ABOVE the ramped floor is
        // legitimate de-risking and must still succeed.
        uint256 stayAbove = book.effectiveMinPrincipal() + 10e6;
        assertLt(stayAbove, uint256(principal), "loan must be big enough to pay down and stay above");
        vm.prank(attacker);
        book.partialRepay(id, uint256(principal) - stayAbove, 1e6, 0, 0);
        (,,, uint128 after_,,,,,,,) = book.loans(id);
        assertEq(uint256(after_), stayAbove, "legitimate collateral release must still work");

        assertEq(book.activeLoanCount(), 21, "slot count unchanged");
    }

    /// @notice The property the flat floor exists to protect must SURVIVE the fix: a borrower paying
    ///         DOWN without taking collateral is never blocked, however full the book is.
    function test_PurePaydownStillWorksOnAFullBook() public {
        uint256 coll = _collFor(2_000e6);
        fxrp.mint(attacker, coll);
        vm.startPrank(attacker);
        fxrp.approve(address(book), type(uint256).max);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();

        // fill every remaining slot so the ramp is at maximum
        for (uint256 i; book.activeLoanCount() < CAP && i < 500; i++) {
            address b = address(uint160(0xE00000 + i));
            uint256 c = _collFor(book.effectiveMinPrincipal());
            fxrp.mint(b, c);
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), c, 0);
            vm.stopPrank();
        }
        assertEq(book.activeLoanCount(), CAP, "book not full");
        assertGt(book.effectiveMinPrincipal(), 100e6, "ramp not at maximum");

        (,,, uint128 principal,,,,,,,) = book.loans(id);
        // Fund the repayment explicitly: the borrow paid out principal MINUS the origination fee, so
        // relying on the proceeds alone leaves the borrower a few percent short.
        usdt0.mint(attacker, uint256(principal));
        // pay down to just above the FLAT floor, taking NO collateral. Must succeed.
        uint256 target = 150e6;
        assertLt(target, book.effectiveMinPrincipal(), "target must be under the ramped floor");
        vm.prank(attacker);
        book.partialRepay(id, uint256(principal) - target, 0, 0, 0);

        (,,, uint128 after_,,,,,,,) = book.loans(id);
        assertEq(uint256(after_), target, "pure paydown must not be blocked by a full book");

        // and a full repay is likewise unaffected
        vm.prank(attacker);
        book.repay(id);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "full repay must work on a full book");
    }

    /// @dev Control: the naive attacker who leaves loans at the ramped size really does pay ~3.9x.
    ///      Confirms the commit's measurement was right about the naive case, and that the gap is
    ///      entirely due to the partialRepay exit.
    function test_NaiveFillerDoesPayTheRamp() public {
        for (uint256 i; i < CAP; i++) {
            address b = address(uint160(0xF00000 + i));
            uint256 coll = _collFor(book.effectiveMinPrincipal());
            fxrp.mint(b, coll);
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), coll, 0);
            vm.stopPrank();
        }
        uint256 locked = fxrp.balanceOf(address(book));
        uint256 flatCost = CAP * _collFor(100e6);
        console2.log("naive filler locked", locked);
        console2.log("naive / flat x100", (locked * 100) / flatCost);
        assertGt(locked * 100 / flatCost, 300, "naive filler should pay >3x");
    }
}
