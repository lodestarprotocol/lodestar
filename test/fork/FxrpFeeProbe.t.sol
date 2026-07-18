// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Ground-truth probe of FXRP (FAsset) transfer mechanics on live Flare mainnet, to check
///         our custody assumptions: open() balance-delta (receipt) and settleSwap SwapIncomplete
///         (which requires the SENDER's balance to drop by EXACTLY the transferred amount).
/// Run: HEAVY_FORK=1 FORK_RPC=<rpc> ~/.foundry/bin/forge test --match-path test/fork/FxrpFeeProbe.t.sol -vv
contract FxrpFeeProbe is Test {
    address constant FXRP = 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE;
    address constant HOLDER = 0xD1b7A5eFa9bd88F291F7A4563a8f6185c0249CB3; // Kinetic isoFXRP, ~21.5M FXRP

    function setUp() public {
        // Heavy live-fork probe; gated so it doesn't run (or rate-limit) in the default suite.
        if (!vm.envOr("HEAVY_FORK", false)) vm.skip(true);
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://flare-api.flare.network/ext/C/rpc")));
    }

    function test_FxrpTransferMechanic() public {
        address B = address(0xBEEF01);
        uint256 amt = 1000e6; // 1000 FXRP

        uint256 sBefore = IERC20(FXRP).balanceOf(HOLDER);
        uint256 rBefore = IERC20(FXRP).balanceOf(B);
        vm.prank(HOLDER);
        IERC20(FXRP).transfer(B, amt);
        uint256 senderDelta = sBefore - IERC20(FXRP).balanceOf(HOLDER);
        uint256 recvDelta = IERC20(FXRP).balanceOf(B) - rBefore;

        emit log_named_uint("amount requested", amt);
        emit log_named_uint("sender balance decreased by", senderDelta);
        emit log_named_uint("recipient received", recvDelta);

        // Simulate the exact settleSwap custody check: a contract holding `amt` sends it out and
        // requires balanceOf == before - amt. This is what _swapViaRouter's SwapIncomplete enforces.
        if (senderDelta == amt && recvDelta == amt) {
            emit log("RESULT: NO transfer fee -> open() and settleSwap custody checks both hold.");
        } else if (senderDelta == amt && recvDelta < amt) {
            emit log("RESULT: RECIPIENT-side fee -> SwapIncomplete OK (sender delta == amt); router just gets less, bounded by the floor/BelowFloor check.");
        } else {
            emit log("RESULT: SENDER-side fee (senderDelta > amt) -> settleSwap SwapIncomplete WOULD REVERT for FXRP. Investigate.");
        }
        // Assert the custody-critical property explicitly so a regression is loud.
        assertEq(senderDelta, amt, "SENDER-side fee detected: settleSwap SwapIncomplete would break for FXRP");
    }
}
