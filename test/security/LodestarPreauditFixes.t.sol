// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILstRateProvider} from "../../src/interfaces/ILstRateProvider.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {LodestarTest} from "../Lodestar.t.sol";

/// @dev Rate provider that works until toggled down, then reverts — models a paused/upgrading LST
///      protocol (Sceptre/Firelight) whose `underlyingPerShare` becomes temporarily unavailable.
contract ToggleRate is ILstRateProvider {
    uint256 public rate = 1e18;
    bool public down;

    function set(uint256 r) external {
        rate = r;
    }

    function setDown(bool d) external {
        down = d;
    }

    function underlyingPerShare() external view returns (uint256) {
        require(!down, "rate down");
        return rate;
    }
}

/// @notice Regression tests for the 2026-07-20 pre-audit fixes surfaced by the Pashov
///         solidity-auditor skill run and verified against source. Reuses the LodestarTest
///         fixture (fixtures, helpers, and actors are inherited).
contract LodestarPreauditFixesTest is LodestarTest {
    // -------------------------------------------------------- Fix 1: rollover borrower-auth
    function test_Rollover_OnlyBorrowerCanRoll() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        address stranger = address(0x57A6E);
        usdt0.mint(stranger, 1_000e6); // fund it so the fee-pull isn't what reverts
        vm.startPrank(stranger);
        usdt0.approve(address(pool), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.NotBorrower.selector);
        book.rollover(id, 0);
        vm.stopPrank();
    }

    function test_Rollover_BorrowerStillWorks() public {
        // The borrower rolling their own loan (even into the same tier right after open) must still
        // work — the auth check is the only new gate, no anti-shorten overreach.
        uint256 id = _openFxrp(borrower, 1000e6);
        usdt0.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.rollover(id, 0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6 + 5e6, "open + rollover reserve cuts buffered");
    }

    // -------------------------------------------------------- Fix 2: withdrawReserve strict sync
    function test_WithdrawReserve_RefusesDuringOutage() public {
        _openFxrp(borrower, 1000e6); // funds the buffer AND leaves an active loan to price
        assertGt(book.reserveBalance(), 0, "buffer funded at open");

        ftso.set(XRP_USD, 0, 8); // FTSO down -> a loan can't be freshly priced
        vm.expectRevert(LodestarLoanBook.OracleDown.selector);
        book.withdrawReserve(1e6);

        ftso.set(XRP_USD, 250_000_000, 8); // recover
        book.withdrawReserve(1e6);
        assertEq(usdt0.balanceOf(reserve), 1e6, "withdrawal proceeds once the book can be priced");
    }

    // -------------------------------------------------------- Fix 4: penaltyBps frozen at open
    function test_PenaltyBps_FrozenAtOpen() public {
        uint256 id = _openFxrp(borrower, 1000e6); // penaltyBps 500 (5%), principal 1250
        uint256 reserveAtOpen = book.reserveBalance();

        // owner jacks the default penalty up on the ALREADY-open loan
        book.setRiskParams(48 hours, 500, 2000, 2000); // penalty 5% -> 20%

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        _buyoutFull(id); // buyer pays full oracle value, surplus exists

        // penalty booked into the reserve = FROZEN 5% of principal (62.5e6), NOT the raised 20% (250e6)
        assertEq(book.reserveBalance() - reserveAtOpen, 625e5, "frozen 5% penalty applied, not 20%");
    }

    // -------------------------------------------------------- Fix 4: keeperBps frozen at open
    function test_KeeperBps_FrozenAtOpen() public {
        uint256 id = _openFxrp(borrower, 1000e6); // keeperBps 500 (5%)
        router.setRate(25, 10); // router pays $2.50/FXRP (matches FTSO)

        book.setRiskParams(48 hours, 1000, 500, 2000); // keeper 5% -> 10%

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        // bounty is the FROZEN 5% of 1000 FXRP = 50e6, not the raised 10% (100e6)
        assertEq(fxrp.balanceOf(keeper), 50e6, "frozen keeper bounty, not the raised one");
    }

    // -------------------------------------------------------- Fix 5: buyoutCost gated on default
    function test_BuyoutCost_RevertsBeforeDefault() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.buyoutCost(id);

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        assertGt(book.buyoutCost(id), 0, "quote available once the loan is buyable");
    }

    // -------------------------------------------------------- Fix 5: ERC4626 max* exit-aware
    function test_MaxWithdrawAndRedeem_ZeroDuringOutage() public {
        _openFxrp(borrower, 1000e6); // active loan
        assertGt(pool.maxWithdraw(lender), 0, "sized normally when priceable");
        assertGt(pool.maxRedeem(lender), 0, "sized normally when priceable");

        ftso.set(XRP_USD, 0, 8); // outage: the real withdraw/redeem would revert OracleDown
        assertEq(pool.maxWithdraw(lender), 0, "max* reports 0, never an amount that would revert");
        assertEq(pool.maxRedeem(lender), 0, "max* reports 0, never an amount that would revert");

        ftso.set(XRP_USD, 250_000_000, 8);
        assertGt(pool.maxWithdraw(lender), 0, "restored after recovery");
    }

    // -------------------------------------------------------- Fix 5: rate-provider outage != trapped
    function test_RateProviderRevert_RepayStillReturnsCollateral() public {
        // Point sFLR at a togglable rate provider and enable a non-zero skim so the repay path reads it.
        ToggleRate tr = new ToggleRate();
        oracle.setFeed(address(sflr), FLR_USD, address(tr), 1 hours, 0);
        book.setYieldSkimBps(1000); // 10% skim -> loanTerms.skimBps snapshotted at open

        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0); // sFLR tier: 55%/30d
        vm.stopPrank();

        tr.setDown(true); // provider goes down AFTER open (paused / mid-upgrade)

        uint256 principal = _principal(id);
        usdt0.mint(borrower, principal);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id); // must NOT revert: skim is skipped, collateral returned whole
        vm.stopPrank();

        assertEq(sflr.balanceOf(borrower), 100_000e18, "collateral fully returned despite a dead rate provider");
    }

    // -------------------------------------------------------- helper
    function _buyoutFull(uint256 id) internal {
        uint256 cost = book.buyoutCost(id);
        usdt0.mint(buyer, cost);
        vm.startPrank(buyer);
        usdt0.approve(address(book), type(uint256).max);
        book.buyout(id, cost);
        vm.stopPrank();
    }
}
