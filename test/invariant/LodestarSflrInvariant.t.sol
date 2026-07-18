// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter, MockRate} from "../Lodestar.t.sol";

/// @dev Fuzz handler for an 18-decimal LST collateral (sFLR). Mirrors the FXRP invariant handler but
///      exercises the 18dp path — open, impair, both settlement routes, partial repay, price crashes —
///      with correct 18dp bounty/units, so the launch collateral's decimal handling is fuzzed, not
///      just unit-tested. Stable (USD₮0) is 6dp; sFLR is 18dp.
contract SflrHandler is Test {
    LodestarLoanBook book;
    LodestarPool pool;
    LodestarOracle oracle;
    MockERC20 stable;
    MockERC20 sflr;
    MockFtsoV2 ftso;
    MockRouter router;
    bytes21 constant FLR = bytes21("FLR/USD");

    uint256[] public ids;
    address[] public actors;
    uint256 public ghostSettled;

    constructor(
        LodestarLoanBook _b,
        LodestarPool _p,
        LodestarOracle _o,
        MockERC20 _s,
        MockERC20 _sflr,
        MockFtsoV2 _ft,
        MockRouter _r
    ) {
        book = _b;
        pool = _p;
        oracle = _o;
        stable = _s;
        sflr = _sflr;
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
        collAmt = bound(collAmt, 1_000e18, 5_000_000e18); // 18dp sFLR
        address a = _actor(actorSeed);
        sflr.mint(a, collAmt);
        vm.startPrank(a);
        sflr.approve(address(book), collAmt);
        try book.open(address(sflr), collAmt, tierSeed % 2) returns (uint256 id) {
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

    function partialRepayLoan(uint256 idSeed, uint256 rSeed, uint256 cSeed, uint256 tierSeed, uint256 payerSeed)
        public
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,, uint256 collAmount, uint256 principal,,,,, bool active,,) = book.loans(id);
        if (!active || principal <= 1 || collAmount == 0) return;
        uint256 r = bound(rSeed, 1, principal);
        uint256 c = (cSeed % 2 == 0) ? 0 : bound(cSeed, 1, collAmount);
        address a = _actor(payerSeed);
        stable.mint(a, r);
        vm.startPrank(a);
        stable.approve(address(pool), r);
        try book.partialRepay(id, r, c, tierSeed % 2, 0) {} catch {}
        vm.stopPrank();
    }

    function addCollateral(uint256 idSeed, uint256 amt, uint256 payerSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,,,,,,, bool active,,) = book.loans(id);
        if (!active) return;
        amt = bound(amt, 1e18, 100_000e18);
        address a = _actor(payerSeed);
        sflr.mint(a, amt);
        vm.startPrank(a);
        sflr.approve(address(book), amt);
        try book.addCollateral(id, amt) {} catch {}
        vm.stopPrank();
    }

    function impairLoan(uint256 idSeed) public {
        if (ids.length == 0) return;
        try book.impair(ids[idSeed % ids.length]) {} catch {}
    }

    function settleViaSwap(uint256 idSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,, uint256 collAmount, uint256 principal,,,, uint64 dueAt, bool active,,) = book.loans(id);
        if (!active) return;
        vm.warp(uint256(dueAt) + 48 hours + 1);
        uint256 p18;
        try oracle.priceUsd18(address(sflr)) returns (uint256 p) {
            p18 = p;
        } catch {
            return;
        }
        if (p18 == 0) return;
        // dynamic fair rate: out = ~1.1x the oracle value of amountIn -> clears the Dutch floor and
        // stays under the 1.5x sane-proceeds ceiling, at whatever the current price is.
        router.setRate(11 * p18, 1e31);
        // replicate the contract's 18dp bounty so `collAmount - bounty` == the contract's toSell.
        uint256 bounty = (collAmount * book.keeperBps()) / 10_000;
        uint256 capTokens = (uint256(book.keeperCapUsd18()) * 1e18) / p18; // 1e18 = sFLR unit
        if (bounty > capTokens) bounty = capTokens;
        uint256 collValStable = ((p18 * collAmount) / 1e18) * 1e6 / 1e18; // usd18 -> stable(6dp)
        if (collValStable < principal) bounty = 0; // underwater -> contract pays no bounty
        address[] memory path = new address[](2);
        path[0] = address(sflr);
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

    function movePriceFlr(uint256 p) public {
        ftso.set(FLR, bound(p, 1e5, 1e8), 8); // FLR $0.001 .. $1 (never 0)
    }
}

contract LodestarSflrInvariant is StdInvariant, Test {
    LodestarLoanBook book;
    LodestarPool pool;
    LodestarOracle oracle;
    MockERC20 stable;
    MockERC20 sflr;
    MockRate sflrRate;
    MockFtsoV2 ftso;
    MockRouter router;
    SflrHandler h;
    bytes21 constant FLR = bytes21("FLR/USD");

    function setUp() public {
        stable = new MockERC20("USDT0", "USDT0", 6);
        sflr = new MockERC20("Staked FLR", "sFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(FLR, 2_000_000, 8); // $0.02
        sflrRate = new MockRate(); // 1 sFLR = 1 FLR

        oracle = new LodestarOracle(address(ftso), address(this));
        oracle.setFeed(address(sflr), FLR, address(sflrRate), 1 hours, 300); // 3% haircut

        pool = new LodestarPool(IERC20(address(stable)), address(this));
        book = new LodestarLoanBook(pool, oracle, address(this), address(this));
        pool.setLoanBook(address(book));

        router = new MockRouter();
        book.setRouterAllowed(address(router), true);
        book.addTier(address(sflr), 4500, 7 days, 200);
        book.addTier(address(sflr), 4000, 30 days, 350);

        stable.mint(address(this), 1_000_000e6);
        stable.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e6, address(this));
        stable.mint(address(router), 100_000_000e6);

        h = new SflrHandler(book, pool, oracle, stable, sflr, ftso, router);
        targetContract(address(h));
    }

    function invariant_sflr_principalOutMatchesLoans() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,, uint256 principal,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += principal;
        }
        assertEq(sum, pool.principalOut(), "principalOut drift (18dp)");
    }

    function invariant_sflr_collateralCustody() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,, uint256 collAmount,,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += collAmount;
        }
        assertEq(sflr.balanceOf(address(book)), sum, "18dp collateral custody drift");
    }

    function invariant_sflr_exposureMatches() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,,,, uint256 pUsd,,, bool active,,) = book.loans(h.ids(i));
            if (active) sum += pUsd;
        }
        assertEq(book.exposureUsd18(address(sflr)), sum, "18dp exposure drift");
    }

    function invariant_sflr_noDustPrincipal() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,, uint256 principal,,,,, bool active,,) = book.loans(h.ids(i));
            if (active) assertGe(principal, book.minPrincipal(), "dust-principal active loan (18dp)");
        }
    }

    function invariant_sflr_bookStableIsReserveBuffer() public view {
        assertEq(stable.balanceOf(address(book)), book.reserveBalance(), "stable stranded/missing (18dp)");
    }

    function invariant_sflr_activeArrayMatchesLoans() public view {
        uint256 active;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            (,,,,,,,, bool a,,) = book.loans(h.ids(i));
            if (a) active++;
        }
        assertEq(book.activeLoanCount(), active, "activeLoanIds drift (18dp)");
    }

    function invariant_sflr_totalAssetsNeverUnderflows() public view {
        pool.totalAssets(); // reverts on underflow -> invariant fails
    }
}
