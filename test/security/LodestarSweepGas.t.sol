// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRouter} from "../Lodestar.t.sol";

/// @notice Quantifies the v1.5 withdraw-time impairment sweep: gas scales O(active loans), so a
///         griefer could inflate the loan count to make withdrawals expensive. This test measures
///         the real cost, proves it stays well under a block gas limit at the loan cap, and proves
///         it never reverts (never bricks a withdrawal). Informs the mainnet `maxActiveLoans` value.
contract LodestarSweepGasTest is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockFtsoV2 ftso;
    MockRouter router;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;
    bytes21 constant XRP = bytes21("XRP/USD");
    address lender = address(0x1E7D);

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        oracle = new LodestarOracle(address(ftso), address(this));
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        pool = new LodestarPool(IERC20(address(usdt0)), address(this));
        book = new LodestarLoanBook(pool, oracle, address(this), address(this));
        pool.setLoanBook(address(book));
        router = new MockRouter();
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.setExposureCap(address(fxrp), 100_000_000e18); // high cap so loan count is the only limit
        usdt0.mint(lender, 5_000_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e6, lender);
        vm.stopPrank();
    }

    function _openN(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            address b = address(uint160(0xB0B0000 + i));
            fxrp.mint(b, 100e6); // 100 FXRP @ $2.50 = $250 -> $125 principal
            vm.startPrank(b);
            fxrp.approve(address(book), type(uint256).max);
            book.open(address(fxrp), 100e6, 0);
            vm.stopPrank();
        }
    }

    function _measureWithdrawGas() internal returns (uint256 used) {
        vm.startPrank(lender);
        uint256 g0 = gasleft();
        pool.withdraw(1e6, lender, lender); // tiny withdraw -> triggers the full sweep
        used = g0 - gasleft();
        vm.stopPrank();
    }

    function test_SweepGasScalesAndStaysBounded() public {
        uint256[4] memory counts = [uint256(1), 50, 150, 300];
        for (uint256 i; i < counts.length; i++) {
            // fresh loans up to the target count
            uint256 have = book.activeLoanCount();
            if (counts[i] > have) _openN(counts[i] - have);
            uint256 gas = _measureWithdrawGas();
            emit log_named_uint(string(abi.encodePacked("withdraw gas @ ", vm.toString(counts[i]), " loans")), gas);
            // hard ceiling: even at 300 loans the sweep must stay well under a conservative 15M block
            assertLt(gas, 15_000_000, "withdraw sweep exceeds a safe block-gas bound");
        }
    }

    /// Even with every loan underwater (worst case: every mark writes), the sweep can't brick.
    function test_SweepUnderFullCrashDoesNotBrick() public {
        _openN(300);
        ftso.set(XRP, 25_000_000, 8); // 90% crash: all 300 loans underwater -> all marks write
        uint256 gas = _measureWithdrawGas();
        emit log_named_uint("withdraw gas @ 300 loans, all underwater (all marks write)", gas);
        assertLt(gas, 15_000_000, "worst-case sweep exceeds a safe block-gas bound");
        assertGt(pool.impairedLoss(), 0, "crash not marked by the sweep");
    }
}
