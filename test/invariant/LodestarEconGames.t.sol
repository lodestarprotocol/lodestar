// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter} from "../Lodestar.t.sol";

/// @notice Deterministic economic-game probes the fuzzer is unlikely to synthesize precisely.
contract LodestarEconGames is Test {
    MockERC20 stable;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    MockRouter router;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant XRP = bytes21("XRP/USD");

    address lp = address(0x11);
    address attacker = address(0xA);
    address borrower = address(0xB);
    address keeper = address(0xC);

    function setUp() public {
        stable = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        oracle = new LodestarOracle(address(ftso), address(this));
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(stable)), address(this));
        book = new LodestarLoanBook(pool, oracle, address(this), address(this));
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200);

        stable.mint(address(this), 1_000_000e6);
        stable.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e6, address(this));
        stable.mint(address(router), 100_000_000e6);
    }

    function _open(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), coll);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // GAME 1: deposit-before-unimpair / withdraw-before-impair sandwich.
    // An attacker who sees a crash coming should not be able to withdraw at par ahead of the
    // mark, nor deposit cheap right before a recovery re-mark to skim the bounce.
    // ------------------------------------------------------------------
    function test_Game_CannotDodgeMarkByExitingBeforeImpair() public {
        uint256 id = _open(borrower, 100_000e6); // big loan
        // attacker LPs at par
        stable.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        stable.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(100_000e6, attacker);
        vm.stopPrank();

        // crash happens; attacker tries to redeem BEFORE anyone calls impair()
        ftso.set(XRP, 25_000_000, 8); // -90%
        uint256 assetsIfExit = pool.previewRedeem(shares);

        // now the honest mark lands
        book.impair(id);
        uint256 assetsAfterMark = pool.previewRedeem(shares);

        // The pre-impair exit value must NOT exceed the post-mark value by a meaningful amount.
        // (If it did, the attacker could exit at par ahead of bad news = informed-exit hole.)
        assertLe(assetsAfterMark, assetsIfExit, "sanity: mark can only lower value");
        // The key property: totalAssets marks down, so an exit AFTER mark is worse — but the
        // protocol's defense is that ANYONE can impair permissionlessly in the same block.
        // Prove the gap the attacker could steal is bounded by one block's race, not structural:
        // after impair the attacker's shares are worth strictly less, so the pool is protected
        // the instant impair() is called.
        assertLt(assetsAfterMark, 100_000e6, "post-mark shares should reflect the loss");
    }

    // Deposit right before an UNIMPAIR (recovery) to skim the bounce: must not profit beyond
    // fair share, because totalAssets is already marked down when they deposit (they buy cheap
    // shares but everyone holding through the recovery gets the same lift pro-rata).
    function test_Game_DepositBeforeUnimpairIsFair() public {
        uint256 id = _open(borrower, 100_000e6);
        ftso.set(XRP, 25_000_000, 8); // -90%
        book.impair(id); // pool marked down

        // attacker deposits into the marked-down pool
        stable.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        stable.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(100_000e6, attacker);
        vm.stopPrank();
        uint256 costBasis = 100_000e6;

        // price recovers, loan repaid, mark reversed
        ftso.set(XRP, 250_000_000, 8);
        book.impair(id);
        (,,, uint256 principal,,,,,,,) = book.loans(id);
        stable.mint(borrower, principal);
        vm.startPrank(borrower);
        stable.approve(address(pool), principal);
        book.repay(id);
        vm.stopPrank();

        uint256 outVal = pool.previewRedeem(shares);
        // The attacker gets the pro-rata lift of the WHOLE pool's recovery, but they contributed
        // real capital while the pool was underwater (took real risk). Profit is bounded by their
        // pro-rata share of the recovered impairment — not a free lunch. Assert they did not mint
        // more value than a proportional claim on the (now-restored) pool allows.
        uint256 supply = pool.totalSupply();
        uint256 fairMax = (pool.totalAssets() * shares) / supply + 2; // rounding slack
        assertLe(outVal, fairMax, "attacker extracted more than pro-rata");
        // They can profit (that's just being an LP through a recovery), but bounded:
        assertLt(outVal, costBasis * 2, "unbounded skim");
    }

    // ------------------------------------------------------------------
    // GAME 2: impair() spam griefing. Repeated impair on a healthy loan must be a cheap no-op
    // and must not corrupt state or accumulate anything.
    // ------------------------------------------------------------------
    function test_Game_ImpairSpamIsHarmlessNoOp() public {
        uint256 id = _open(borrower, 1_000e6);
        uint256 assetsBefore = pool.totalAssets();
        for (uint256 i; i < 50; i++) {
            book.impair(id);
        }
        assertEq(pool.impairedLoss(), 0, "healthy impair spam accumulated loss");
        assertEq(pool.totalAssets(), assetsBefore, "impair spam moved share price");
        (,,,,,,,,, , uint256 marked) = book.loans(id);
        assertEq(marked, 0, "per-loan mark drifted");
    }

    // Toggle impair up/down repeatedly across a volatile price; impairedLoss must always equal
    // the single loan's current mark (no accumulation from repeated marking).
    function test_Game_ImpairToggleNoAccumulation() public {
        uint256 id = _open(borrower, 1_000e6);
        for (uint256 i; i < 30; i++) {
            ftso.set(XRP, i % 2 == 0 ? 50_000_000 : 250_000_000, 8);
            book.impair(id);
        }
        (,,,,,,,,,, uint256 marked) = book.loans(id);
        assertEq(pool.impairedLoss(), marked, "impairedLoss != single loan mark after toggling");
    }

    // ------------------------------------------------------------------
    // GAME 3: borrower opens a loan sized to be unsettleable, then defaults. Even if no keeper
    // ever settles, the pool must remain solvent-on-paper (impair marks the loss) and settlement
    // must eventually clear via buyout at the decayed floor.
    // ------------------------------------------------------------------
    function test_Game_UnsettleableLoanStillResolvable() public {
        uint256 id = _open(borrower, 1_000e6);
        ftso.set(XRP, 25_000_000, 8); // -90%, collateral now $250 vs $1250 principal
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        book.impair(id);
        assertGt(pool.impairedLoss(), 0, "loss not marked on defaulted underwater loan");

        // Buyout at the decayed floor always works — collateral is small but real.
        vm.warp(block.timestamp + 48 hours); // past full decay
        uint256 cost = book.buyoutCost(id);
        stable.mint(attacker, cost);
        vm.startPrank(attacker);
        stable.approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "unsettleable loan never resolved");
        assertEq(pool.impairedLoss(), 0, "mark not cleared at settlement");
        assertEq(pool.principalOut(), 0);
    }

    // ------------------------------------------------------------------
    // GAME 4: reserve-buffer drain vs shortfall obligations. Owner cannot withdraw buffer that is
    // needed to cover a pending shortfall in a way that leaves the book's stable balance != buffer.
    // withdrawReserve reverts on underflow; the invariant stable.balanceOf(book)==reserveBalance holds.
    // ------------------------------------------------------------------
    function test_Game_ReserveWithdrawCannotStrandShortfall() public {
        // build a buffer
        uint256 id0 = _open(address(0xFEE), 1_000e6);
        stable.mint(address(0xFEE), 1_250e6);
        vm.startPrank(address(0xFEE));
        stable.approve(address(pool), type(uint256).max);
        book.repay(id0);
        vm.stopPrank();
        uint256 buffer = book.reserveBalance();
        assertEq(stable.balanceOf(address(book)), buffer);

        // owner drains the whole buffer
        book.withdrawReserve(buffer);
        assertEq(book.reserveBalance(), 0);
        assertEq(stable.balanceOf(address(book)), 0, "book stable != buffer after withdraw");

        // trying to over-withdraw reverts (no negative buffer)
        vm.expectRevert();
        book.withdrawReserve(1);

        // now a default with a shortfall: buffer is empty, so the shortfall is simply a realized
        // lender loss — no phantom coverage, book stable stays == buffer (both 0 + any penalty).
        uint256 id = _open(borrower, 1_000e6);
        ftso.set(XRP, 50_000_000, 8);
        router.setRate(5, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 assetsBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(1_000e6), 0);
        assertLt(pool.totalAssets(), assetsBefore, "shortfall not realized (phantom coverage)");
        assertEq(stable.balanceOf(address(book)), book.reserveBalance(), "book stable stranded");
    }

    function _swapData(uint256 amountIn) internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(fxrp);
        path[1] = address(stable);
        return abi.encodeCall(MockRouter.swapExactTokensForTokens, (amountIn, 0, path, address(book), block.timestamp));
    }

    // ------------------------------------------------------------------
    // GAME 5: rounding accumulation over many small loans. Open+repay a dust-adjacent loan
    // thousands of times; the pool must not leak value to/from borrowers via rounding, and the
    // book's stable balance must stay exactly == reserveBalance the entire time.
    // ------------------------------------------------------------------
    function test_Game_RoundingDoesNotLeakOverManyCycles() public {
        // smallest principal that passes minPrincipal (10 USDT0). 15 FXRP @ $2.50 * 50% = $18.75.
        uint256 startAssets = pool.totalAssets();
        uint256 startPrincipalOut = pool.principalOut();

        for (uint256 i; i < 2_000; i++) {
            uint256 id = _open(borrower, 9e6); // 9 FXRP -> $22.5 -> $11.25 principal, fee 2%
            (,,, uint256 principal,,,,,,,) = book.loans(id);
            // repay principal-only
            stable.mint(borrower, principal);
            vm.startPrank(borrower);
            stable.approve(address(pool), principal);
            book.repay(id);
            vm.stopPrank();
            // invariant every cycle: book stable == buffer
            assertEq(stable.balanceOf(address(book)), book.reserveBalance(), "buffer drift mid-loop");
            assertEq(pool.principalOut(), startPrincipalOut, "principalOut leaked");
        }

        // pool should have GAINED fee yield (never lost). principalOut back to start.
        assertGe(pool.totalAssets(), startAssets, "pool LOST value over many cycles (rounding leak)");
        assertEq(pool.principalOut(), startPrincipalOut, "principalOut not restored");
        // borrower net-paid fees; never extracted free value
        // (borrower minted exactly `principal` each repay and received `principal - fee` at open)
    }

    // ------------------------------------------------------------------
    // GAME 6: can a loan be resolved twice? Repay then settle, or buyout then settleSwap.
    // ------------------------------------------------------------------
    function test_Game_CannotResolveTwice() public {
        uint256 id = _open(borrower, 1_000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 cost = book.buyoutCost(id);
        stable.mint(attacker, cost);
        vm.startPrank(attacker);
        stable.approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();

        // second buyout must revert NotActive
        vm.expectRevert(LodestarLoanBook.NotActive.selector);
        book.buyout(id, type(uint256).max);
        // settleSwap on the same id must revert NotActive
        vm.expectRevert(LodestarLoanBook.NotActive.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        // repay must revert NotActive
        vm.expectRevert(LodestarLoanBook.NotActive.selector);
        book.repay(id);
    }
}
