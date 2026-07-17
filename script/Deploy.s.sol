// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {LodestarPool} from "../src/LodestarPool.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";

/// @notice Deploys Lodestar v1.3 to Coston2 (chainId 114) against real test FXRP + USD₮0 and the live FTSOv2.
///   forge script script/Deploy.s.sol:Deploy --rpc-url $COSTON2_RPC --account lodestar-deployer \
///     --sender $DEPLOYER --password <pw> --broadcast
contract Deploy is Script {
    // Coston2 verified addresses (2026-07-16)
    address constant FTSO = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7; // FTestXRP, 6dp
    address constant USDT0 = 0xC1A5B41512496B80903D1f32d6dEa3a73212E71F; // USD₮0, 6dp
    bytes21 constant FEED_XRP = 0x015852502f55534400000000000000000000000000;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);

        LodestarOracle oracle = new LodestarOracle(FTSO, deployer);
        // FXRP is 1:1 XRP-backed (FAssets), so no haircut; 15-min staleness bound (FTSO ~90s).
        oracle.setFeed(FXRP, FEED_XRP, address(0), 15 minutes, 0);

        LodestarPool pool = new LodestarPool(IERC20(USDT0), deployer);
        LodestarLoanBook book = new LodestarLoanBook(pool, oracle, deployer, deployer);
        pool.setLoanBook(address(book));

        // Testnet: faucet dispenses 10 FXRP (~$11), so allow small loans. Mainnet keeps 10+.
        book.setMinPrincipal(1e6);
        // No DEX with FTestXRP liquidity exists on Coston2: buyout is the settlement path,
        // so no router is whitelisted here. Mainnet will whitelist SparkDEX V4 / V3.1 / Enosys.

        // FXRP tiers: 50% LTV / 7d / 2% fee, and 45% / 30d / 3.5%
        book.addTier(FXRP, 5000, 7 days, 200);
        book.addTier(FXRP, 4500, 30 days, 350);
        book.setExposureCap(FXRP, 1_000_000e18); // usd18 cap

        // seed the lender pool with the deployer's faucet USD₮0
        uint256 bal = IERC20(USDT0).balanceOf(deployer);
        if (bal > 0) {
            IERC20(USDT0).approve(address(pool), bal);
            pool.deposit(bal, deployer);
        }

        vm.stopBroadcast();

        console.log("=== Lodestar v1.5 deployed to Coston2 (114) ===");
        console.log("LodestarOracle  ", address(oracle));
        console.log("LodestarPool    ", address(pool));
        console.log("LodestarLoanBook", address(book));
        console.log("Pool seeded USDT0", bal);
    }
}
