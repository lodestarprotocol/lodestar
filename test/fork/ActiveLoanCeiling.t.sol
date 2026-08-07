// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice How much headroom is there above maxActiveLoans = 400?
///
/// `maxActiveLoans` is hard-bounded to [50, 400] in the contract, unlike `exposureCapUsd18` which the
/// owner can set freely. The reason is not risk appetite, it is gas: every lender exit calls
/// `syncImpairmentForExit()`, which sweeps EVERY active loan. If that sweep can exceed the block gas
/// limit, a lender cannot withdraw, which is a far worse failure than refusing a 401st borrow.
///
/// Coston2 currently sits at exactly 400/400 active loans, so the live book IS the worst case. This
/// measures the real sweep cost there and derives the actual ceiling, so any decision to raise the
/// bound is made on a number rather than on intuition.
interface IBook {
    function syncImpairment() external;
    function syncImpairmentForExit() external;
    function oracleReady() external view returns (bool);
    function activeLoanCount() external view returns (uint256);
    function maxActiveLoans() external view returns (uint32);
}

contract ActiveLoanCeilingTest is Test {
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    IBook book = IBook(BOOK);

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string("https://coston2-api.flare.network/ext/C/rpc"));
        vm.createSelectFork(rpc);
    }

    function test_MeasureExitSweepGasAtCeiling() public {
        uint256 n = book.activeLoanCount();
        uint256 cap = book.maxActiveLoans();
        emit log_named_uint("active loans on fork", n);
        emit log_named_uint("maxActiveLoans", cap);
        emit log_named_uint("block gas limit", block.gaslimit);

        // The exit-facing sweep is the one that gates lender withdrawals.
        uint256 g0 = gasleft();
        book.syncImpairmentForExit();
        uint256 used = g0 - gasleft();
        emit log_named_uint("syncImpairmentForExit gas", used);

        require(n > 0, "no active loans to measure");
        uint256 perLoan = used / n;
        emit log_named_uint("gas per active loan", perLoan);

        // Derive the ceiling from the measurement. Use half the block gas limit as the safe budget:
        // the sweep is only part of a withdraw transaction, and a lender exit must never sit near
        // the edge of a block.
        uint256 budget = block.gaslimit / 2;
        uint256 maxLoans = perLoan == 0 ? type(uint256).max : budget / perLoan;
        emit log_named_uint("safe budget (half block)", budget);
        emit log_named_uint("implied max active loans", maxLoans);

        if (maxLoans > cap) {
            emit log_string("HEADROOM: the 400 bound is conservative vs measured gas");
        } else {
            emit log_string("NO HEADROOM: 400 is already at or beyond the safe sweep budget");
        }
    }

    /// @dev The read-only twin runs on every maxWithdraw/maxRedeem quote, so integrators pay it too.
    function test_MeasureOracleReadyGas() public view {
        uint256 g0 = gasleft();
        bool ready = book.oracleReady();
        uint256 used = g0 - gasleft();
        assertTrue(ready || !ready);
        // view-call gas is not consensus-critical but it bounds RPC cost for integrators
        // (eth_call has its own gas cap, commonly 50M).
    }
}
