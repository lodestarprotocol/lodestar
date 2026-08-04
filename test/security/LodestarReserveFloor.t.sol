// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {LodestarTest} from "../Lodestar.t.sol";

/// @dev Whitelisted router that tries to fund the reserve from inside the settlement swap.
///      `_swapViaRouter` measures proceeds as a stable balance delta, so if this succeeded the same
///      stable would be counted twice, once as buffer and once as proceeds, and
///      `stable.balanceOf(book) == reserveBalance` would break. fundReserve is nonReentrant
///      precisely to make this impossible.
contract ReentrantFunder {
    address public immutable book;
    address public immutable stable;
    address public immutable collateral;
    bool public attempted;
    bool public succeeded;

    constructor(address _book, address _stable, address _collateral) {
        book = _book;
        stable = _stable;
        collateral = _collateral;
    }

    function swapAndFund(uint256 toSell, uint256 payOut, uint256 fundAmt) external {
        IERC20(collateral).transferFrom(book, address(this), toSell); // complete the approved sale
        IERC20(stable).transfer(book, payOut); // pay the proceeds
        attempted = true;
        IERC20(stable).approve(book, fundAmt);
        // must revert on the reentrancy guard; swallow so the settlement itself still completes
        try LodestarLoanBook(book).fundReserve(fundAmt) {
            succeeded = true;
        } catch {}
    }
}

/// @notice Tests for `fundReserve` / `reserveFloor` (2026-08-04).
///
/// The gap being closed: before this, every dollar of the first-loss buffer was owner-withdrawable
/// down to the marked loss, and there was no way at all to add to it from outside (a plain transfer
/// is not credited and is swept away by `sweepStableDonations`). So nobody, including the protocol
/// itself, could credibly subordinate capital ahead of lenders.
///
/// The properties that must hold:
///   1. anyone can contribute, and the contribution lands in the buffer
///   2. the owner can never withdraw a contribution back out
///   3. the owner CAN still withdraw genuine fee surplus, so this is not a lockout
///   4. losses consume contributed capital first, which is the entire point of contributing it
///   5. once losses have consumed it, fee income that rebuilds the buffer is free again
///   6. `reserveFloor <= reserveBalance` always, and custody stays exact throughout
contract LodestarReserveFloorTest is LodestarTest {
    address contributor = address(0xC0F1);

    function _fund(address who, uint256 amt) internal {
        usdt0.mint(who, amt);
        vm.startPrank(who);
        usdt0.approve(address(book), amt);
        book.fundReserve(amt);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 1. contributing works
    function test_FundReserve_RaisesBufferAndFloor_AndIsPermissionless() public {
        uint256 bufBefore = book.reserveBalance();
        assertEq(book.reserveFloor(), 0, "floor starts empty");

        _fund(contributor, 500e6); // a plain address, not the owner

        assertEq(book.reserveBalance(), bufBefore + 500e6, "buffer took the contribution");
        assertEq(book.reserveFloor(), 500e6, "floor tracks the contribution");
        assertEq(usdt0.balanceOf(address(book)), book.reserveBalance(), "custody exact after funding");
    }

    function test_FundReserve_RejectsZero() public {
        vm.prank(contributor);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.fundReserve(0);
    }

    // ---------------------------------------------------------------- 2. owner cannot take it back
    function test_WithdrawReserve_CannotTakeContributedFloor() public {
        _fund(contributor, 500e6);
        uint256 buf = book.reserveBalance();

        // even one wei below the floor must fail, and the whole buffer certainly must
        vm.prank(owner);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.withdrawReserve(buf);

        vm.prank(owner);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.withdrawReserve(buf - 500e6 + 1);

        assertEq(book.reserveBalance(), buf, "buffer untouched by the failed withdrawals");
    }

    // ---------------------------------------------------------------- 3. not a lockout
    function test_WithdrawReserve_StillTakesFeeSurplusAboveFloor() public {
        _openFxrp(borrower, 1000e6); // 5e6 of fee cut into the buffer
        uint256 fees = book.reserveBalance();
        assertGt(fees, 0, "fee surplus exists");

        _fund(contributor, 500e6);
        assertEq(book.reserveBalance(), fees + 500e6);

        // the owner may take exactly the fee surplus, no more
        vm.prank(owner);
        book.withdrawReserve(fees);
        assertEq(book.reserveBalance(), 500e6, "only the contribution remains");
        assertEq(book.reserveFloor(), 500e6, "floor unchanged by a legitimate withdrawal");
        assertEq(usdt0.balanceOf(reserve), fees, "surplus reached the treasury");

        vm.prank(owner);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.withdrawReserve(1); // nothing left above the floor
    }

    // ---------------------------------------------------------------- 4 + 5 + 6. loss absorption
    function test_ContributedFloorAbsorbsLossFirst_ThenFeesAreFreeAgain() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        _fund(contributor, 300e6); // thick enough to be partially, not fully, consumed
        uint256 floorBefore = book.reserveFloor();
        uint256 bufBefore = book.reserveBalance();

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(XRP_USD, 50_000_000, 8); // deep crash: collateral well under principal
        book.impair(id);

        router.setRate(5, 10);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(1000e6), 0);

        // the shortfall ate into the buffer, and the floor followed it down rather than going stale
        assertLt(book.reserveBalance(), bufBefore, "buffer absorbed the shortfall");
        assertLe(book.reserveFloor(), book.reserveBalance(), "floor never exceeds the buffer");
        assertLt(book.reserveFloor(), floorBefore, "contributed capital was consumed, as intended");
        assertEq(usdt0.balanceOf(address(book)), book.reserveBalance(), "custody exact after settlement");

        // fee income earned AFTER the loss is protocol surplus, not contributed capital: withdrawable
        uint256 floorAfter = book.reserveFloor();
        _openFxrp(borrower, 1000e6); // adds a fresh 5e6 fee cut
        uint256 free = book.reserveBalance() - floorAfter - pool.impairedLoss();
        assertGt(free, 0, "new fee income sits above the floor");
        vm.prank(owner);
        book.withdrawReserve(free);
        assertEq(book.reserveFloor(), floorAfter, "withdrawing surplus did not touch the floor");
    }

    function test_FullyConsumedFloorGoesToZero_NotNegative() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        _fund(contributor, 10e6); // small: the shortfall will exceed it entirely
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(XRP_USD, 50_000_000, 8);
        book.impair(id);
        router.setRate(5, 10);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(1000e6), 0);

        assertEq(book.reserveBalance(), 0, "buffer fully spent as first loss");
        assertEq(book.reserveFloor(), 0, "floor clamped to zero, never underflowed or stranded");
        assertEq(usdt0.balanceOf(address(book)), 0, "custody exact");
    }

    // ---------------------------------------------------------------- reentrancy
    function test_FundReserve_BlockedInsideSettlement() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        ReentrantFunder evil = new ReentrantFunder(address(book), address(usdt0), address(fxrp));
        usdt0.mint(address(evil), 10_000e6);
        vm.prank(owner);
        book.setRouterAllowed(address(evil), true);

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 bufBefore = book.reserveBalance();

        bytes memory data = abi.encodeWithSelector(ReentrantFunder.swapAndFund.selector, uint256(950e6), uint256(2400e6), uint256(100e6));
        vm.prank(keeper);
        book.settleSwap(id, address(evil), data, 0);

        assertTrue(evil.attempted(), "the router did try to fund mid-settlement");
        assertFalse(evil.succeeded(), "reentrant fundReserve must be rejected by the guard");
        assertEq(book.reserveFloor(), 0, "no floor was created from inside the swap");
        assertEq(usdt0.balanceOf(address(book)), book.reserveBalance(), "custody exact: no double count");
        bufBefore; // silence unused
    }

    // ---------------------------------------------------------------- fuzz the core property
    function testFuzz_FloorNeverExceedsBufferAndOwnerCannotBreachIt(uint96 contribution, uint96 withdrawWant) public {
        vm.assume(contribution > 0 && contribution < 50_000e6);
        _openFxrp(borrower, 1000e6);
        uint256 fees = book.reserveBalance();
        _fund(contributor, contribution);

        assertLe(book.reserveFloor(), book.reserveBalance(), "floor <= buffer");

        uint256 want = uint256(withdrawWant);
        vm.prank(owner);
        if (want > 0 && want <= fees) {
            book.withdrawReserve(want); // within surplus: allowed
            assertGe(book.reserveBalance(), book.reserveFloor(), "floor still intact");
        } else if (want > fees) {
            vm.expectRevert(LodestarLoanBook.BadParam.selector);
            book.withdrawReserve(want); // would eat the contribution: refused
        }
        assertEq(book.reserveFloor(), uint256(contribution), "contribution never withdrawable");
    }
}
