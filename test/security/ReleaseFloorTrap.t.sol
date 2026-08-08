// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2} from "../Lodestar.t.sol";

/// @notice Does gating collateral release on the LIVE ramped floor trap honest borrowers, and does
///         it actually keep the squatter's capital locked?
///
/// The anti-bypass gate reads `effectiveMinPrincipal()` at release time. That is a function of how
/// full the book is RIGHT NOW, which has two consequences the fix did not intend:
///
///   - an honest borrower who opened on an empty book is quoted a $100 floor, and once strangers
///     fill the book the release floor rises above their entire principal, so no release of any size
///     is possible at all;
///   - the squatter it was written to stop only has to wait. When the book empties the floor falls
///     and they strip the premium back out while still holding the slot.
///
/// Both were proven here BEFORE the fix. Release is now gated on the floor the loan was
/// underwritten at (`openFloor[id]`), frozen per loan like `openLtvBps`, so neither can recur:
/// Alice opened at $100 and can always shrink to $100; the squatter opened at $964 and can never
/// shrink below $964, however the book moves. These tests now assert the fixed behaviour.
contract ReleaseFloorTrapTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address alice = address(0xA11CE);
    address squatter = address(0x5CA7);

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
        book = new LodestarLoanBook(pool, oracle, address(0xEE5E), owner);
        pool.setLoanBook(address(book));
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.setMinPrincipal(uint128(100e6));
        book.setMaxActiveLoans(uint32(CAP));

        usdt0.mint(address(0x1E7D), 5_000_000e6);
        vm.startPrank(address(0x1E7D));
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e6, address(0x1E7D));
        vm.stopPrank();
    }

    function _collFor(uint256 principal) internal pure returns (uint256) {
        return (principal * 8) / 10 + 1e6;
    }

    function _open(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), type(uint256).max);
        usdt0.approve(address(pool), type(uint256).max);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    function _fillTo(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 k;
        for (uint256 i; book.activeLoanCount() < n && i < 2000; i++) {
            ids[k++] = _open(address(uint160(0x900000 + i)), _collFor(book.effectiveMinPrincipal()));
        }
    }

    /// @notice REGRESSION: an honest borrower must keep collateral release however full the book
    ///          gets. Before the snapshot fix, the live floor rose above her entire principal and
    ///          EVERY release reverted, down to partialRepay(id, 1, 1, 0, 0).
    function test_HonestBorrowerLosesCollateralReleaseEntirely() public {
        uint256 id = _open(alice, _collFor(500e6)); // ~2x collateralized, principal ~$501
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        uint256 quoted = book.effectiveMinPrincipal();
        assertLt(quoted, 101e6, "quoted floor on a near-empty book is ~the flat minimum");

        _fillTo(CAP);
        uint256 floorNow = book.effectiveMinPrincipal();
        console2.log("alice principal", uint256(principal));
        console2.log("release floor after strangers filled the book", floorNow);
        assertGt(floorNow, uint256(principal), "the floor now exceeds her entire principal");

        usdt0.mint(alice, uint256(principal));
        // Her snapshot is the ~$100 she was quoted, so releasing down to it must still work even
        // though the LIVE floor is now $1,000 and exceeds her whole principal.
        assertLt(book.openFloor(id), 101e6, "snapshot is the floor she was quoted");
        uint256 target = uint256(book.openFloor(id)) + 1e6;
        uint256 before = fxrp.balanceOf(alice);
        vm.prank(alice);
        book.partialRepay(id, uint256(principal) - target, 100e6, 0, 0);
        assertGt(fxrp.balanceOf(alice), before, "honest borrower can still release collateral");

        // and full repay is of course unaffected
        (,,, uint128 rest,,,,,,,) = book.loans(id);
        usdt0.mint(alice, uint256(rest));
        vm.prank(alice);
        book.repay(id);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "full repay must still work");
    }

    /// @notice REGRESSION: the premium must be LOCKED capital, not a peak-instant toll. Before the
    ///          snapshot fix, 30 honest borrowers repaying on time dropped the floor from $964 to
    ///          $244 and let the squatter withdraw 87% while keeping the slot.
    function test_SquatterClawsThePremiumBackWhenTheBookEmpties() public {
        uint256[] memory honest = _fillTo(CAP - 1);
        uint256 peak = book.effectiveMinPrincipal();
        uint256 coll = _collFor(peak * 2);
        uint256 id = _open(squatter, coll); // takes the last slot at the peak ramp
        assertEq(book.activeLoanCount(), CAP, "book full");
        uint256 heldAtPeak = coll;

        // Honest borrowers simply repay on time. No adversarial or admin action whatsoever.
        for (uint256 i; i < 30; i++) {
            if (honest[i] == 0) continue;
            (,,, uint128 p,,,,,,,) = book.loans(honest[i]);
            address b = address(uint160(0x900000 + i));
            usdt0.mint(b, uint256(p));
            vm.prank(b);
            book.repay(honest[i]);
        }
        uint256 floorAfter = book.effectiveMinPrincipal();
        console2.log("floor at peak", peak);
        console2.log("floor after 30 honest repayments", floorAfter);
        assertLt(floorAfter, peak, "floor fell as the book emptied");

        (,,, uint128 sp,,,,,,,) = book.loans(id);
        uint256 target = floorAfter + 1e6;
        usdt0.mint(squatter, uint256(sp));
        // The snapshot is the peak floor they opened at, so the claw-back is refused even though the
        // live floor has fallen to a quarter of it.
        assertGe(uint256(book.openFloor(id)), peak, "snapshot froze the peak floor");
        vm.prank(squatter);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.partialRepay(id, uint256(sp) - target, coll - _collFor(target), 0, 0);

        console2.log("collateral posted at peak", heldAtPeak);
        console2.log("snapshot floor (frozen)", uint256(book.openFloor(id)));
        (,,,,,,,, bool stillActive,,) = book.loans(id);
        assertTrue(stillActive, "slot still held, but the capital stays with it");
    }
}
