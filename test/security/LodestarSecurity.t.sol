// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
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
        oracle.setFeed(address(fxrp), XRP, address(0), 0);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, owner, owner);
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.setRouter(IDexRouter(address(router)));
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

    /// Pool funds can only ever be moved by the loan book.
    function test_OnlyLoanBookCanMovePoolFunds() public {
        vm.startPrank(attacker);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.disburse(attacker, 1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.payout(attacker, 1e6);
        vm.expectRevert(LodestarPool.NotLoanBook.selector);
        pool.pull(owner, 1e6);
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
        // attacker deposits 1 unit, then donates a large amount to spike the share price
        usdt0.mint(attacker, 1);
        vm.startPrank(attacker);
        usdt0.approve(address(p), type(uint256).max);
        p.deposit(1, attacker);
        usdt0.mint(attacker, 10_000e6);
        usdt0.transfer(address(p), 10_000e6); // donation
        vm.stopPrank();
        // victim deposits 1,000 USDT0
        usdt0.mint(victim, 1_000e6);
        vm.startPrank(victim);
        usdt0.approve(address(p), type(uint256).max);
        uint256 shares = p.deposit(1_000e6, victim);
        vm.stopPrank();
        assertGt(shares, 0, "victim minted 0 shares -> attack succeeded");
        // victim can redeem back essentially their deposit (>99%)
        assertGe(p.previewRedeem(shares), 990e6, "victim lost >1% to inflation");
    }

    /// A keeper cannot settle a swap that returns less than the FTSO-anchored floor.
    function test_KeeperCannotSettleBelowFtsoFloor() public {
        uint256 id = _borrow(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        router.setRate(50, 100); // pays only ~50% of value, below the 98% floor
        vm.prank(keeper);
        vm.expectRevert(bytes("MockRouter: slippage"));
        book.settle(id, 0);
    }

    /// A price crash cannot liquidate an in-term loan, no matter how deep.
    function test_NoLiquidationOnCrashInTerm() public {
        uint256 id = _borrow(borrower, 1_000e6);
        ftso.set(XRP, 25_000_000, 8); // XRP crashes 90% to $0.25
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.settle(id, 0);
        assertFalse(book.isDefaulted(id));
    }

    /// On genuine bad debt, the loss is realized transparently through the pool (no hidden insolvency).
    function test_BadDebtRealizedTransparently() public {
        uint256 id = _borrow(borrower, 1_000e6); // $2500 collateral, $1250 principal
        // deep crash so the sale can't cover the debt
        ftso.set(XRP, 50_000_000, 8); // $0.50
        router.setRate(5, 10); // router pays $0.50 per FXRP (matches crashed oracle)
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        uint256 assetsBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settle(id, 0);

        assertEq(pool.principalOut(), 0, "principal not cleared after settlement");
        assertLt(pool.totalAssets(), assetsBefore, "loss not realized (phantom solvency)");
        // and the loan is closed, so it can't be re-settled or double-counted
        (,,,,,,,, bool active) = book.loans(id);
        assertFalse(active);
    }

    /// Borrow amount can never exceed the tier LTV of the FTSO-valued collateral.
    function test_CannotBorrowAboveLTV() public {
        uint256 id = _borrow(borrower, 1_000e6); // 1000 FXRP @ $2.50 = $2500, 50% LTV
        (,,, uint256 principal,,,,,) = book.loans(id);
        // principal (6dp USDT0) must be <= 50% of $2500 = $1250
        assertLe(principal, 1_250e6, "borrowed above LTV");
        assertApproxEqAbs(principal, 1_250e6, 1, "LTV math off");
    }
}
