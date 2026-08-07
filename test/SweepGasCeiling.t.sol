// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {LodestarPool} from "../src/LodestarPool.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter, MockRate} from "./Lodestar.t.sol";

/// @notice What actually sets the maxActiveLoans = 400 ceiling, and is there room above it?
///
/// Every lender exit calls syncImpairmentForExit(), which sweeps EVERY active loan. The bound exists
/// so a redemption can never exceed the block gas limit and strand lenders. Measured on the live
/// Coston2 book (400/400, healthy) the sweep costs ~6.03M gas, about 21.5% of Flare's 28M block —
/// which makes 400 look conservative.
///
/// That measurement is misleading on its own. The case the bound must survive is a mass crash, where
/// every loan goes underwater and the sweep writes an impairment mark per loan instead of just
/// reading. Cold SSTOREs dominate, and a crash is precisely when lenders try to leave. This measures
/// both so the ceiling is set from the worst case rather than the quiet one.
contract SweepGasCeilingTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);

    bytes21 constant XRP_USD = bytes21("XRP/USD");

    uint256 constant N = 400; // the contract's hard ceiling
    uint256 constant FLARE_BLOCK_GAS = 28_000_000; // measured on Coston2/Flare

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
        book.setMaxActiveLoans(uint32(N));

        usdt0.mint(lender, 5_000_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e6, lender);
        vm.stopPrank();
    }

    function _fill(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            address b = address(uint160(0x100000 + i));
            fxrp.mint(b, 200e6); // 200 FXRP @ $2.50 = $500, 50% LTV -> $250 principal
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), 200e6, 0);
            vm.stopPrank();
        }
    }

    function test_SweepGas_HealthyVsCrash_SetsTheRealCeiling() public {
        _fill(N);
        assertEq(book.activeLoanCount(), N, "did not fill the book");

        // --- healthy book: reads only, no impairment written ---
        uint256 g0 = gasleft();
        book.syncImpairmentForExit();
        uint256 healthy = g0 - gasleft();
        emit log_named_uint("HEALTHY sweep gas (400 loans)", healthy);
        emit log_named_uint("  per loan", healthy / N);
        emit log_named_uint("  pct of 28M block", healthy * 100 / FLARE_BLOCK_GAS);

        // --- mass crash: every loan underwater, so every loan writes a mark (cold SSTORE) ---
        // 80% drawdown puts a 50%-LTV loan far under water.
        ftso.set(XRP_USD, 50_000_000, 8); // $2.50 -> $0.50
        uint256 g1 = gasleft();
        book.syncImpairment(); // permissionless variant, same _syncAll
        uint256 crash = g1 - gasleft();
        emit log_named_uint("CRASH sweep gas, FIRST pass (cold writes)", crash);
        emit log_named_uint("  per loan", crash / N);
        emit log_named_uint("  pct of 28M block", crash * 100 / FLARE_BLOCK_GAS);

        // --- second crash pass: marks already written, so warm ---
        uint256 g2 = gasleft();
        book.syncImpairment();
        uint256 warm = g2 - gasleft();
        emit log_named_uint("CRASH sweep gas, second pass (warm)", warm);

        // Derive the ceiling from the WORST case, budgeting half a block: the sweep is only part of a
        // withdraw transaction, and a lender exit must never sit near the block edge.
        uint256 perLoanWorst = (crash > healthy ? crash : healthy) / N;
        uint256 budget = FLARE_BLOCK_GAS / 2;
        uint256 implied = budget / perLoanWorst;
        emit log_named_uint("worst-case gas per loan", perLoanWorst);
        emit log_named_uint("IMPLIED SAFE maxActiveLoans (half block)", implied);

        if (implied > N) {
            emit log_string("VERDICT: 400 is conservative even in a crash - headroom exists");
        } else {
            emit log_string("VERDICT: 400 is at or above the safe crash budget - do NOT raise it");
        }
    }
}
