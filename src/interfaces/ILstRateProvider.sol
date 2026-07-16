// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Converts a liquid-staking token (e.g. sFLR) into its underlying (FLR) value.
/// @dev Returns underlying tokens per 1 share, scaled to 1e18. For a 1:1 wrapper, return 1e18.
interface ILstRateProvider {
    function underlyingPerShare() external view returns (uint256);
}
