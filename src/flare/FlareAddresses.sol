// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical Flare mainnet (chainId 14) addresses & FTSO feed ids used by Lodestar.
/// @dev Verified on-chain 2026-07-16. FtsoV2 resolved via the ContractRegistry.
library FlareAddresses {
    // Infrastructure
    address internal constant CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    address internal constant FTSO_V2 = 0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20;

    // Collateral & stable
    address internal constant SFLR = 0x12e605bc104e93B45e1aD99F9e555f659051c2BB; // Sceptre sFLR (18dp)
    address internal constant FXRP = 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE; // FAsset FXRP (6dp)
    address internal constant USDT0 = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D; // USD₮0 stable

    // FTSO v2 feed ids (0x01 = crypto category + ASCII name, right-padded to 21 bytes)
    bytes21 internal constant FEED_FLR_USD = 0x01464c522f55534400000000000000000000000000;
    bytes21 internal constant FEED_XRP_USD = 0x015852502f55534400000000000000000000000000;
}
