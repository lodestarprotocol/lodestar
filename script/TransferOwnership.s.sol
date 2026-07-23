// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

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
/// @dev The contracts use OZ `Ownable2Step`: this script only PROPOSES the multisig as pending
///      owner (a fat-fingered address can no longer brick ownership — the deployer stays owner
///      until the transfer is accepted). To COMPLETE the handoff the Safe must then execute
///      `acceptOwnership()` on ORACLE, POOL and BOOK (three Safe transactions; any signer can
///      propose them, threshold signs). Verify owner() == Safe on all three afterwards.
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

        // post-checks (2-step): reserve retargeted, multisig is PENDING owner on all three, and the
        // deployer still holds ownership until the Safe accepts (that is the safety property).
        require(ILoanBookReserve(book).reserve() == reserveTo, "reserve not set");
        require(Ownable2Step(oracle).pendingOwner() == multisig, "oracle pending != multisig");
        require(Ownable2Step(pool).pendingOwner() == multisig, "pool pending != multisig");
        require(Ownable2Step(book).pendingOwner() == multisig, "book pending != multisig");
        require(Ownable(oracle).owner() == deployer, "oracle owner changed early");
        require(Ownable(pool).owner() == deployer, "pool owner changed early");
        require(Ownable(book).owner() == deployer, "book owner changed early");

        console.log("=== Ownership PROPOSED to multisig (2-step) ===");
        console.log("multisig (pending owner)", multisig);
        console.log("reserve ", reserveTo);
        console.log("NEXT: Safe executes acceptOwnership() on oracle, pool, book:");
        console.log("  oracle", oracle);
        console.log("  pool  ", pool);
        console.log("  book  ", book);
        console.log("then verify owner() == Safe on all three.");
    }
}
