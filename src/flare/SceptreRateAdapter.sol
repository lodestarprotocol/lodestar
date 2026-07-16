// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILstRateProvider} from "../interfaces/ILstRateProvider.sol";

interface ISceptre {
    /// @return FLR value of `shares` sFLR (18dp in, 18dp out)
    function getPooledFlrByShares(uint256 shares) external view returns (uint256);
}

/// @notice Adapts Sceptre sFLR into an ILstRateProvider returning FLR-per-sFLR (1e18).
/// @dev Immutable, keyless. Used by LodestarOracle to price sFLR as FLR/USD * rate.
contract SceptreRateAdapter is ILstRateProvider {
    ISceptre public immutable sflr;

    constructor(address _sflr) {
        sflr = ISceptre(_sflr);
    }

    function underlyingPerShare() external view returns (uint256) {
        return sflr.getPooledFlrByShares(1e18);
    }
}
