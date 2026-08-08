// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice If the memo's OPERATION reverts, does `handleMintedFAssets` revert too, or succeed anyway?
///
/// This decides whether an executor can trust a successful receipt. The deployed MemoInstructions
/// library does:
///
///   (bool success, ) = _personalAccount.call{value: msg.value}(userOp.callData);
///
/// and a plain `.call` does NOT bubble a revert. If `success` is not required, then a memo whose
/// operation fails produces a Flare transaction that SUCCEEDS: the FXRP mints, the XRPL transaction
/// id is consumed by the replay guard, no loan opens, and a `status == 1` receipt tells the executor
/// everything worked. The user is left holding FXRP in an account they may not know how to drive,
/// and the operation can never be retried because the txId is spent.
///
/// That failure is invisible to every check an executor would naturally write, so it has to be
/// measured rather than assumed. Both outcomes are legitimate designs; the executor must be built
/// against whichever is real.
///
/// The trigger used here is a borrow for more collateral than the personal account holds. It is the
/// most likely real-world cause: the user's Payment mints less FXRP than the memo's `open()` asks to
/// lock, which happens whenever fees are deducted or the price moves between quoting and sending.
contract XrplInnerCallFailureTest is Test {
    address constant MAC = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    address constant ASSET_MANAGER_FXRP = 0xc1Ca88b937d0b528842F95d5731ffB586f4fbDFA;
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    address constant FXRP_WHALE = 0xFf02F742106B8a25C26e65C1f0d66BEC3C90d429;
    string constant XRPL_ADDR = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";
    uint256 constant MINT = 1_000e6;

    address payable executor = payable(address(0xE7EC));
    address pa;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        pa = IMac3(MAC).getPersonalAccount(XRPL_ADDR);
        address owner = IBook3(BOOK).owner();
        vm.prank(owner);
        IBook3(BOOK).setExposureCap(FXRP, 0);
        if (IBook3(BOOK).activeLoanCount() >= IBook3(BOOK).maxActiveLoans()) {
            uint256 victim = IBook3(BOOK).activeLoanIds(0);
            (,,, uint128 owed,,,,,,,) = IBook3(BOOK).loans(victim);
            address stable = IBook3(BOOK).stable();
            deal(stable, address(this), uint256(owed));
            IERC20(stable).approve(IBook3(BOOK).pool(), uint256(owed));
            IBook3(BOOK).repay(victim);
        }
    }

    function _fund(uint256 a) internal {
        vm.prank(FXRP_WHALE);
        IERC20(FXRP).transfer(MAC, a);
    }

    function _memo(uint256 nonce, Call3[] memory calls) internal view returns (bytes memory) {
        PackedUserOperation3 memory op = PackedUserOperation3({
            sender: pa, nonce: nonce, initCode: "",
            callData: abi.encodeCall(IPersonalAccount3.executeUserOp, (calls)),
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""});
        return abi.encodePacked(bytes1(0xFF), bytes1(uint8(0)), bytes8(uint64(0)), abi.encode(op));
    }

    function _approveMemo(uint256 n) internal view returns (bytes memory) {
        Call3[] memory c = new Call3[](1);
        c[0] = Call3({target: FXRP, value: 0,
                      data: abi.encodeCall(IERC20.approve, (BOOK, type(uint256).max))});
        return _memo(n, c);
    }

    /// @notice THE question. A borrow for 100x what the account holds must fail. Does the relay?
    function test_DoesAFailingInnerOperationRevertTheRelay() public {
        // setup first so the allowance is not the reason it fails.
        // The memo is built BEFORE vm.prank: building it calls getNonce(), and an external call in
        // an argument consumes the prank, so handleMintedFAssets would then be called by this test
        // contract and revert with OnlyAssetManager.
        _fund(MINT);
        bytes memory setupMemo = _approveMemo(IMac3(MAC).getNonce(pa));
        vm.prank(ASSET_MANAGER_FXRP);
        IMac3(MAC).handleMintedFAssets(keccak256("icf-setup"), XRPL_ADDR, MINT, 0,
                                       setupMemo, executor, "");

        uint256 held = IERC20(FXRP).balanceOf(pa);
        uint256 ask = held * 100 + 1e6;          // guaranteed more collateral than exists
        Call3[] memory c = new Call3[](1);
        c[0] = Call3({target: BOOK, value: 0, data: abi.encodeCall(IBook3.open, (FXRP, ask, 0))});

        uint256 loansBefore = IBook3(BOOK).activeLoanCount();
        uint256 nonceBefore = IMac3(MAC).getNonce(pa);

        _fund(MINT);
        bytes32 txId = keccak256("icf-doomed");
        bytes memory doomed = _memo(nonceBefore, c);   // built before the prank, same reason
        vm.prank(ASSET_MANAGER_FXRP);
        try IMac3(MAC).handleMintedFAssets(txId, XRPL_ADDR, MINT, 0,
                                           doomed, executor, "") {
            console2.log("RELAY SUCCEEDED despite the inner operation being impossible.");
            console2.log("  loans before / after", loansBefore, IBook3(BOOK).activeLoanCount());
            console2.log("  nonce before / after", nonceBefore, IMac3(MAC).getNonce(pa));
            console2.log("  FXRP stranded at the personal account", IERC20(FXRP).balanceOf(pa));

            // If we are here, a status==1 receipt does NOT mean the user's borrow happened.
            assertEq(IBook3(BOOK).activeLoanCount(), loansBefore, "no loan should exist");

            // And is the XRPL txId now burnt, making it unretryable?
            _fund(MINT);
            bytes memory retry = _memo(IMac3(MAC).getNonce(pa), c);
            vm.prank(ASSET_MANAGER_FXRP);
            try IMac3(MAC).handleMintedFAssets(txId, XRPL_ADDR, MINT, 0,
                                               retry, executor, "") {
                console2.log("  txId REUSABLE - the operation could be retried");
            } catch {
                console2.log("  txId CONSUMED - this payment can never be relayed again");
            }
        } catch {
            console2.log("RELAY REVERTED - a failing inner operation reverts the whole call.");
            console2.log("  This is the safe design: the executor's tx fails, nothing is consumed,");
            console2.log("  and a status==1 receipt is sufficient proof the user's borrow happened.");
            assertEq(IBook3(BOOK).activeLoanCount(), loansBefore, "nothing may have changed");
            assertEq(IMac3(MAC).getNonce(pa), nonceBefore, "nonce must not have advanced");
        }
    }
}

struct PackedUserOperation3 {
    address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits;
    uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature;
}
struct Call3 { address target; uint256 value; bytes data; }
interface IPersonalAccount3 { function executeUserOp(Call3[] calldata _calls) external payable; }
interface IMac3 {
    function handleMintedFAssets(bytes32, string calldata, uint256, uint256, bytes calldata,
                                 address payable, bytes calldata) external payable;
    function getPersonalAccount(string calldata) external view returns (address);
    function getNonce(address) external view returns (uint256);
}
interface IBook3 {
    function open(address, uint256, uint256) external returns (uint256);
    function repay(uint256) external;
    function loans(uint256) external view returns (address,address,uint256,uint128,uint128,uint128,
                                                   uint64,uint64,bool,uint128,uint128);
    function stable() external view returns (address);
    function owner() external view returns (address);
    function pool() external view returns (address);
    function activeLoanCount() external view returns (uint256);
    function maxActiveLoans() external view returns (uint32);
    function activeLoanIds(uint256) external view returns (uint256);
    function setExposureCap(address, uint256) external;
}
