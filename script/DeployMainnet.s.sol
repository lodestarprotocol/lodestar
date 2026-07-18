// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {LodestarPool} from "../src/LodestarPool.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";
import {SceptreRateAdapter} from "../src/flare/SceptreRateAdapter.sol";
import {FirelightRateAdapter} from "../src/flare/FirelightRateAdapter.sol";
import {FlareAddresses as FA} from "../src/flare/FlareAddresses.sol";

/// @notice Deploys Lodestar to FLARE MAINNET (chainId 14). Ownership is left with the deployer so
///         the wiring can be verified on-chain, THEN handed to the multisig via TransferOwnership.s.sol.
///
/// Run (deployer key never on the command line; read from the locked file at run time):
///   export DEPLOYER=0x59b7fb215e9C73A25B358929462A107E1fEc5088
///   forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url http://127.0.0.1:9650/ext/bc/C/rpc \
///     --private-key $(cat /c/Users/cyber/lodestar-deploy/wallets/deploy.pk) --broadcast --slow
///
/// EVERY address below is IMMUTABLE once deployed. A wrong token/feed cannot be fixed. The script
/// reverts if a required address is left at address(0). VERIFY each against official sources first.
contract DeployMainnet is Script {
    // All addresses come from the canonical, on-chain-verified src/flare/FlareAddresses.sol (single
    // source of truth). Re-verify FtsoV2 against the ContractRegistry at deploy time in case Flare
    // rotates the contract.
    address constant FTSO = FA.FTSO_V2;
    address constant USDT0 = FA.USDT0; // 6dp pool asset
    address constant FXRP = FA.FXRP; // 6dp, = AssetManagerFXRP.fAsset()

    address constant SFLR = FA.SFLR; // Sceptre sFLR, 18dp
    // sFLR exposes getPooledFlrByShares, NOT underlyingPerShare, so leave SFLR_RATE at 0 and the
    // script deploys a SceptreRateAdapter for it. Override only if you have a bespoke provider.
    address constant SFLR_RATE = address(0);
    // stXRP = Firelight stXRP (FA.STXRP): verified, adapter fork-proven, DEEP settlement (stXRP/FXRP
    // ~$5.8M SparkDEX V4 + ~$3M Enosys) and settlement fork-proven via SparkDEX V4 2-hop. ENABLED with
    // conservative params (STXRP_HAIRCUT + STXRP_CAP below) given Firelight is a newer protocol.
    address constant STXRP = FA.STXRP;
    address constant STXRP_RATE = address(0); // 0 -> the script deploys a FirelightRateAdapter

    // Whitelisted routers for settleSwap. settleSwap only grants a bounded collateral allowance and
    // checks the stable delta clears the Dutch floor, so a whitelisted standard router can't take funds.
    // LIQUIDITY verified via GeckoTerminal + on-chain 2026-07-18: SparkDEX V4 (Algebra) has the DEEPEST
    // pools (sFLR/WFLR ~$1.05M, stXRP/FXRP ~$5.8M, FXRP/USD₮0 ~$0.8M) -> all three settle deeply via DEX
    // (sFLR via WFLR, stXRP via FXRP, both 2-hop). V3.1 is fork-proven for FXRP direct. BlazeSwap = backup.
    address constant SPARKDEX_V4 = FA.SPARKDEX_V4_ROUTER; // Algebra — deepest sFLR/stXRP (2-hop)
    address constant SPARKDEX_V31 = FA.SPARKDEX_V31_ROUTER; // UniV3-fork — FXRP direct (fork-proven)
    address constant BLAZESWAP = FA.BLAZESWAP_ROUTER; // UniV2 (generic backup)

    bytes21 constant FEED_XRP = FA.FEED_XRP_USD;
    bytes21 constant FEED_FLR = FA.FEED_FLR_USD;

    // ---- risk params (calibrate before launch; conservative starting point) ----
    uint64 constant MAX_STALE = 15 minutes; // FTSO updates ~90s; bound <= 1h
    uint16 constant HAIRCUT_LST = 300; // 3% haircut on sFLR (can trade under NAV); FXRP = 0 (1:1)
    uint16 constant STXRP_HAIRCUT = 600; // 6% on stXRP: newer Firelight vault -> extra conservatism
    uint128 constant MIN_PRINCIPAL = 100e6; // $100 floor: prices out slot-exhaustion of maxActiveLoans
    uint256 constant CAP_LAUNCH_USD18 = 200_000e18; // start small per collateral; raise as confidence grows

    function run() external {
        require(FTSO != address(0), "set FTSO");
        require(USDT0 != address(0), "set USDT0");
        require(FXRP != address(0), "set FXRP");

        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);

        // ---- oracle + feeds ----
        LodestarOracle oracle = new LodestarOracle(FTSO, deployer);
        oracle.setFeed(FXRP, FEED_XRP, address(0), MAX_STALE, 0); // FXRP 1:1, no rate provider, no haircut
        if (SFLR != address(0)) {
            // sFLR speaks getPooledFlrByShares, not underlyingPerShare -> deploy a thin, immutable,
            // ownerless adapter (unless a bespoke provider is pinned).
            address sflrRate = SFLR_RATE;
            if (sflrRate == address(0)) sflrRate = address(new SceptreRateAdapter(SFLR));
            oracle.setFeed(SFLR, FEED_FLR, sflrRate, MAX_STALE, HAIRCUT_LST);
            console.log("sFLR rate adapter", sflrRate);
        }
        if (STXRP != address(0)) {
            // stXRP is an ERC-4626 vault over FXRP -> a FirelightRateAdapter converts its share rate.
            address stxrpRate = STXRP_RATE;
            if (stxrpRate == address(0)) stxrpRate = address(new FirelightRateAdapter(STXRP));
            oracle.setFeed(STXRP, FEED_XRP, stxrpRate, MAX_STALE, STXRP_HAIRCUT);
            console.log("stXRP rate adapter", stxrpRate);
        }

        // ---- pool + book ----
        LodestarPool pool = new LodestarPool(IERC20(USDT0), deployer);
        LodestarLoanBook book = new LodestarLoanBook(pool, oracle, deployer, deployer);
        pool.setLoanBook(address(book));

        book.setMinPrincipal(MIN_PRINCIPAL);

        // ---- tiers + exposure caps (conservative; <=70% LTV hard ceiling) ----
        book.addTier(FXRP, 5000, 7 days, 200); // 50% / 7d / 2%
        book.addTier(FXRP, 4500, 30 days, 350); // 45% / 30d / 3.5%
        book.setExposureCap(FXRP, CAP_LAUNCH_USD18);
        if (SFLR != address(0)) {
            book.addTier(SFLR, 4500, 7 days, 200);
            book.addTier(SFLR, 4000, 30 days, 350);
            book.setExposureCap(SFLR, CAP_LAUNCH_USD18);
        }
        if (STXRP != address(0)) {
            book.addTier(STXRP, 4000, 7 days, 200); // lower LTV than sFLR/FXRP for the newer vault
            book.addTier(STXRP, 3500, 30 days, 350);
            book.setExposureCap(STXRP, CAP_LAUNCH_USD18 / 4); // smaller launch cap for stXRP
        }

        // ---- settlement routers (optional; buyout works without any) ----
        if (SPARKDEX_V4 != address(0)) book.setRouterAllowed(SPARKDEX_V4, true);
        if (SPARKDEX_V31 != address(0)) book.setRouterAllowed(SPARKDEX_V31, true);
        if (BLAZESWAP != address(0)) book.setRouterAllowed(BLAZESWAP, true);

        // ---- seed the lender pool with any USD₮0 the deployer holds (ERC4626 inflation defense) ----
        uint256 bal = IERC20(USDT0).balanceOf(deployer);
        if (bal > 0) {
            IERC20(USDT0).approve(address(pool), bal);
            pool.deposit(bal, deployer);
        }

        vm.stopBroadcast();

        console.log("=== Lodestar deployed to Flare MAINNET (14) ===");
        console.log("LodestarOracle  ", address(oracle));
        console.log("LodestarPool    ", address(pool));
        console.log("LodestarLoanBook", address(book));
        console.log("Pool seeded USDT0", bal);
        console.log("Owner is still the deployer. Verify on-chain, then run TransferOwnership.s.sol.");
    }
}
