// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

/// @notice Testnet-only stand-in for a DEX router used by default settlement.
/// @dev Swaps at a fixed num/den ratio; must be pre-funded with the output token.
///      Not for mainnet — Coston2 has no deep DEX, so keeper settlement uses this.
contract MockRouter is IDexRouter {
    uint256 public num = 1;
    uint256 public den = 1;

    function setRate(uint256 _num, uint256 _den) external {
        num = _num;
        den = _den;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * num) / den;
        require(out >= amountOutMin, "MockRouter: slippage");
        IERC20(path[1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}
