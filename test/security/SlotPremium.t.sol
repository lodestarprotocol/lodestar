// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2} from "../Lodestar.t.sol";

/// @notice The slot-exhaustion premium: properties an auditor should be able to check by name.
///
/// Why it exists: a griefer can occupy every active slot with minimum-size loans and block all new
/// borrowing. Unlike exposure-cap exhaustion, which the owner undoes in one transaction by raising
/// the cap, slot exhaustion CANNOT be undone: maxActiveLoans is hard-bounded to 400 in the contract
/// and the squatted loans persist until maturity, up to 30 days on the long tier.
///
/// The premium raises the minimum loan quadratically with book fullness, so buying the whole book
/// costs the integral under that ramp rather than a flat minPrincipal per slot.
///
/// The invariants that keep it from doing harm are the point of this file:
///   - an empty book charges exactly minPrincipal (no tax on the first borrower)
///   - the ramp is negligible while the book is not scarce
///   - setting the premium to 0 restores the previous behaviour byte for byte
///   - it gates open() ONLY: paying a loan down, repaying, and adding collateral must never be
///     blocked because someone else filled the book
contract SlotPremiumTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address alice = address(0xA11CE);

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
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.setMinPrincipal(uint128(100e6)); // $100, the mainnet launch floor

        usdt0.mint(lender, 5_000_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e6, lender);
        vm.stopPrank();
    }

    function _open(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), type(uint256).max);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    /// @dev collateral needed for a given principal at $2.50 and 50% LTV, plus rounding headroom
    function _collFor(uint256 principal) internal pure returns (uint256) {
        return (principal * 8) / 10 + 1e6;
    }

    function _fillTo(uint256 n) internal {
        for (uint256 i; book.activeLoanCount() < n && i < 2000; i++) {
            _open(address(uint160(0x700000 + i)), _collFor(book.effectiveMinPrincipal()));
        }
    }

    // --------------------------------------------------------------- core shape

    function test_EmptyBookChargesExactlyMinPrincipal() public view {
        assertEq(book.activeLoanCount(), 0, "book not empty");
        assertEq(book.effectiveMinPrincipal(), book.minPrincipal(), "first borrower must not be taxed");
    }

    function test_FullBookChargesMinPrincipalTimesPremium() public {
        book.setMaxActiveLoans(50);
        _fillTo(50);
        uint256 expected = uint256(book.minPrincipal())
            + (uint256(book.minPrincipal()) * book.slotPremiumBps()) / 10_000;
        assertEq(book.effectiveMinPrincipal(), expected, "full book must charge the full premium");
    }

    function test_RampIsMonotonicAndNegligibleWhileNotScarce() public {
        book.setMaxActiveLoans(100);
        uint256 prev = book.effectiveMinPrincipal();
        assertEq(prev, 100e6, "starts at the floor");
        for (uint256 target = 10; target <= 50; target += 10) {
            _fillTo(target);
            uint256 now_ = book.effectiveMinPrincipal();
            assertGe(now_, prev, "ramp must never decrease");
            prev = now_;
        }
        // At half full the quadratic term is 1/4 of the premium: $100 -> $325 at 9x.
        assertLe(book.effectiveMinPrincipal(), 400e6, "ramp too aggressive at half full");
    }

    function test_QuarterFullBarelyMoves() public {
        book.setMaxActiveLoans(400);
        _fillTo(50); // 12.5% full
        // Linear would have demanded ~$212 here. Quadratic must stay close to the floor.
        assertLt(book.effectiveMinPrincipal(), 120e6, "small borrowers priced out too early");
    }

    // --------------------------------------------------------------- disable / bounds

    function test_ZeroPremiumRestoresExactOldBehaviour() public {
        book.setSlotPremiumBps(0);
        book.setMaxActiveLoans(50);
        _fillTo(49);
        assertEq(book.effectiveMinPrincipal(), book.minPrincipal(), "premium disabled must be flat");
        // and a flat-floor loan still opens at 49/50, exactly as before the change
        _open(alice, _collFor(100e6));
        assertEq(book.activeLoanCount(), 50, "flat floor open should succeed when disabled");
    }

    function test_SetSlotPremiumBounds() public {
        book.setSlotPremiumBps(0);
        book.setSlotPremiumBps(200_000);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setSlotPremiumBps(200_001);
    }

    function test_SetSlotPremiumIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        book.setSlotPremiumBps(1000);
    }

    /// @dev maxActiveLoans can be lowered below the current book size; the clamp must hold and the
    ///      view must not revert or overflow.
    function test_CapLoweredBelowBookDoesNotBreakTheView() public {
        book.setMaxActiveLoans(60);
        _fillTo(60);
        book.setMaxActiveLoans(50); // now used (60) > cap (50)
        uint256 v = book.effectiveMinPrincipal();
        uint256 max = uint256(book.minPrincipal())
            + (uint256(book.minPrincipal()) * book.slotPremiumBps()) / 10_000;
        assertEq(v, max, "clamped to the full premium, never beyond");
    }

    /// @dev An earlier version of this test set the extreme parameters but read an EMPTY book, where
    ///      used == 0 zeroes the whole premium term. It therefore exercised none of the arithmetic it
    ///      claimed to. Fill the book FIRST at a cheap floor, then raise both ceilings and read the
    ///      view, so the intermediate `minPrincipal * slotPremiumBps * used * used` is at its maximum
    ///      without needing a multi-million-dollar pool to fill 400 slots at a $10k floor.
    function test_NoOverflowAtExtremeParameters() public {
        book.setMaxActiveLoans(400);
        book.setMinPrincipal(uint128(100e6));
        _fillTo(400); // cheap fill at the low floor
        assertEq(book.activeLoanCount(), 400, "book not full");

        book.setMinPrincipal(uint128(10_000e6)); // setter ceiling
        book.setSlotPremiumBps(200_000); // setter ceiling
        // used == cap == 400 now, so the numerator is minPrincipal * 200_000 * 400 * 400 = 3.2e20
        uint256 v = book.effectiveMinPrincipal();
        uint256 expected = uint256(10_000e6) + (uint256(10_000e6) * 200_000) / 10_000; // 21x
        assertEq(v, expected, "full book at both ceilings must equal minPrincipal * 21");
        assertEq(v, 210_000e6, "sanity: $10k floor -> $210k at a completely full book");
    }

    /// @dev The overflow bound depends on stableUnit, which is read from the pool asset at
    ///      construction. USD₮0 is 6dp so minPrincipal tops out at 1e10, but an 18dp stable would
    ///      allow 1e22 and the intermediate becomes 1e22 * 2e5 * 1.6e5 = 3.2e32. Still far below
    ///      uint256 (~1.16e77), but the audit note should state the general bound, not the 6dp one.
    function test_OverflowHeadroomIsStatedCorrectly() public pure {
        uint256 minPrincipal18dp = 10_000 * 1e18; // the setter ceiling on an 18-decimal stable
        uint256 worst = minPrincipal18dp * 200_000 * 400 * 400;
        assertEq(worst, 3.2e32, "worst-case numerator");
        assertLt(worst, type(uint256).max / 1e40, "orders of magnitude of headroom remain");
    }

    // --------------------------------------------------------------- must NOT gate exits

    /// @dev THE regression this design had to avoid: a borrower paying their loan DOWN does not
    ///      consume a slot, so a full book must never block it. partialRepay keeps the flat floor.
    function test_PartialRepayUsesFlatFloor_EvenWhenBookIsFull() public {
        book.setMaxActiveLoans(50); // 50 is the contract's lower bound
        // open one healthy loan we will pay down later
        uint256 id = _open(alice, _collFor(500e6));
        _fillTo(50); // book now completely full, ramp at maximum
        assertEq(book.activeLoanCount(), 50, "book not full");
        assertGt(book.effectiveMinPrincipal(), 100e6, "ramp not engaged");

        (,,, uint128 principal,,,,,,,) = book.loans(id);
        // Pay down to just above the FLAT floor. If partialRepay had used the ramped floor this
        // would revert, trapping the borrower because strangers filled the book.
        uint256 target = 150e6; // > minPrincipal ($100), < effectiveMinPrincipal
        assertLt(target, book.effectiveMinPrincipal(), "test needs target under the ramped floor");
        uint256 repayAmt = uint256(principal) - target;

        usdt0.mint(alice, repayAmt);
        vm.startPrank(alice);
        usdt0.approve(address(pool), type(uint256).max);
        book.partialRepay(id, repayAmt, 0, 0, 0);
        vm.stopPrank();

        (,,, uint128 after_,,,,,,,) = book.loans(id);
        assertEq(uint256(after_), target, "partial repay must succeed against the flat floor");
    }

    /// @dev Full repay and addCollateral must likewise be unaffected by a full book.
    function test_RepayAndAddCollateralUnaffectedByFullBook() public {
        book.setMaxActiveLoans(50); // 50 is the contract's lower bound
        uint256 id = _open(alice, _collFor(500e6));
        _fillTo(50);

        fxrp.mint(alice, 10e6);
        vm.startPrank(alice);
        fxrp.approve(address(book), type(uint256).max);
        book.addCollateral(id, 10e6); // must not revert on a full book
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        usdt0.mint(alice, principal);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "repay must work regardless of book fullness");
    }
}
