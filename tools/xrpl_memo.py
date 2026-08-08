#!/usr/bin/env python3
"""Build the XRPL memo that makes an XRP holder borrow from Lodestar with no EVM wallet.

An XRPL user sends one Payment to an FAssets agent. FXRP mints straight into the Flare
`PersonalAccount` derived from their XRPL address, and the memo tells the chain what to do next. For
a 0xFE custom instruction the memo is a hash commitment, and the executor supplies the matching
bytes. From the verified deployed source (contracts/smartAccounts/library/MemoInstructions.sol):

    require(_memoData.length == 42, InvalidMemoData());
    bytes32 expected = bytes32(_memoData[10:42]);
    bytes32 actual   = keccak256(_data);
    require(actual == expected, CustomInstructionHashMismatch(expected, actual));
    userOp = abi.decode(_data, (PackedUserOperation));
    ...
    (bool success, ) = _personalAccount.call{value: msg.value}(userOp.callData);

Two things follow, and both are easy to get wrong:

  * `_data` is `abi.encode(userOp)` over the FULL nine-field struct, which is OpenZeppelin 5.5.0's
    `PackedUserOperation` (EIP-4337 v0.7+), NOT the older nine-field `UserOperation` of v0.6. Only
    sender, nonce and callData are validated on chain, but every field is inside the hash.
  * Because the struct is dynamic, Solidity's `abi.encode` prepends a 32-byte offset. Encoding the
    members without it produces a different hash and the instruction is rejected on chain, AFTER the
    user's XRP has already left their wallet.

Neither is assumed here. `selftest` diffs every intermediate against vectors emitted by
test/XrplMemoReference.t.sol, which computes them in Solidity itself.

Usage:
    python tools/xrpl_memo.py selftest
    python tools/xrpl_memo.py build --xrpl rXXXX --amount 1000 --tier 0 [--rpc URL]
"""
import argparse
import json
import sys

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

# Deployed Lodestar on Coston2, and the Smart Accounts diamond (same address on Coston2 and mainnet).
BOOK_COSTON2 = "0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46"
FXRP_COSTON2 = "0x0b6A3645c240605887a5532109323A3E12273dc7"
MASTER_ACCOUNT_CONTROLLER = "0x434936d47503353f06750Db1A444DBDC5F0AD37c"

# The nine-field OZ 5.5.0 PackedUserOperation, in declaration order.
USEROP_TUPLE = "(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)"
CALL_ARRAY = "(address,uint256,bytes)[]"


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def encode_approve(spender: str, amount: int) -> bytes:
    return selector("approve(address,uint256)") + abi_encode(
        ["address", "uint256"], [to_checksum_address(spender), amount]
    )


# DELIBERATELY the 3-argument form, though the book also has
#   open(address,uint256,uint256,uint256 minOut,uint256 deadline)
# and the XRPL relay window is the exact case that overload was written for: the user signs an XRPL
# Payment and an executor submits on Flare whenever it suits them, so the submitter chooses the
# moment the collateral is priced.
#
# It is NOT a mechanical switch, because of the failure semantics documented at the top of this file:
# a rejected instruction is rejected AFTER the user's XRP has left their wallet and FXRP has minted
# into their PersonalAccount. An expired deadline or a tripped minOut therefore does not return them
# to where they started -- it leaves them holding FXRP in an account they may have no idea how to
# drive, pending a second instruction. That can easily be worse than a borrow that filled a few
# percent smaller than quoted.
#
# So the guards want a recovery path first (a retry instruction, or an executor SLA short enough to
# make a tight deadline safe), which is a product decision, not an encoding one. Costs nothing to
# defer: the CONTRACT side already ships in this audit round, so adopting the overload here later
# needs no re-audit. Revisit alongside the executor design.
def encode_open(collateral: str, amount: int, tier: int) -> bytes:
    return selector("open(address,uint256,uint256)") + abi_encode(
        ["address", "uint256", "uint256"], [to_checksum_address(collateral), amount, tier]
    )


def encode_execute_user_op(calls) -> bytes:
    """abi.encodeCall(IPersonalAccount.executeUserOp, (calls))"""
    return selector("executeUserOp((address,uint256,bytes)[])") + abi_encode(
        [CALL_ARRAY], [[(to_checksum_address(t), v, d) for (t, v, d) in calls]]
    )


def encode_user_op(sender: str, nonce: int, call_data: bytes) -> bytes:
    """abi.encode(userOp).

    Encoded as ONE dynamic tuple parameter, which is what Solidity's abi.encode(struct) produces:
    a 32-byte offset followed by the tuple body. Encoding the members as nine separate parameters
    omits that offset and yields a different hash.
    """
    return abi_encode(
        [USEROP_TUPLE],
        [(to_checksum_address(sender), nonce, b"", call_data, b"\x00" * 32, 0, b"\x00" * 32, b"", b"")],
    )


def build_memo(user_op_hash: bytes, wallet_id: int = 0, executor_fee: int = 0) -> bytes:
    """[0]=0xFE [1]=walletId [2:10]=executorFee big-endian uint64 [10:42]=userOpHash."""
    if len(user_op_hash) != 32:
        raise ValueError("userOpHash must be 32 bytes")
    if not 0 <= wallet_id <= 0xFF:
        raise ValueError("walletId must fit in one byte")
    if not 0 <= executor_fee < 2**64:
        raise ValueError("executorFee must fit in uint64")
    memo = bytes([0xFE, wallet_id]) + executor_fee.to_bytes(8, "big") + user_op_hash
    assert len(memo) == 42, "memo must be exactly 42 bytes"
    return memo


def build_borrow(personal_account, amount, tier, book=BOOK_COSTON2, fxrp=FXRP_COSTON2,
                 nonce=0, wallet_id=0, executor_fee=0):
    """Everything an executor and an XRPL wallet need for one borrow."""
    calls = [
        (fxrp, 0, encode_approve(book, amount)),
        (book, 0, encode_open(fxrp, amount, tier)),
    ]
    call_data = encode_execute_user_op(calls)
    data = encode_user_op(personal_account, nonce, call_data)
    h = keccak(data)
    return {
        "personal_account": to_checksum_address(personal_account),
        "nonce": nonce,
        "approve_calldata": "0x" + calls[0][2].hex(),
        "open_calldata": "0x" + calls[1][2].hex(),
        "executeUserOp_callData": "0x" + call_data.hex(),
        "abi_encode_userOp": "0x" + data.hex(),   # this is `_data` the executor submits
        "userOpHash": "0x" + h.hex(),
        "memo_hex": "0x" + build_memo(h, wallet_id, executor_fee).hex(),
        "memo_len": len(build_memo(h, wallet_id, executor_fee)),
    }


# --------------------------------------------------------------------------- verification

# Emitted by test/XrplMemoReference.t.sol, computed in Solidity. If these ever disagree the encoder
# is wrong and must not be used: a mismatch is only discovered on chain, after the XRP is spent.
REFERENCE = {
    "personal_account": "0x221B34142F7d1c6761472130AA5652e731a25237",
    "amount": 1_000_000_000,
    "tier": 0,
    "nonce": 0,
    "wallet_id": 0,
    "executor_fee": 1_000_000,
    "approve_calldata": (
        "0x095ea7b30000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc46"
        "000000000000000000000000000000000000000000000000000000003b9aca00"),
    "open_calldata": (
        "0x89a86ad30000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7"
        "000000000000000000000000000000000000000000000000000000003b9aca00"
        "0000000000000000000000000000000000000000000000000000000000000000"),
    "userOpHash": "0x7173736fbd34ee7b9696063e5f93a513648d991d1ef3540b523b73f88ac9fa50",
    "memo_hex": ("0xfe0000000000000f4240"
                 "7173736fbd34ee7b9696063e5f93a513648d991d1ef3540b523b73f88ac9fa50"),
}


def selftest() -> int:
    r = REFERENCE
    got = build_borrow(r["personal_account"], r["amount"], r["tier"],
                       nonce=r["nonce"], wallet_id=r["wallet_id"], executor_fee=r["executor_fee"])
    checks = [
        ("approve calldata", got["approve_calldata"], r["approve_calldata"]),
        ("open calldata", got["open_calldata"], r["open_calldata"]),
        ("userOpHash", got["userOpHash"], r["userOpHash"]),
        ("42-byte memo", got["memo_hex"], r["memo_hex"]),
    ]
    bad = 0
    for name, a, b in checks:
        ok = a.lower() == b.lower()
        bad += 0 if ok else 1
        print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
        if not ok:
            print("      solidity: %s" % b)
            print("      python  : %s" % a)
    print("  [%s] memo length is 42" % ("PASS" if got["memo_len"] == 42 else "FAIL"))
    bad += 0 if got["memo_len"] == 42 else 1

    # Measured, not assumed: a two-call borrow encodes to 1,088 bytes of `_data`, which is OVER
    # XRPL's 1,024-byte memo cap. That is why 0xFE (a 32-byte hash commitment, with the bytes
    # delivered by an executor) is the only workable opcode here -- 0xFF would inline `_data` in the
    # memo and simply not fit. If a future batch ever shrinks under the cap, 0xFF becomes an option
    # and removes the dependency on an executor holding our data.
    XRPL_MEMO_CAP = 1024
    data_len = (len(got["abi_encode_userOp"]) - 2) // 2
    fits_inline = data_len <= XRPL_MEMO_CAP
    print("  [INFO] executor _data is %d bytes; 0xFF inline %s (XRPL cap %d)"
          % (data_len, "WOULD FIT" if fits_inline else "does NOT fit", XRPL_MEMO_CAP))
    print("\n%s" % ("ALL MATCH SOLIDITY" if bad == 0 else "%d MISMATCH(ES) - DO NOT USE" % bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest", help="diff every intermediate against the Solidity reference")
    b = sub.add_parser("build", help="build a memo for a real XRPL address")
    b.add_argument("--xrpl", required=True, help="XRPL classic address, e.g. rHb9...")
    b.add_argument("--amount", type=float, required=True, help="FXRP to lock, human units")
    b.add_argument("--tier", type=int, default=0)
    b.add_argument("--executor-fee", type=int, default=0, help="drops, paid to the executor")
    b.add_argument("--rpc", default="https://coston2-api.flare.network/ext/C/rpc")
    a = ap.parse_args()

    if a.cmd == "selftest":
        sys.exit(selftest())

    # Derive the account and nonce from chain rather than guessing either.
    from web3 import Web3
    w3 = Web3(Web3.HTTPProvider(a.rpc, request_kwargs={"timeout": 30}))
    mac = w3.eth.contract(
        address=to_checksum_address(MASTER_ACCOUNT_CONTROLLER),
        abi=[
            {"name": "getPersonalAccount", "type": "function", "stateMutability": "view",
             "inputs": [{"name": "_xrplOwner", "type": "string"}], "outputs": [{"type": "address"}]},
            {"name": "getNonce", "type": "function", "stateMutability": "view",
             "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
        ])
    pa = mac.functions.getPersonalAccount(a.xrpl).call()
    nonce = mac.functions.getNonce(pa).call()
    out = build_borrow(pa, int(round(a.amount * 1e6)), a.tier, nonce=nonce,
                       executor_fee=a.executor_fee)
    out["xrpl_address"] = a.xrpl
    out["chain_id"] = w3.eth.chain_id
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
