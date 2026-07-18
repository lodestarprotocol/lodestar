// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILstRateProvider} from "../interfaces/ILstRateProvider.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Minimal ERC-4626 read surface of Firelight stXRP (0x4c18…b2b3): its underlying asset (FXRP)
///      and the assets backing a given share amount.
interface IERC4626Vault {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
}

/// @title FirelightRateAdapter
/// @notice Adapts Firelight stXRP (an ERC-4626 vault over FXRP) to Lodestar's `ILstRateProvider`.
///         Returns the FXRP backing one whole stXRP, scaled to 1e18 — the share->underlying rate the
///         oracle multiplies the XRP/USD feed by (FXRP is XRP-backed 1:1, so XRP/USD is FXRP/USD).
///         Immutable, ownerless, stateless: it only forwards a view call. Decimals are read once at
///         construction so the 1e18 scaling is correct regardless of the vault's / asset's decimals.
contract FirelightRateAdapter is ILstRateProvider {
    IERC4626Vault public immutable vault;
    uint256 public immutable oneShare; // 10**shareDecimals
    uint256 public immutable assetUnit; // 10**assetDecimals

    constructor(address _vault) {
        require(_vault != address(0), "vault=0");
        vault = IERC4626Vault(_vault);
        oneShare = 10 ** IERC4626Vault(_vault).decimals();
        assetUnit = 10 ** IERC20Metadata(IERC4626Vault(_vault).asset()).decimals();
    }

    /// @return underlying (FXRP) per 1 whole stXRP share, scaled to 1e18.
    function underlyingPerShare() external view returns (uint256) {
        return (vault.convertToAssets(oneShare) * 1e18) / assetUnit;
    }
}
