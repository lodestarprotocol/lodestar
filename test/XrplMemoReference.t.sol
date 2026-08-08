// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Solidity reference for the XRPL custom-instruction encoding. This contract is the ORACLE
///         that `tools/xrpl_memo.py` is diffed against, so the two can never drift on assumption.
///
/// From the verified deployed source (contracts/smartAccounts/library/MemoInstructions.sol), the two
/// opcodes differ only in how `_data` reaches the chain:
///
///   0xFE  require(_memoData.length == 42, InvalidMemoData());
///         bytes32 expected = bytes32(_memoData[10:42]);
///         require(keccak256(_data) == expected, CustomInstructionHashMismatch(...));
///         -> the memo is a 32-byte COMMITMENT and an executor supplies the bytes separately.
///
///   0xFF  the operation is INLINE in the memo after the same 10-byte header, so `_data` is empty
///         and no executor holds anything -- though one is still needed to RELAY (see below).
///
/// Both then do:
///   userOp = abi.decode(<data>, (PackedUserOperation));
///   (bool success, ) = _personalAccount.call{value: msg.value}(userOp.callData);
///
/// THE PRODUCTION SHAPE IS 0xFF, IN TWO MEMOS. A single batch of approve+open encodes to 1,088 bytes,
/// over the memo cap, which is what forced 0xFE. Splitting it into a one-time infinite approve (810
/// bytes) and a single-call borrow (842 bytes) puts both under it. Proven end to end against Flare's
/// real deployed controller in test/fork/XrplEndToEnd.t.sol, and the 842-byte memo is proven sendable
/// on a validated XRPL testnet transaction.
///
/// This removes the executor's DATA DEPENDENCY, not the executor. Flare cannot observe an XRPL
/// payment by itself: someone must fetch an FDC attestation and call `executeDirectMinting` (0xFF) or
/// `executeDirectMintingWithData` (0xFE) on the AssetManager. With 0xFF that relayer needs none of
/// our bytes, so any indexer can do it -- but until one runs, a Payment carrying these memos mints
/// nothing.
///
/// The nonce is NOT guessed. test/fork/XrplNonceSemantics.t.sol proves against the deployed contract
/// that it advances by exactly one per operation and that BOTH stale and future nonces revert. Since
/// the user signs both XRPL payments before either executes, the encoder must emit the borrow at
/// setup_nonce + 1, and the setup payment must land first.
///
/// Two encoding traps, both silent until on chain, by which time the user's XRP is spent:
///   * `PackedUserOperation` is OpenZeppelin 5.5.0 / EIP-4337 v0.7+, NOT the v0.6 `UserOperation`.
///     Only sender, nonce and callData are validated, but every field is inside the hash.
///   * `abi.encode(struct)` of a DYNAMIC struct prepends a 32-byte offset. Encoding the nine members
///     as separate parameters omits it and produces different bytes.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

/// @dev Verbatim from contracts/userInterfaces/IPersonalAccount.sol on the deployed diamond.
struct Call {
    address target;
    uint256 value;
    bytes data;
}

interface IPersonalAccount {
    function executeUserOp(Call[] calldata _calls) external payable;
}

interface IBook {
    function open(address collateral, uint256 collAmount, uint256 tierIndex) external returns (uint256);
}

contract XrplMemoReferenceTest is Test {
    // Fixed vectors so the Python encoder can be diffed against an exact expected output.
    address constant PA = 0x221B34142F7d1c6761472130AA5652e731a25237; // rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    uint256 constant AMOUNT = 1_000e6; // 1,000 FXRP
    uint256 constant TIER = 0;
    uint256 constant NONCE = 0; // setup nonce; the borrow is built at NONCE + 1
    uint8 constant WALLET_ID = 0;
    uint64 constant EXECUTOR_FEE = 1_000_000; // legacy 0xFE path only; 0xFF needs no executor
    // MEASURED, not taken from the docs. Flare's docs and every write-up say "~1024 bytes", but a real
    // XRPL testnet submission rejects 1020 and accepts 1019 ("The memo exceeds the maximum allowed
    // size", local checks, so it never even reaches consensus). The 1024 limit applies to the whole
    // serialised Memo OBJECT; the MemoData field header consumes 5 of it. Bisected on XRPL testnet
    // 2026-08-08. Using 1024 here would pass a memo that XRPL refuses to send.
    uint256 constant XRPL_MEMO_CAP = 1019;

    // ---------------------------------------------------------------- builders

    function _wrap(uint256 nonce, Call[] memory calls) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: PA,
            nonce: nonce,
            initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (calls)),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev PRODUCTION step 1: one-time infinite approve, so no later borrow needs an approve call.
    function _setupOp() internal pure returns (PackedUserOperation memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call({target: FXRP, value: 0,
                     data: abi.encodeCall(IERC20.approve, (BOOK, type(uint256).max))});
        return _wrap(NONCE, c);
    }

    /// @dev PRODUCTION step 2: the borrow, a single call, at setup nonce + 1.
    function _borrowOp() internal pure returns (PackedUserOperation memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call({target: BOOK, value: 0, data: abi.encodeCall(IBook.open, (FXRP, AMOUNT, TIER))});
        return _wrap(NONCE + 1, c);
    }

    /// @dev LEGACY 0xFE: approve + open batched into one operation. Kept because it is still a valid
    ///      on-chain path (proven in the fork suite) and is the fallback if a future batch ever
    ///      exceeds the memo cap again.
    function _legacyBatchOp() internal pure returns (PackedUserOperation memory) {
        Call[] memory c = new Call[](2);
        c[0] = Call({target: FXRP, value: 0, data: abi.encodeCall(IERC20.approve, (BOOK, AMOUNT))});
        c[1] = Call({target: BOOK, value: 0, data: abi.encodeCall(IBook.open, (FXRP, AMOUNT, TIER))});
        return _wrap(NONCE, c);
    }

    function _memoFF(PackedUserOperation memory op) internal pure returns (bytes memory) {
        // 0xFF: same 10-byte header as 0xFE, then the operation inline instead of its hash.
        return abi.encodePacked(bytes1(0xFF), bytes1(WALLET_ID), bytes8(uint64(0)), abi.encode(op));
    }

    function _memoFE(PackedUserOperation memory op) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0xFE), bytes1(WALLET_ID), bytes8(EXECUTOR_FEE),
                                keccak256(abi.encode(op)));
    }

    // ---------------------------------------------------------------- vectors

    /// @dev Emits every intermediate the encoder must reproduce byte for byte.
    function test_EmitReferenceVectors() public pure {
        PackedUserOperation memory setupOp = _setupOp();
        PackedUserOperation memory borrowOp = _borrowOp();
        PackedUserOperation memory legacyOp = _legacyBatchOp();

        console2.log("=== PRODUCTION 0xFF, step 1: setup (infinite approve) ===");
        console2.log("setup_approve_calldata");
        console2.logBytes(abi.encodeCall(IERC20.approve, (BOOK, type(uint256).max)));
        console2.log("setup_executeUserOp_callData");
        console2.logBytes(setupOp.callData);
        console2.log("setup_abi_encode_userOp");
        console2.logBytes(abi.encode(setupOp));
        console2.log("setup_memo");
        console2.logBytes(_memoFF(setupOp));
        console2.log("setup_memo_len", _memoFF(setupOp).length);

        console2.log("=== PRODUCTION 0xFF, step 2: borrow (single call, nonce+1) ===");
        console2.log("borrow_open_calldata");
        console2.logBytes(abi.encodeCall(IBook.open, (FXRP, AMOUNT, TIER)));
        console2.log("borrow_executeUserOp_callData");
        console2.logBytes(borrowOp.callData);
        console2.log("borrow_abi_encode_userOp");
        console2.logBytes(abi.encode(borrowOp));
        console2.log("borrow_memo");
        console2.logBytes(_memoFF(borrowOp));
        console2.log("borrow_memo_len", _memoFF(borrowOp).length);

        console2.log("=== LEGACY 0xFE, batched approve+open, executor-delivered ===");
        console2.log("legacy_userOpHash");
        console2.logBytes32(keccak256(abi.encode(legacyOp)));
        console2.log("legacy_memo_42");
        console2.logBytes(_memoFE(legacyOp));
        console2.log("legacy_data_len", abi.encode(legacyOp).length);
    }

    // ---------------------------------------------------------------- properties

    /// @dev The whole reason the executor could be removed. If either of these ever exceeds the cap,
    ///      that shape is unsendable from a real XRPL wallet and the design must fall back to 0xFE.
    function test_BothProductionMemosFitTheXrplCap() public pure {
        uint256 s = _memoFF(_setupOp()).length;
        uint256 b = _memoFF(_borrowOp()).length;
        assertLe(s, XRPL_MEMO_CAP, "setup memo over the XRPL memo cap");
        assertLe(b, XRPL_MEMO_CAP, "borrow memo over the XRPL memo cap");
        // And the batched form does NOT fit, which is the fact that forced the split.
        assertGt(_memoFF(_legacyBatchOp()).length, XRPL_MEMO_CAP, "batched form should not fit");
    }

    /// @dev The contract slices [10:42] for the 0xFE hash, so the header must be exactly 10 bytes:
    ///      opcode(1) + walletId(1) + fee(8). 0xFF reuses the same header, so proving it here proves
    ///      the inline payload starts at byte 10 for both.
    function test_MemoHeaderIsExactlyTenBytes() public pure {
        PackedUserOperation memory op = _legacyBatchOp();
        bytes32 h = keccak256(abi.encode(op));
        bytes memory memo = _memoFE(op);
        assertEq(memo.length, 42, "length");
        assertEq(uint8(memo[0]), 0xFE, "opcode");
        assertEq(uint8(memo[1]), WALLET_ID, "walletId");
        bytes memory sliced = new bytes(32);
        for (uint256 i; i < 32; i++) sliced[i] = memo[10 + i];
        assertEq(bytes32(sliced), h, "hash must sit at bytes [10:42]");
        uint64 fee;
        for (uint256 i; i < 8; i++) fee = (fee << 8) | uint8(memo[2 + i]);
        assertEq(fee, EXECUTOR_FEE, "fee must be big-endian at [2:10]");

        // 0xFF: same header, payload inline from byte 10.
        bytes memory ff = _memoFF(op);
        assertEq(uint8(ff[0]), 0xFF, "0xFF opcode");
        assertEq(ff.length, 10 + abi.encode(op).length, "0xFF payload must start at byte 10");
    }

    /// @dev The two production memos MUST differ, and specifically must differ in nonce. If the
    ///      encoder built both at the same nonce the second would revert on chain, after the user's
    ///      XRP is spent. See test/fork/XrplNonceSemantics.t.sol for the on-chain proof.
    function test_ProductionMemosUseConsecutiveNonces() public pure {
        assertEq(_setupOp().nonce, NONCE, "setup at N");
        assertEq(_borrowOp().nonce, NONCE + 1, "borrow at N+1");
        assertTrue(keccak256(_memoFF(_setupOp())) != keccak256(_memoFF(_borrowOp())), "memos must differ");
    }

    /// @dev abi.decode(_data, (PackedUserOperation)) must recover exactly what we put in, otherwise
    ///      the on-chain sender/nonce checks compare against garbage.
    function test_RoundTripDecodeMatches() public pure {
        PackedUserOperation memory op = _borrowOp();
        PackedUserOperation memory back = abi.decode(abi.encode(op), (PackedUserOperation));
        assertEq(back.sender, op.sender, "sender");
        assertEq(back.nonce, op.nonce, "nonce");
        assertEq(keccak256(back.callData), keccak256(op.callData), "callData");
    }
}
