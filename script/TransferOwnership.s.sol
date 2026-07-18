// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ILoanBookReserve {
    function setReserve(address) external;
    function reserve() external view returns (address);
}

/// @notice Points the protocol reserve at the treasury and hands ownership of the three Lodestar
///         Ownables (Oracle, Pool, LoanBook) to the governance multisig. Run ONLY after the deploy
///         is verified on-chain (feeds, tiers, caps, routers all correct) — the point of no return.
///
///   export ORACLE=0x... POOL=0x... BOOK=0x... MULTISIG=0x...   # the 3-of-5 Safe
///   export RESERVE=0x...   # optional: revenue destination; defaults to MULTISIG
///   forge script script/TransferOwnership.s.sol:TransferOwnership \
///     --rpc-url http://127.0.0.1:9650/ext/bc/C/rpc \
///     --private-key $(cat /c/Users/cyber/lodestar-deploy/wallets/deploy.pk) --broadcast --slow
///
/// @dev The contracts use plain OZ `Ownable` (single-step). transferOwnership takes effect
///      immediately, so the multisig must be a live, correctly-configured Safe BEFORE running this.
///      The reserve is moved OFF the hot deploy EOA first (while the deployer is still owner), so
///      withdrawn profit + any yield-skim route to the treasury, never the throwaway deploy key.
contract TransferOwnership is Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE");
        address pool = vm.envAddress("POOL");
        address book = vm.envAddress("BOOK");
        address multisig = vm.envAddress("MULTISIG");
        address deployer = vm.envAddress("DEPLOYER");
        address reserveTo = vm.envOr("RESERVE", multisig); // default revenue destination = the Safe

        require(multisig != address(0), "MULTISIG unset");
        require(oracle != address(0) && pool != address(0) && book != address(0), "addr unset");
        require(reserveTo != address(0), "RESERVE zero");
        // sanity: the multisig must be a contract (a Safe), never an EOA typo
        require(multisig.code.length > 0, "MULTISIG has no code (not a deployed Safe?)");

        // pre-checks: deployer must currently own all three
        require(Ownable(oracle).owner() == deployer, "deployer !owner oracle");
        require(Ownable(pool).owner() == deployer, "deployer !owner pool");
        require(Ownable(book).owner() == deployer, "deployer !owner book");

        vm.startBroadcast(deployer);
        // 1) move the reserve off the hot deploy EOA FIRST (needs the deployer to still be owner)
        if (ILoanBookReserve(book).reserve() != reserveTo) ILoanBookReserve(book).setReserve(reserveTo);
        // 2) hand over ownership of all three contracts
        Ownable(oracle).transferOwnership(multisig);
        Ownable(pool).transferOwnership(multisig);
        Ownable(book).transferOwnership(multisig);
        vm.stopBroadcast();

        // post-checks: reserve retargeted + every contract now owned by the multisig
        require(ILoanBookReserve(book).reserve() == reserveTo, "reserve not set");
        require(Ownable(oracle).owner() == multisig, "oracle transfer failed");
        require(Ownable(pool).owner() == multisig, "pool transfer failed");
        require(Ownable(book).owner() == multisig, "book transfer failed");

        console.log("=== Ownership transferred to multisig ===");
        console.log("multisig", multisig);
        console.log("reserve ", reserveTo);
        console.log("oracle owner", Ownable(oracle).owner());
        console.log("pool   owner", Ownable(pool).owner());
        console.log("book   owner", Ownable(book).owner());
    }
}
