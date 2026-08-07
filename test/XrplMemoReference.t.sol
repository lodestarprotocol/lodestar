// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Solidity reference for the XRPL 0xFE custom-instruction encoding.
///
/// The off-chain encoder must produce bytes that Flare's MemoInstructions library accepts. From the
/// verified deployed source (contracts/smartAccounts/library/MemoInstructions.sol):
///
///   require(_memoData.length == 42, InvalidMemoData());
///   bytes32 expected = bytes32(_memoData[10:42]);
///   bytes32 actual   = keccak256(_data);
///   require(actual == expected, CustomInstructionHashMismatch(expected, actual));
///   userOp = abi.decode(_data, (PackedUserOperation));
///   ...
///   (bool success, ) = _personalAccount.call{value: msg.value}(userOp.callData);
///
/// So `_data` is `abi.encode(userOp)` and the memo commits to `keccak256` of exactly those bytes.
/// Getting the encoding wrong by one field fails on chain with a hash mismatch, and the user's XRP
/// has already left their wallet by then. This contract is the oracle the Python encoder is diffed
/// against, so the two can never drift on assumption alone.
///
/// PackedUserOperation is OpenZeppelin 5.5.0 / EIP-4337 v0.7+ (NOT the v0.6 `UserOperation`),
/// reproduced verbatim from the dependency the deployed facet actually imports.
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
    uint256 constant NONCE = 0;
    uint8 constant WALLET_ID = 0;
    uint64 constant EXECUTOR_FEE = 1_000_000; // 1 XRP in drops, in the FAsset's smallest unit

    function _buildCalls() internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({target: FXRP, value: 0, data: abi.encodeCall(IERC20.approve, (BOOK, AMOUNT))});
        calls[1] = Call({target: BOOK, value: 0, data: abi.encodeCall(IBook.open, (FXRP, AMOUNT, TIER))});
    }

    function _buildUserOp() internal pure returns (PackedUserOperation memory op) {
        Call[] memory calls = _buildCalls();
        op = PackedUserOperation({
            sender: PA,
            nonce: NONCE,
            initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (calls)),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev Emits every intermediate the encoder must reproduce.
    function test_EmitReferenceVectors() public pure {
        Call[] memory calls = _buildCalls();
        bytes memory callData = abi.encodeCall(IPersonalAccount.executeUserOp, (calls));
        PackedUserOperation memory op = _buildUserOp();
        bytes memory data = abi.encode(op);
        bytes32 h = keccak256(data);

        bytes memory memo = abi.encodePacked(bytes1(0xFE), bytes1(WALLET_ID), bytes8(EXECUTOR_FEE), h);
        require(memo.length == 42, "memo must be exactly 42 bytes");

        console2.log("approve_calldata");
        console2.logBytes(calls[0].data);
        console2.log("open_calldata");
        console2.logBytes(calls[1].data);
        console2.log("executeUserOp_callData");
        console2.logBytes(callData);
        console2.log("abi_encode_userOp");
        console2.logBytes(data);
        console2.log("userOpHash");
        console2.logBytes32(h);
        console2.log("memo_42_bytes");
        console2.logBytes(memo);
    }

    /// @dev The contract slices [10:42] for the hash, so the header must be exactly 10 bytes:
    ///      opcode(1) + walletId(1) + fee(8). Proves our packing lands the hash where it is read.
    function test_MemoHeaderIsExactlyTenBytes() public pure {
        bytes32 h = keccak256(abi.encode(_buildUserOp()));
        bytes memory memo = abi.encodePacked(bytes1(0xFE), bytes1(WALLET_ID), bytes8(EXECUTOR_FEE), h);
        assertEq(memo.length, 42, "length");
        assertEq(uint8(memo[0]), 0xFE, "opcode");
        assertEq(uint8(memo[1]), WALLET_ID, "walletId");
        // reproduce the contract's own slice and compare
        bytes memory sliced = new bytes(32);
        for (uint256 i; i < 32; i++) sliced[i] = memo[10 + i];
        assertEq(bytes32(sliced), h, "hash must sit at bytes [10:42]");
        // and the fee occupies [2:10], big-endian
        uint64 fee;
        for (uint256 i; i < 8; i++) fee = (fee << 8) | uint8(memo[2 + i]);
        assertEq(fee, EXECUTOR_FEE, "fee must be big-endian at [2:10]");
    }

    /// @dev abi.decode(_data, (PackedUserOperation)) must recover exactly what we put in, otherwise
    ///      the on-chain sender/nonce checks compare against garbage.
    function test_RoundTripDecodeMatches() public pure {
        PackedUserOperation memory op = _buildUserOp();
        PackedUserOperation memory back = abi.decode(abi.encode(op), (PackedUserOperation));
        assertEq(back.sender, op.sender, "sender");
        assertEq(back.nonce, op.nonce, "nonce");
        assertEq(keccak256(back.callData), keccak256(op.callData), "callData");
    }
}
