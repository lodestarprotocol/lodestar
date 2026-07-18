// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter} from "../Lodestar.t.sol";

/// @dev ERC777-style collateral: calls a hook on the recipient during transfer.
contract HookToken is ERC20 {
    uint8 private immutable _dec;
    address public hookTarget;
    bool public hookOn;

    constructor(uint8 d) ERC20("HOOK", "HOOK") {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setHook(address t, bool on) external {
        hookTarget = t;
        hookOn = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookOn && to == hookTarget && to != address(0)) {
            ReentryAttacker(hookTarget).onTokensReceived();
        }
    }
}

contract ReentryAttacker {
    LodestarPool public pool;
    LodestarLoanBook public book;
    IERC20 public stable;
    bool public armed;
    uint256 public depositAmt;

    constructor(LodestarPool _pool, LodestarLoanBook _book, IERC20 _stable) {
        pool = _pool;
        book = _book;
        stable = _stable;
    }

    function arm(uint256 amt) external {
        armed = true;
        depositAmt = amt;
    }

    function doBuyout(uint256 id, uint256 maxCost) external {
        book.buyout(id, maxCost);
    }

    event Snap(uint256 totalAssets, uint256 impairedLoss, uint256 principalOut, uint256 sharePrice1e6);

    // Called during collateral transfer (buyout) — try to deposit at the pre-reversal price.
    function onTokensReceived() external {
        if (!armed) return;
        armed = false;
        emit Snap(pool.totalAssets(), pool.impairedLoss(), pool.principalOut(), pool.convertToAssets(1e6));
        stable.approve(address(pool), depositAmt);
        pool.deposit(depositAmt, address(this));
    }

    function redeemAll() external {
        pool.redeem(pool.balanceOf(address(this)), address(this), address(this));
    }
}

contract LodestarReentryAudit is Test {
    MockERC20 usdt0;
    HookToken coll;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant FEED = bytes21("XRP/USD");

    address owner = address(this);
    address lp = makeAddr("lp");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        coll = new HookToken(6);
        ftso = new MockFtsoV2();
        ftso.set(FEED, 250_000_000, 8); // $2.50
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(coll), FEED, address(0), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, owner, owner);
        pool.setLoanBook(address(book));
        book.addTier(address(coll), 5000, 7 days, 200);

        // LP seeds pool
        usdt0.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lp);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 c) internal returns (uint256 id) {
        coll.mint(who, c);
        vm.startPrank(who);
        coll.approve(address(book), c);
        id = book.open(address(coll), c, 0);
        vm.stopPrank();
    }

    /// Attempt the deposit-during-collateral-callback skim on a marked-then-recovered loan.
    function test_DepositDuringBuyoutCallbackSkim() public {
        // borrower opens: 10000 coll @ $2.50 = $25000, 50% LTV => 12500 principal
        uint256 id = _borrow(borrower, 10_000e6);

        // crash price so the loan is deeply underwater, then default
        ftso.set(FEED, 100_000_000, 8); // $1.00 => coll worth 10000
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        // mark the loss
        book.impair(id);
        uint256 markedLoss = pool.impairedLoss();
        assertGt(markedLoss, 0, "should be marked underwater");

        // price recovers ABOVE principal before settlement
        ftso.set(FEED, 400_000_000, 8); // $4.00 => coll worth 40000, floor >> principal

        // deploy attacker, fund it with stable for both buyout cost and the injected deposit
        ReentryAttacker atk = new ReentryAttacker(pool, book, IERC20(address(usdt0)));
        uint256 cost = book.buyoutCost(id);
        uint256 injectDeposit = 50_000e6;
        usdt0.mint(address(atk), cost + injectDeposit);

        // approve stable spend by book for the buyout cost (attacker contract must approve)
        vm.prank(address(atk));
        usdt0.approve(address(book), type(uint256).max);

        // arm the hook to re-enter pool.deposit during collateral receipt
        coll.setHook(address(atk), true);
        atk.arm(injectDeposit);

        uint256 sharesBefore = pool.balanceOf(address(atk));
        // execute buyout; if deposit-during-callback reverts, whole tx reverts
        try atk.doBuyout(id, cost) {
            uint256 sharesAfter = pool.balanceOf(address(atk));
            console2.log("attacker shares minted:", sharesAfter - sharesBefore);
            // Now let attacker exit; measure profit vs the stable put in for the deposit
            coll.setHook(address(atk), false);
            uint256 stableBeforeRedeem = usdt0.balanceOf(address(atk));
            vm.prank(address(atk));
            atk.redeemAll();
            uint256 got = usdt0.balanceOf(address(atk)) - stableBeforeRedeem;
            console2.log("deposit put in:", injectDeposit);
            console2.log("redeem got out:", got);
            if (got > injectDeposit) {
                console2.log("SKIM PROFIT:", got - injectDeposit);
            } else {
                console2.log("no profit; loss:", injectDeposit - got);
            }
            // Assert attacker did NOT profit from the deposit round-trip
            assertLe(got, injectDeposit, "ATTACKER SKIMMED THE REVERSAL");
        } catch (bytes memory reason) {
            console2.log("buyout reverted (reentry blocked)");
            emit log_named_bytes("revert", reason);
        }
    }

    /// Underwater with NO recovery: deposit-during-callback should NOT profit (fair marked price).
    function test_NoRecoveryNoSkim() public {
        uint256 id = _borrow(borrower, 10_000e6);
        ftso.set(FEED, 100_000_000, 8); // stays crashed
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        book.impair(id);

        ReentryAttacker atk = new ReentryAttacker(pool, book, IERC20(address(usdt0)));
        uint256 cost = book.buyoutCost(id);
        uint256 injectDeposit = 50_000e6;
        usdt0.mint(address(atk), cost + injectDeposit);
        vm.prank(address(atk));
        usdt0.approve(address(book), type(uint256).max);
        coll.setHook(address(atk), true);
        atk.arm(injectDeposit);
        // With the fix, the reentrant deposit reverts the whole buyout (ReentrancyGuard via
        // deposit->_syncImpairment while the LoanBook guard is held). Regression assertion.
        vm.expectRevert();
        atk.doBuyout(id, cost);
    }

    /// Control: identical buyout but NO reentrant deposit. Measure the honest LP's share value
    /// before vs after so we can attribute the skim to LP funds.
    function test_ControlNoReentrancyLpValue() public {
        uint256 id = _borrow(borrower, 10_000e6);
        ftso.set(FEED, 100_000_000, 8);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        book.impair(id);
        ftso.set(FEED, 400_000_000, 8);

        uint256 lpAssetsBefore = pool.convertToAssets(pool.balanceOf(lp));

        address buyer = makeAddr("honestBuyer");
        uint256 cost = book.buyoutCost(id);
        usdt0.mint(buyer, cost);
        vm.startPrank(buyer);
        usdt0.approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();

        uint256 lpAssetsAfter = pool.convertToAssets(pool.balanceOf(lp));
        console2.log("LP assets before:", lpAssetsBefore);
        console2.log("LP assets after :", lpAssetsAfter);
        // Honest recovery: LP is made whole (mark reversed, principal repaid). LP value RISES back.
        assertGe(lpAssetsAfter, lpAssetsBefore, "LP made whole on recovery");
    }
}
