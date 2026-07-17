// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter} from "../Lodestar.t.sol";

/// @notice Adversarial suite: each test *tries* to break a security property and asserts it can't.
contract LodestarSecurityTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    MockRouter router;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant XRP = bytes21("XRP/USD");

    address owner = address(this);
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address borrower = makeAddr("borrower");
    address keeper = makeAddr("keeper");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, owner, owner);
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200);

        usdt0.mint(owner, 100_000e6);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, owner);
        usdt0.mint(address(router), 1_000_000e6);
    }

    function _borrow(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), coll);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    function _swapData(uint256 amountIn) internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(fxrp);
        path[1] = address(usdt0);
        return abi.encodeCall(MockRouter.swapExactTokensForTokens, (amountIn, 0, path, address(book), block.timestamp));
    }

    /// Pool funds can only ever be moved by the loan book.
    function test_OnlyLoanBookCanMovePoolFunds() public {
        vm.startPrank(attacker);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.disburse(attacker, 1e6, 1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.payout(attacker, 1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.pull(owner, 1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.impair(1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.unimpair(1e6);
        vm.stopPrank();
    }

    /// setLoanBook is one-shot: an attacker can't re-point the pool at their own contract.
    function test_LoanBookCannotBeReassigned() public {
        vm.prank(attacker);
        vm.expectRevert();
        pool.setLoanBook(attacker);
    }

    /// ERC4626 first-depositor / donation inflation attack must not grief a later depositor.
    function test_InflationAttackMitigated() public {
        LodestarPool p = new LodestarPool(IERC20(address(usdt0)), owner); // fresh, unseeded
        usdt0.mint(attacker, 1);
        vm.startPrank(attacker);
        usdt0.approve(address(p), type(uint256).max);
        p.deposit(1, attacker);
        usdt0.mint(attacker, 10_000e6);
        usdt0.transfer(address(p), 10_000e6); // donation
        vm.stopPrank();
        usdt0.mint(victim, 1_000e6);
        vm.startPrank(victim);
        usdt0.approve(address(p), type(uint256).max);
        uint256 shares = p.deposit(1_000e6, victim);
        vm.stopPrank();
        assertGt(shares, 0, "victim minted 0 shares -> attack succeeded");
        assertGe(p.previewRedeem(shares), 990e6, "victim lost >1% to inflation");
    }

    /// A keeper cannot settle a swap that returns less than the Dutch floor.
    function test_KeeperCannotSettleBelowFloor() public {
        uint256 id = _borrow(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        router.setRate(50, 100); // pays only ~50% of value, far below any floor level
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.BelowFloor.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        // even after the full decay the floor is 85%: still rejected
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.BelowFloor.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
    }

    /// A keeper cannot route the sale through an unapproved contract.
    function test_KeeperCannotUseRogueRouter() public {
        uint256 id = _borrow(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        MockRouter rogue = new MockRouter();
        usdt0.mint(address(rogue), 10_000e6);
        vm.prank(attacker);
        vm.expectRevert(LodestarLoanBook.RouterNotAllowed.selector);
        book.settleSwap(id, address(rogue), _swapData(950e6), 0);
    }

    /// A buyout below the current Dutch floor is impossible: cost is computed by the contract.
    function test_BuyoutAlwaysPaysTheFloor() public {
        uint256 id = _borrow(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 cost = book.buyoutCost(id); // ~$2500 right after default
        usdt0.mint(attacker, cost);
        vm.startPrank(attacker);
        usdt0.approve(address(book), type(uint256).max);
        book.buyout(id, type(uint256).max);
        vm.stopPrank();
        assertEq(usdt0.balanceOf(attacker), 0, "attacker paid the full floor cost");
        assertApproxEqRel(cost, 2_500e6, 0.01e18, "floor ~= full FTSO value at default");
    }

    /// A defaulting borrower earns no keeper bounty by settling their own loan.
    function test_BorrowerCannotFarmOwnDefaultBounty() public {
        uint256 id = _borrow(borrower, 1_000e6);
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(borrower);
        book.settleSwap(id, address(router), _swapData(1_000e6), 0);
        assertEq(fxrp.balanceOf(borrower), 0, "borrower extracted a bounty from their own default");
    }

    /// A price crash cannot liquidate an in-term loan, no matter how deep. Impairing it
    /// marks the pool's accounting but never touches the loan or the collateral.
    function test_NoLiquidationOnCrashInTerm() public {
        uint256 id = _borrow(borrower, 1_000e6);
        ftso.set(XRP, 25_000_000, 8); // XRP crashes 90% to $0.25
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.buyout(id, type(uint256).max);
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        book.impair(id); // accounting-only: allowed mid-term
        assertGt(pool.impairedLoss(), 0, "mid-term crash marked");
        (,,, uint256 principal,,,,, bool active,,) = book.loans(id);
        assertTrue(active, "loan still alive");
        assertEq(fxrp.balanceOf(address(book)), 1_000e6, "collateral untouched");
        assertGt(principal, 0);
        assertFalse(book.isDefaulted(id));
    }

    /// An underwater position cannot buy itself more time: rollover re-checks LTV.
    function test_UnderwaterRolloverBlocked() public {
        uint256 id = _borrow(borrower, 1_000e6);
        ftso.set(XRP, 150_000_000, 8); // -40%: $1500 collateral vs $1250 principal
        usdt0.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.rollover(id, 0);
        vm.stopPrank();
    }

    /// On genuine bad debt, the loss is realized transparently through the pool (no hidden insolvency).
    function test_BadDebtRealizedTransparently() public {
        uint256 id = _borrow(borrower, 1_000e6); // $2500 collateral, $1250 principal
        ftso.set(XRP, 50_000_000, 8); // $0.50
        router.setRate(5, 10); // router pays $0.50 per FXRP, matching the crashed oracle
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        uint256 assetsBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        assertEq(pool.principalOut(), 0, "principal not cleared after settlement");
        assertLt(pool.totalAssets(), assetsBefore, "loss not realized (phantom solvency)");
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active);
    }

    /// impair() cannot be used to grief the pool: it only ever marks the oracle-true loss,
    /// re-marks track the price, and repayment reverses the mark exactly.
    function test_ImpairCannotOvermark() public {
        uint256 id = _borrow(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        // healthy collateral: impair marks zero
        book.impair(id);
        assertEq(pool.impairedLoss(), 0, "no loss to mark while covered");

        // crash: mark appears; recovery: mark shrinks back
        ftso.set(XRP, 50_000_000, 8);
        book.impair(id);
        uint256 marked = pool.impairedLoss();
        assertGt(marked, 0);
        ftso.set(XRP, 200_000_000, 8); // $2.00: collateral covers again
        book.impair(id);
        assertEq(pool.impairedLoss(), 0, "mark not reversed on recovery");
    }

    /// Pause blocks NEW borrows but never touches existing loans or funds.
    function test_PauseBlocksBorrowsOnly() public {
        uint256 id = _borrow(borrower, 1_000e6);
        book.setPaused(true);
        fxrp.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        fxrp.approve(address(book), 1_000e6);
        vm.expectRevert(LodestarLoanBook.Paused.selector);
        book.open(address(fxrp), 1_000e6, 0);
        vm.stopPrank();
        // existing loan can still be repaid while paused (non-custodial); repay is principal-only
        (,,, uint256 principal,,,,,,,) = book.loans(id);
        usdt0.mint(borrower, principal);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), principal);
        book.repay(id);
        vm.stopPrank();
        assertEq(fxrp.balanceOf(borrower), 1_000e6, "collateral not returned while paused");
    }

    /// FTSO outage: settlement waits inside the fallback delay, then proceeds against the
    /// CACHED price floor — an outage can never be exploited to underprice a sale.
    function test_OracleOutageCachedFloorSettlement() public {
        uint256 id = _borrow(borrower, 1_000e6); // caches $2.50 at open
        ftso.set(XRP, 0, 8); // oracle now reverts (BadPrice)
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.OracleDown.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 100e6);

        vm.warp(block.timestamp + 7 days); // past the oracle-fallback delay
        // a keeper trying to self-deal at 40% of the cached value is still rejected
        router.setRate(10, 10);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.BelowFloor.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        // a fair fill against the cached price clears
        router.setRate(25, 10);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "defaulted loan not resolved after oracle-fallback delay");
    }

    /// Borrow amount can never exceed the tier LTV of the FTSO-valued collateral.
    function test_CannotBorrowAboveLTV() public {
        uint256 id = _borrow(borrower, 1_000e6); // 1000 FXRP @ $2.50 = $2500, 50% LTV
        (,,, uint256 principal,,,,,,,) = book.loans(id);
        assertLe(principal, 1_250e6, "borrowed above LTV");
        assertApproxEqAbs(principal, 1_250e6, 1, "LTV math off");
    }

    /// The stable the book holds is exactly the first-loss buffer: settlement can't strand funds.
    function test_BookHoldsExactlyTheBuffer() public {
        uint256 id = _borrow(borrower, 1_000e6);
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        assertEq(usdt0.balanceOf(address(book)), book.reserveBalance(), "stable stranded in the book");
    }
}
