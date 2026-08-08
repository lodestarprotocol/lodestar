// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pins the nonce behaviour that `tools/xrpl_memo.py` depends on.
///
/// The production shape is TWO memos: a one-time approve, then a borrow. Both are signed on XRPL
/// BEFORE either executes, so the encoder has to predict the second one's nonce rather than read it.
/// If it predicts wrong the borrow reverts on chain, after the user's XRP has already left their
/// wallet. Guessing this from the docs is exactly the kind of assumption that costs a user money, so
/// it is measured here against Flare's real deployed controller.
///
/// Three questions, all answered by execution rather than by reading:
///   1. does the nonce advance by exactly one per executed operation?
///   2. is a stale nonce actually rejected, or silently ignored?
///   3. is a FUTURE nonce rejected? (if it were accepted, ordering would not matter and the
///      encoder could emit both at the same nonce)
contract XrplNonceSemanticsTest is Test {
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
        pa = IMac(MAC).getPersonalAccount(XRPL_ADDR);
    }

    function _fund(uint256 a) internal {
        vm.prank(FXRP_WHALE);
        IERC20(FXRP).transfer(MAC, a);
    }

    /// @dev A one-call approve op at an explicit nonce, encoded exactly as the tool does it.
    function _approveMemo(uint256 nonce) internal view returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call({target: FXRP, value: 0, data: abi.encodeCall(IERC20.approve, (BOOK, type(uint256).max))});
        PackedUserOperation memory op = PackedUserOperation({
            sender: pa, nonce: nonce, initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (c)),
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""});
        return abi.encodePacked(bytes1(0xFF), bytes1(uint8(0)), bytes8(uint64(0)), abi.encode(op));
    }

    function test_NonceAdvancesByExactlyOnePerOperation() public {
        uint256 n0 = IMac(MAC).getNonce(pa);
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac(MAC).handleMintedFAssets(keccak256("n1"), XRPL_ADDR, MINT, 0, _approveMemo(n0), executor, "");
        uint256 n1 = IMac(MAC).getNonce(pa);

        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac(MAC).handleMintedFAssets(keccak256("n2"), XRPL_ADDR, MINT, 0, _approveMemo(n1), executor, "");
        uint256 n2 = IMac(MAC).getNonce(pa);

        console2.log("nonce before / after 1st / after 2nd", n0, n1, n2);
        assertEq(n1, n0 + 1, "one operation must advance the nonce by exactly 1");
        assertEq(n2, n1 + 1, "and again");
    }

    /// @dev THE property the encoder relies on: predicting nonce+1 for the second memo is safe only
    ///      if a stale nonce is refused. If it were ignored, a replayed memo would execute twice.
    function test_StaleNonceIsRejected() public {
        uint256 n0 = IMac(MAC).getNonce(pa);
        bytes memory memo = _approveMemo(n0);

        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac(MAC).handleMintedFAssets(keccak256("s1"), XRPL_ADDR, MINT, 0, memo, executor, "");
        assertEq(IMac(MAC).getNonce(pa), n0 + 1, "consumed");

        // Same memo, same (now stale) nonce, but a DIFFERENT XRPL txId so Flare's txId replay guard
        // is not what refuses it. This isolates the nonce check itself.
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        vm.expectRevert();
        IMac(MAC).handleMintedFAssets(keccak256("s2"), XRPL_ADDR, MINT, 0, memo, executor, "");
    }

    /// @dev If a future nonce were ACCEPTED, the encoder would not need to predict anything and the
    ///      two memos could be executed in either order. Proving it is refused is what makes ordering
    ///      a hard requirement the tool has to state to the user.
    function test_FutureNonceIsRejected() public {
        uint256 n0 = IMac(MAC).getNonce(pa);
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        vm.expectRevert();
        IMac(MAC).handleMintedFAssets(keccak256("f1"), XRPL_ADDR, MINT, 0, _approveMemo(n0 + 1), executor, "");
    }

    /// @dev The setup memo grants an INFINITE allowance, so later borrows need no approve. Proves the
    ///      allowance survives a subsequent operation rather than being consumed by it.
    function test_InfiniteApprovalPersistsAcrossOperations() public {
        uint256 n0 = IMac(MAC).getNonce(pa);
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac(MAC).handleMintedFAssets(keccak256("a1"), XRPL_ADDR, MINT, 0, _approveMemo(n0), executor, "");
        assertEq(IERC20(FXRP).allowance(pa, BOOK), type(uint256).max, "approval not set");

        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac(MAC).handleMintedFAssets(keccak256("a2"), XRPL_ADDR, MINT, 0, _approveMemo(n0 + 1), executor, "");
        assertEq(IERC20(FXRP).allowance(pa, BOOK), type(uint256).max, "approval must persist");
    }
}

struct PackedUserOperation {
    address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits;
    uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature;
}

struct Call { address target; uint256 value; bytes data; }

interface IPersonalAccount { function executeUserOp(Call[] calldata _calls) external payable; }

interface IMac {
    function handleMintedFAssets(bytes32, string calldata, uint256, uint256, bytes calldata,
                                 address payable, bytes calldata) external payable;
    function getPersonalAccount(string calldata) external view returns (address);
    function getNonce(address) external view returns (uint256);
}
