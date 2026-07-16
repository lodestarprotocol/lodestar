// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interface for Flare's enshrined FtsoV2 oracle.
/// @dev feedId is a 21-byte identifier (category + hex-encoded feed name), e.g. XRP/USD, FLR/USD.
interface IFtsoV2 {
    /// @return value    the feed value
    /// @return decimals number of decimals in `value` (can be negative)
    /// @return timestamp last update time (unix seconds)
    function getFeedById(bytes21 feedId) external view returns (uint256 value, int8 decimals, uint64 timestamp);
}
