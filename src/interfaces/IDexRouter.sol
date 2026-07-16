// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap-v2-style router subset used only for default settlement swaps.
interface IDexRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
