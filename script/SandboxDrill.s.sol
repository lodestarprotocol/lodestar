// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {LodestarPool} from "../src/LodestarPool.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";

/// @notice Price feed we control, so the sandbox can simulate a crash the real FTSO never gives us
///         on testnet. Same shape as the suite's MockFtsoV2.
contract DrillFtso is IFtsoV2 {
    address public immutable owner = msg.sender;
    mapping(bytes21 => uint256) public value;
    mapping(bytes21 => int8) public dec;

    function set(bytes21 id, uint256 v, int8 d) external {
        require(msg.sender == owner, "not owner");
        value[id] = v;
        dec[id] = d;
    }

    function getFeedById(bytes21 id) external view returns (uint256, int8, uint64) {
        return (value[id], dec[id], uint64(block.timestamp));
    }
}

/// @notice UNDERWATER-DEFAULT FIRE DRILL on Coston2: a throwaway Oracle/Pool/Book instance wired to
///         a controllable feed, 10-minute tier + 10-minute grace, so we can crash the price and
///         watch impairment -> share-price markdown -> default -> underwater buyout end to end on a
///         live chain. Completely separate from the public v1.7 deployment.
contract SandboxDrill is Script {
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    address constant USDT0 = 0xC1A5B41512496B80903D1f32d6dEa3a73212E71F;
    bytes21 constant FEED_XRP = 0x015852502f55534400000000000000000000000000;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);

        DrillFtso ftso = new DrillFtso();
        ftso.set(FEED_XRP, 1_090_000, 6); // $1.09, matching the real XRP feed shape

        LodestarOracle oracle = new LodestarOracle(address(ftso), deployer);
        oracle.setFeed(FXRP, FEED_XRP, address(0), 15 minutes, 0);

        LodestarPool pool = new LodestarPool(IERC20(USDT0), deployer);
        LodestarLoanBook book = new LodestarLoanBook(pool, oracle, deployer, deployer);
        pool.setLoanBook(address(book));

        book.setMinPrincipal(1e5); // $0.10
        book.setRiskParams(600, 500, 500, 2000); // 10-min grace; keeper/penalty/feeReserve = defaults
        book.addTier(FXRP, 5000, 600, 200); // 50% LTV, 10-minute term, 2% fee
        book.setExposureCap(FXRP, 1_000_000e18);

        // Seed the pool: this deposit is the "lender" whose shares must mark down in the drill.
        IERC20(USDT0).approve(address(pool), 3e6);
        pool.deposit(3e6, deployer);

        // Open the doomed loan: 4 FXRP @ $1.09 = $4.36 collateral -> $2.18 principal at 50% LTV.
        IERC20(FXRP).approve(address(book), 4e6);
        uint256 id = book.open(FXRP, 4e6, 0);

        vm.stopBroadcast();

        console.log("=== SANDBOX DRILL deployed (Coston2) ===");
        console.log("DrillFtso ", address(ftso));
        console.log("Oracle    ", address(oracle));
        console.log("Pool      ", address(pool));
        console.log("Book      ", address(book));
        console.log("Loan id   ", id);
        console.log("sharePrice (assets per 1e12 shares)", pool.convertToAssets(1e12));
    }
}
