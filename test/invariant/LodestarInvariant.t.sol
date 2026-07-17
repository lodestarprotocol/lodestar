// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter} from "../Lodestar.t.sol";

/// @dev Randomised actor that pounds the protocol from every entrypoint.
contract Handler is Test {
    LodestarLoanBook book;
    LodestarPool pool;
    MockERC20 stable;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    MockRouter router;
    bytes21 constant XRP = bytes21("XRP/USD");

    uint256[] public ids;
    address[] public actors;
    uint256 public ghostSettled;

    constructor(LodestarLoanBook _b, LodestarPool _p, MockERC20 _s, MockERC20 _f, MockFtsoV2 _ft, MockRouter _r) {
        book = _b;
        pool = _p;
        stable = _s;
        fxrp = _f;
        ftso = _ft;
        router = _r;
        actors.push(address(0xA11));
        actors.push(address(0xB22));
        actors.push(address(0xC33));
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function openLoan(uint256 collAmt, uint256 actorSeed, uint256 tierSeed) public {
        collAmt = bound(collAmt, 1e6, 5_000e6);
        address a = _actor(actorSeed);
        fxrp.mint(a, collAmt);
        vm.startPrank(a);
        fxrp.approve(address(book), collAmt);
        try book.open(address(fxrp), collAmt, tierSeed % 2) returns (uint256 id) {
            ids.push(id);
        } catch {}
        vm.stopPrank();
    }

    function repayLoan(uint256 idSeed, uint256 payerSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,, uint256 principal,,,,, bool active,,) = book.loans(id);
        if (!active) return;
        address a = _actor(payerSeed);
        stable.mint(a, principal);
        vm.startPrank(a);
        stable.approve(address(pool), principal);
        try book.repay(id) {} catch {}
        vm.stopPrank();
    }

    function addCollateral(uint256 idSeed, uint256 amt, uint256 payerSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,,,,,,, bool active,,) = book.loans(id);
        if (!active) return;
        amt = bound(amt, 1e6, 1_000e6);
        address a = _actor(payerSeed);
        fxrp.mint(a, amt);
        vm.startPrank(a);
        fxrp.approve(address(book), amt);
        try book.addCollateral(id, amt) {} catch {}
        vm.stopPrank();
    }

    function rolloverLoan(uint256 idSeed, uint256 tierSeed, uint256 payerSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,, uint256 principal,,,,, bool active,,) = book.loans(id);
        if (!active) return;
        address a = _actor(payerSeed);
        stable.mint(a, principal); // more than any fee
        vm.startPrank(a);
        stable.approve(address(pool), principal);
        try book.rollover(id, tierSeed % 2) {} catch {}
        vm.stopPrank();
    }

    function impairLoan(uint256 idSeed) public {
        if (ids.length == 0) return;
        try book.impair(ids[idSeed % ids.length]) {} catch {}
    }

    function settleViaSwap(uint256 idSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (, address coll, uint256 collAmount,,,,, uint64 dueAt, bool active,,) = book.loans(id);
        if (!active) return;
        vm.warp(uint256(dueAt) + 48 hours + 1);
        router.setRate(25, 10); // generous fill so any floor level clears
        // reproduce the book's bounty math so the swap takes exactly the sale amount
        uint256 bounty = (collAmount * book.keeperBps()) / 10_000;
        uint256 p18 = book.lastPrice18(coll);
        if (p18 != 0) {
            uint256 capTokens = (uint256(book.keeperCapUsd18()) * 1e6) / p18;
            if (bounty > capTokens) bounty = capTokens;
        }
        address[] memory path = new address[](2);
        path[0] = coll;
        path[1] = address(stable);
        bytes memory data = abi.encodeCall(
            MockRouter.swapExactTokensForTokens, (collAmount - bounty, 0, path, address(book), block.timestamp)
        );
        try book.settleSwap(id, address(router), data, 0) {
            ghostSettled++;
        } catch {}
    }

    function settleViaBuyout(uint256 idSeed, uint256 actorSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,,,,,, uint64 dueAt, bool active,,) = book.loans(id);
        if (!active) return;
        vm.warp(uint256(dueAt) + 48 hours + 1);
        address a = _actor(actorSeed);
        uint256 cost;
        try book.buyoutCost(id) returns (uint256 c) {
            cost = c;
        } catch {
            return;
        }
        stable.mint(a, cost);
        vm.startPrank(a);
        stable.approve(address(book), cost);
        try book.buyout(id, cost) {
            ghostSettled++;
        } catch {}
        vm.stopPrank();
    }

    function deposit(uint256 amt, uint256 actorSeed) public {
        amt = bound(amt, 1e6, 100_000e6);
        address a = _actor(actorSeed);
        stable.mint(a, amt);
        vm.startPrank(a);
        stable.approve(address(pool), amt);
        try pool.deposit(amt, a) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 shareSeed, uint256 actorSeed) public {
        address a = _actor(actorSeed);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        vm.startPrank(a);
        try pool.redeem(bound(shareSeed, 1, bal), a, a) {} catch {}
        vm.stopPrank();
    }

    function movePrice(uint256 p) public {
        ftso.set(XRP, bound(p, 1e7, 1e11), 8); // XRP $0.10 .. $1000
    }
}

contract LodestarInvariant is StdInvariant, Test {
    LodestarLoanBook book;
    LodestarPool pool;
    MockERC20 stable;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    MockRouter router;
    LodestarOracle oracle;
    Handler h;
    bytes21 constant XRP = bytes21("XRP/USD");

    function setUp() public {
        stable = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50

        oracle = new LodestarOracle(address(ftso), address(this));
        oracle.setFeed(address(fxrp), XRP, address(0), 1 days);

        pool = new LodestarPool(IERC20(address(stable)), address(this));
        book = new LodestarLoanBook(pool, oracle, address(this), address(this));
        pool.setLoanBook(address(book));

        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.addTier(address(fxrp), 4500, 30 days, 350);

        stable.mint(address(this), 1_000_000e6);
        stable.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e6, address(this));
        stable.mint(address(router), 100_000_000e6); // settlement liquidity

        h = new Handler(book, pool, stable, fxrp, ftso, router);
        targetContract(address(h));
    }

    /// principalOut always equals the sum of active-loan principals.
    function invariant_principalOutMatchesLoans() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,, uint256 principal,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += principal;
        }
        assertEq(sum, pool.principalOut(), "principalOut drift");
    }

    /// The loan book custodies exactly the collateral of active loans (nothing stuck, nothing missing).
    function invariant_collateralCustody() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,, uint256 collAmount,,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += collAmount;
        }
        assertEq(fxrp.balanceOf(address(book)), sum, "collateral custody drift");
    }

    /// Recorded USD exposure per collateral equals the sum of active-loan USD principals.
    function invariant_exposureMatches() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,,,, uint256 pUsd,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += pUsd;
        }
        assertEq(book.exposureUsd18(address(fxrp)), sum, "exposure drift");
    }

    /// No active loan can exist below the minimum principal (dust guard holds under fuzzing).
    function invariant_noDustPrincipal() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,, uint256 principal,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) assertGe(principal, book.minPrincipal(), "dust-principal active loan");
        }
    }

    /// The stable balance the book holds is exactly its first-loss buffer.
    function invariant_bookStableIsReserveBuffer() public view {
        assertEq(stable.balanceOf(address(book)), book.reserveBalance(), "stable stranded or missing in book");
    }

    /// The pool's aggregate markdown equals the sum of active per-loan marks.
    function invariant_impairmentMatchesLoans() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,,,,,,, bool active,, uint256 marked) = book.loans(h.ids(i));
            if (active) sum += marked;
        }
        assertEq(sum, pool.impairedLoss(), "impairment drift");
    }
}
