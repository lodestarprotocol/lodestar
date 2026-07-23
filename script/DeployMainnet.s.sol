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

/// @dev Flare's canonical, address-stable contract registry (same on Flare/Songbird/Coston(2)).
///      Used to resolve the CURRENT FtsoV2 at deploy time instead of trusting a hardcoded constant.
interface IFlareContractRegistry {
    function getContractAddressByName(string calldata name) external view returns (address);
}

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
    // source of truth). FtsoV2 is NOT taken from the constant directly: it is resolved from the
    // FlareContractRegistry at deploy time (see run()) and cross-checked against this audited value,
    // so a stale constant or a Flare rotation can never silently point the immutable oracle at the
    // wrong contract — the deploy halts for human review instead.
    address constant REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019; // address-stable on all Flare nets
    address constant FTSO_EXPECTED = FA.FTSO_V2; // audited/reviewed FtsoV2; must equal the live registry value
    address constant USDT0 = FA.USDT0; // 6dp pool asset
    address constant FXRP = FA.FXRP; // 6dp, = AssetManagerFXRP.fAsset()

    address constant SFLR = FA.SFLR; // Sceptre sFLR, 18dp
    // sFLR exposes getPooledFlrByShares, NOT underlyingPerShare, so leave SFLR_RATE at 0 and the
    // script deploys a SceptreRateAdapter for it. Override only if you have a bespoke provider.
    address constant SFLR_RATE = address(0);
    // stXRP = Firelight stXRP (FA.STXRP): adapter fork-proven, DEEP settlement (stXRP/FXRP ~$5.8M
    // SparkDEX V4 + ~$3M Enosys). ON HOLD FOR LAUNCH: Kinetic (the only live Flare venue with an
    // opinion) assigns stXRP a 0% collateral factor — a strong "riskier than FXRP" signal for a
    // newer liquid-staked-XRP wrapper. Launch FXRP + sFLR first; RE-ENABLE later by setting this
    // back to FA.STXRP (feed/adapter/tiers/cap below are all ready and gated on STXRP != 0).
    address constant STXRP = address(0);
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
    uint16 constant RATE_CLAMP_BPS_PER_DAY = 20; // LST valuation-rate growth allowance (see setRateClamp)
    uint128 constant MIN_PRINCIPAL = 100e6; // $100 floor: prices out slot-exhaustion of maxActiveLoans
    uint256 constant SEED_MIN = 10e6; // $10 minimum first-deposit seed; deploy reverts if unseeded
    // GUARDED LAUNCH: tiny per-collateral borrow cap bounds the MAX possible loss from any tail risk
    // (incl. the sFLR rate provider being upgradeable by a single external EOA) to the cap size — a
    // cleaner, zero-code-change mitigation than an oracle rate-clamp. Multisig raises it via
    // setExposureCap as confidence grows (25k -> 50k -> ...). Aave-style cap-guardian launch.
    uint256 constant CAP_LAUNCH_USD18 = 25_000e18;

    function run() external {
        require(USDT0 != address(0), "set USDT0");
        require(FXRP != address(0), "set FXRP");

        // Resolve the CURRENT FtsoV2 from the registry and cross-check it against the audited value.
        // The oracle's ftso is immutable, so wiring a wrong/rotated address is unrecoverable. If the
        // live registry value ever differs from what was reviewed (FTSO_EXPECTED), HALT — never
        // silently deploy against an FtsoV2 whose interface hasn't been re-verified.
        address ftso = IFlareContractRegistry(REGISTRY).getContractAddressByName("FtsoV2");
        require(ftso != address(0), "FtsoV2 not in registry (wrong chain/registry?)");
        require(ftso == FTSO_EXPECTED, "FtsoV2 drift: registry != audited FA.FTSO_V2 -- re-verify before deploy");

        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);

        // ---- oracle + feeds ----
        LodestarOracle oracle = new LodestarOracle(ftso, deployer);
        oracle.setFeed(FXRP, FEED_XRP, address(0), MAX_STALE, 0); // FXRP 1:1, no rate provider, no haircut
        if (SFLR != address(0)) {
            // sFLR speaks getPooledFlrByShares, not underlyingPerShare -> deploy a thin, immutable,
            // ownerless adapter (unless a bespoke provider is pinned).
            address sflrRate = SFLR_RATE;
            if (sflrRate == address(0)) sflrRate = address(new SceptreRateAdapter(SFLR));
            oracle.setFeed(SFLR, FEED_FLR, sflrRate, MAX_STALE, HAIRCUT_LST);
            // Arm the valuation-side rate limiter: real sFLR yield is ~1.7 bps/day, so 20 bps/day
            // gives >10x headroom while capping a compromised Sceptre provider to +0.2%/day of
            // over-valuation. Keeper pokes the anchor forward periodically (see keeper duties).
            oracle.setRateClamp(SFLR, RATE_CLAMP_BPS_PER_DAY);
            console.log("sFLR rate adapter", sflrRate);
        }
        if (STXRP != address(0)) {
            // stXRP is an ERC-4626 vault over FXRP -> a FirelightRateAdapter converts its share rate.
            address stxrpRate = STXRP_RATE;
            if (stxrpRate == address(0)) stxrpRate = address(new FirelightRateAdapter(STXRP));
            oracle.setFeed(STXRP, FEED_XRP, stxrpRate, MAX_STALE, STXRP_HAIRCUT);
            oracle.setRateClamp(STXRP, RATE_CLAMP_BPS_PER_DAY); // same rate limiter for the Firelight vault
            console.log("stXRP rate adapter", stxrpRate);
        }

        // ---- pool + book ----
        LodestarPool pool = new LodestarPool(IERC20(USDT0), deployer);
        LodestarLoanBook book = new LodestarLoanBook(pool, oracle, deployer, deployer);
        pool.setLoanBook(address(book));

        book.setMinPrincipal(MIN_PRINCIPAL);

        // ---- tiers + exposure caps ----
        // TIERS ARE APPEND-ONLY AND IMMUTABLE: addTier can never be edited or removed, and a
        // borrower may always pick any tier by index, so every LTV/fee below is a PERMANENT
        // commitment. Launch is deliberately LEAN: two tiers per collateral (Standard 7d,
        // Extended 30d) — matching the dapp UI. 14d and 90d were evaluated and DEFERRED (append
        // them later if demand shows; 90d especially wants a richer term-premium fee and has no
        // mid-term LTV re-check, so it's not a launch tier).
        //
        // Calibration is verified, not assumed:
        //   - LTVs benchmarked live: Kinetic gives FXRP 70% WITH liquidation -> our 50% no-liq
        //     max sits correctly below; MoreMarkets borrows XRP at 50% even with liquidation;
        //     Myso's no-liq volatile range is 50-75% (we're at the floor); Aave puts volatile
        //     assets at 35-40%. LST (sFLR) ranked below FXRP.
        //   - Fees vs 8yr XRP / 3.5yr FLR drawdowns: expected loss per term is 0.05% (7d) /
        //     0.19% (30d); the 2% / 3.5% fees over-cover it ~18-42x. Also CHEAPER than Myso's
        //     realized no-liq deals (their 30d ~85-104% APY vs our ~43%), so borrower-competitive.
        // fee bps: 200 = 2% (7d) | 350 = 3.5% (30d)
        book.addTier(FXRP, 5000, 7 days, 200); // 50% / 7d / 2%
        book.addTier(FXRP, 4500, 30 days, 350); // 45% / 30d / 3.5%
        book.setExposureCap(FXRP, CAP_LAUNCH_USD18);
        if (SFLR != address(0)) {
            book.addTier(SFLR, 4500, 7 days, 200); // 45% / 7d / 2% (LST < FXRP)
            book.addTier(SFLR, 4000, 30 days, 350); // 40% / 30d / 3.5%
            book.setExposureCap(SFLR, CAP_LAUNCH_USD18);
        }
        // stXRP is ON HOLD for launch (STXRP == address(0) above -> this block is skipped). When
        // re-enabled, it launches lower than FXRP/sFLR (newer vault) with a quarter-size cap.
        if (STXRP != address(0)) {
            book.addTier(STXRP, 4000, 7 days, 200); // 40% / 7d / 2%
            book.addTier(STXRP, 3500, 30 days, 350); // 35% / 30d / 3.5%
            book.setExposureCap(STXRP, CAP_LAUNCH_USD18 / 4); // smaller launch cap for stXRP
        }

        // ---- settlement routers (optional; buyout works without any) ----
        if (SPARKDEX_V4 != address(0)) book.setRouterAllowed(SPARKDEX_V4, true);
        if (SPARKDEX_V31 != address(0)) book.setRouterAllowed(SPARKDEX_V31, true);
        if (BLAZESWAP != address(0)) book.setRouterAllowed(BLAZESWAP, true);

        // ---- seed the lender pool (ERC4626 inflation defense; belt-and-suspenders over _decimalsOffset).
        // MANDATORY: refuse to launch an unseeded pool. Fund the deploy wallet with >= SEED_MIN USD₮0
        // before broadcasting; the whole balance goes in as the first deposit (deployer = first lender).
        uint256 bal = IERC20(USDT0).balanceOf(deployer);
        require(bal >= SEED_MIN, "fund deployer with USDT0 to seed the pool (>= SEED_MIN)");
        IERC20(USDT0).approve(address(pool), bal);
        pool.deposit(bal, deployer);

        vm.stopBroadcast();

        console.log("=== Lodestar deployed to Flare MAINNET (14) ===");
        console.log("FtsoV2 (registry-resolved)", ftso);
        console.log("LodestarOracle  ", address(oracle));
        console.log("LodestarPool    ", address(pool));
        console.log("LodestarLoanBook", address(book));
        console.log("Pool seeded USDT0", bal);
        console.log("Owner is still the deployer. Verify on-chain, then run TransferOwnership.s.sol.");
    }
}
