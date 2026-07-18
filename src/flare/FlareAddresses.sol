// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical Flare mainnet (chainId 14) addresses & FTSO feed ids used by Lodestar.
/// @dev Verified on-chain 2026-07-16. FtsoV2 resolved via the ContractRegistry.
library FlareAddresses {
    // Infrastructure
    address internal constant CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    address internal constant FTSO_V2 = 0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20;

    // Collateral & stable (re-verified on-chain 2026-07-17: symbol/decimals checked)
    address internal constant SFLR = 0x12e605bc104e93B45e1aD99F9e555f659051c2BB; // Sceptre sFLR (18dp)
    address internal constant FXRP = 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE; // FAsset FXRP (6dp), = AssetManagerFXRP.fAsset()
    address internal constant USDT0 = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D; // USD₮0 stable (6dp)
    address internal constant STXRP = 0x4C18Ff3C89632c3Dd62E796c0aFA5c07c4c1B2b3; // Firelight stXRP (6dp, ERC4626 over FXRP)
    address internal constant WFLR = 0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d; // wrapped FLR (2-hop mid for sFLR settlement)

    // Whitelisted settleSwap routers. Liquidity verified via GeckoTerminal + on-chain (2026-07-18):
    // SparkDEX V4 (Algebra, factory 0x805488Da) holds the DEEPEST pools — sFLR/WFLR ~$1.05M,
    // stXRP/FXRP ~$5.8M, FXRP/USD₮0 ~$0.8M — so sFLR settles via WFLR and stXRP via FXRP (2-hop).
    // SparkDEX V3.1 (UniV3-fork, factory 0x8A2578d2) is fork-proven for FXRP/USD₮0 fee 500.
    // BlazeSwap (UniV2) is the generic minor venue. (Enosys V3 is also deep for stXRP — add its
    // router once confirmed.)
    address internal constant SPARKDEX_V4_ROUTER = 0x69D57B9D705eaD73a5d2f2476C30c55bD755cc2F; // Algebra (V4) — deepest sFLR/stXRP
    address internal constant SPARKDEX_V31_ROUTER = 0x8a1E35F5c98C4E85B36B7B253222eE17773b2781; // UniV3-fork — FXRP (fork-proven)
    address internal constant BLAZESWAP_ROUTER = 0xe3A1b355ca63abCBC9589334B5e609583C7BAa06; // UniV2 (generic)

    // FTSO v2 feed ids (0x01 = crypto category + ASCII name, right-padded to 21 bytes)
    bytes21 internal constant FEED_FLR_USD = 0x01464c522f55534400000000000000000000000000;
    bytes21 internal constant FEED_XRP_USD = 0x015852502f55534400000000000000000000000000;
}
