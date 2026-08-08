#!/usr/bin/env python3
"""Build the XRPL memos that let an XRP holder borrow from Lodestar with no EVM wallet.

An XRPL user sends a Payment to an FAssets agent. FXRP mints straight into the Flare
`PersonalAccount` derived from their XRPL address, and a memo on that Payment tells the chain what to
do next. Flare's deployed `MemoInstructions` library supports two custom opcodes:

    0xFE   the memo is a 32-byte COMMITMENT to keccak256(_data); an EXECUTOR must supply the
           matching bytes in a separate argument.
    0xFF   the operation is INLINE in the memo after the same 10-byte header; `_data` is empty and
           no executor holds anything.

THE PRODUCTION SHAPE IS 0xFF, IN TWO MEMOS.

    step 1, once per XRPL address:   approve(BOOK, uint256.max)      810 bytes
    step 2, every borrow:            open(FXRP, amount, tier)        842 bytes

Both fit under XRPL's 1,024-byte memo cap, which is what removes the executor from the design
entirely. Batching approve+open into a single operation encodes to 1,088 bytes, over the cap: that is
the only reason 0xFE and an executor were ever needed. Proven end to end against Flare's real
deployed controller in test/fork/XrplEndToEnd.t.sol.

ORDER IS MANDATORY, AND THE NONCE IS PREDICTED, NOT READ.
The user signs BOTH XRPL Payments before EITHER executes, so the encoder cannot read the second
nonce from chain -- it has to predict it. test/fork/XrplNonceSemantics.t.sol proves against the
deployed contract that the nonce advances by exactly one per operation and that BOTH a stale and a
future nonce revert. So the setup memo is built at nonce N, the borrow at N+1, and the setup Payment
MUST land first. If the setup fails for any reason, the borrow memo is invalid and must be rebuilt.

TWO ENCODING TRAPS, both silent until on chain, by which time the user's XRP is already spent:

  * `_data` is `abi.encode(userOp)` over the FULL nine-field struct, which is OpenZeppelin 5.5.0's
    `PackedUserOperation` (EIP-4337 v0.7+), NOT the older nine-field `UserOperation` of v0.6. Only
    sender, nonce and callData are validated on chain, but every field is inside the encoding.
  * Because the struct is dynamic, Solidity's `abi.encode` prepends a 32-byte offset. Encoding the
    members as nine separate parameters omits it and produces different bytes.

Neither is assumed. `selftest` diffs every intermediate against vectors emitted by
test/XrplMemoReference.t.sol, which computes them in Solidity itself.

Usage:
    python tools/xrpl_memo.py selftest
    python tools/xrpl_memo.py build --xrpl rXXXX --amount 1000 --tier 0 [--rpc URL]
    python tools/xrpl_memo.py state --xrpl rXXXX [--rpc URL]
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

# ⚠️ MAINNET: BOOK is set by DeployMainnet, FXRP is 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE.
#    The controller address is the same on Coston2 and mainnet. See MAINNET_SWITCHOVER.md.

# The nine-field OZ 5.5.0 PackedUserOperation, in declaration order.
USEROP_TUPLE = "(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)"
CALL_ARRAY = "(address,uint256,bytes)[]"

XRPL_MEMO_CAP = 1024  # bytes, per XRPL Memo field
MAX_UINT256 = 2**256 - 1

# Coston2 FAssets AssetManager for FXRP. Mainnet has its own; see MAINNET_SWITCHOVER.md.
ASSET_MANAGER_FXRP_COSTON2 = "0xc1Ca88b937d0b528842F95d5731ffB586f4fbDFA"


def memo_data(memo: bytes) -> str:
    """The value to paste into an XRPL Memo field: bare uppercase hex, NO 0x.

    XRPL memo fields are hex strings. Verified against xrpl-py 5.0.0: a 0x-prefixed MemoData is
    accepted by the model constructor without complaint and then dies at serialization with
    "non-hexadecimal number found", i.e. the mistake surfaces at submit time rather than build time.
    """
    return memo.hex().upper()


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def encode_approve(spender: str, amount: int) -> bytes:
    return selector("approve(address,uint256)") + abi_encode(
        ["address", "uint256"], [to_checksum_address(spender), amount]
    )


# DELIBERATELY the 3-argument form, though the book also has
#   open(address,uint256,uint256,uint256 minOut,uint256 deadline)
# and the XRPL relay window is the exact case that overload was written for.
#
# It is NOT a mechanical switch, because of the failure semantics at the top of this file: a rejected
# instruction is rejected AFTER the user's XRP has left their wallet and FXRP has minted into their
# PersonalAccount. An expired deadline or a tripped minOut therefore does not return them to where
# they started -- it leaves them holding FXRP in an account they may have no idea how to drive,
# pending a second instruction. That can easily be worse than a borrow that filled a few percent
# smaller than quoted. The guards want a recovery path first, which is a product decision rather than
# an encoding one, and deferring costs nothing: the CONTRACT side already ships in this audit round.
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
    omits that offset and yields different bytes.
    """
    return abi_encode(
        [USEROP_TUPLE],
        [(to_checksum_address(sender), nonce, b"", call_data, b"\x00" * 32, 0, b"\x00" * 32, b"", b"")],
    )


def memo_ff(sender: str, nonce: int, calls, wallet_id: int = 0) -> bytes:
    """0xFF: header(10) + abi.encode(userOp) inline. No executor, no separate data channel.

    The executor fee is fixed at 0. There is no executor in this path, and the controller checks
    `_amount >= _executorFee`, so a non-zero fee here would only create a way for a small deposit to
    be rejected.
    """
    if not 0 <= wallet_id <= 0xFF:
        raise ValueError("walletId must fit in one byte")
    data = encode_user_op(sender, nonce, encode_execute_user_op(calls))
    return bytes([0xFF, wallet_id]) + (0).to_bytes(8, "big") + data


def memo_fe(sender: str, nonce: int, calls, wallet_id: int = 0, executor_fee: int = 0) -> bytes:
    """LEGACY 0xFE: header(10) + keccak256(_data). An executor must submit the matching `_data`."""
    if not 0 <= wallet_id <= 0xFF:
        raise ValueError("walletId must fit in one byte")
    if not 0 <= executor_fee < 2**64:
        raise ValueError("executorFee must fit in uint64")
    data = encode_user_op(sender, nonce, encode_execute_user_op(calls))
    memo = bytes([0xFE, wallet_id]) + executor_fee.to_bytes(8, "big") + keccak(data)
    assert len(memo) == 42, "0xFE memo must be exactly 42 bytes"
    return memo


def setup_calls(book=BOOK_COSTON2, fxrp=FXRP_COSTON2):
    """One-time infinite approve, so no later borrow needs an approve call in its memo."""
    return [(fxrp, 0, encode_approve(book, MAX_UINT256))]


def borrow_calls(amount, tier, book=BOOK_COSTON2, fxrp=FXRP_COSTON2):
    return [(book, 0, encode_open(fxrp, amount, tier))]


def _step(kind, memo, nonce, order, note):
    if len(memo) > XRPL_MEMO_CAP:
        raise ValueError(
            "%s memo is %d bytes, over the XRPL cap of %d. This shape is unsendable from an XRPL "
            "wallet; fall back to the 0xFE executor path." % (kind, len(memo), XRPL_MEMO_CAP))
    return {"nonce": nonce, "send_order": order, "memo_len": len(memo),
            "memo_data": memo_data(memo),        # paste THIS into the XRPL Memo field
            "memo_hex": "0x" + memo.hex(),       # same bytes, 0x-prefixed, for EVM tooling only
            "note": note}


def build(personal_account, amount, tier, nonce, book=BOOK_COSTON2, fxrp=FXRP_COSTON2,
          wallet_id=0, needs_setup=True):
    """The production memos. `nonce` is the CURRENT on-chain nonce of the personal account.

    `needs_setup=False` when the account already holds an infinite allowance to the book. That is not
    cosmetic: the setup Payment is what advances the nonce, so skipping it means the borrow executes
    at `nonce`, not `nonce + 1`. Emitting a borrow at nonce+1 alongside a "you can skip step 1"
    warning -- which is what this did -- hands the user a memo that reverts AFTER their XRP is spent.
    """
    pa = to_checksum_address(personal_account)
    out = {"personal_account": pa, "collateral_amount_6dp": amount, "tier": tier,
           "setup_required": bool(needs_setup)}

    if needs_setup:
        out["setup"] = _step(
            "setup", memo_ff(pa, nonce, setup_calls(book, fxrp), wallet_id), nonce, 1,
            "Send FIRST. One-time per XRPL address: grants the book an unlimited FXRP allowance so "
            "no later borrow needs an approve call in its memo. The FXRP this Payment mints is NOT "
            "spent -- it stays in your personal account and can be locked by the borrow below.")
        borrow_nonce = nonce + 1
        borrow_note = ("Send SECOND, and only after the setup Payment has been processed. It is "
                       "signed for nonce %d and reverts at any other, which is proven on chain in "
                       "test/fork/XrplNonceSemantics.t.sol." % borrow_nonce)
    else:
        borrow_nonce = nonce
        borrow_note = ("The allowance is already set, so there is no setup step and this is the ONLY "
                       "Payment to send. Signed for nonce %d." % borrow_nonce)

    out["borrow"] = _step("borrow", memo_ff(pa, borrow_nonce, borrow_calls(amount, tier, book, fxrp),
                                            wallet_id), borrow_nonce,
                          2 if needs_setup else 1, borrow_note)
    return out


# --------------------------------------------------------------------------- XRPL address checks

_B58 = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz"


def is_valid_xrpl_address(addr: str) -> bool:
    """Base58-decode and verify the 4-byte double-SHA256 checksum.

    Used instead of trusting a regex match, because the candidate is scraped out of an ABI blob whose
    exact layout is not vendored here, and the result is an address a user will send real XRP to.
    """
    import hashlib
    if not addr or addr[0] != "r" or not 25 <= len(addr) <= 35:
        return False
    n = 0
    for ch in addr:
        i = _B58.find(ch)
        if i < 0:
            return False
        n = n * 58 + i
    raw = n.to_bytes(25, "big") if n < 256**25 else None
    if raw is None or raw[0] != 0x00:          # 0x00 = classic account address prefix
        return False
    return hashlib.sha256(hashlib.sha256(raw[:21]).digest()).digest()[:4] == raw[21:]


def _xrpl_address_in(blob: bytes):
    """Find the one checksum-valid XRPL address in an ABI-encoded struct."""
    import re
    for m in re.finditer(rb"r[1-9A-HJ-NP-Za-km-z]{24,34}", blob):
        cand = m.group(0).decode()
        # the regex is greedy at the tail; try progressively shorter prefixes
        for end in range(len(cand), 24, -1):
            if is_valid_xrpl_address(cand[:end]):
                return cand[:end]
    return None


# --------------------------------------------------------------------------- verification

# precommit-allow-hex: keccak256 test vectors and ABI-encoded memos, every one recomputed from
# public inputs by `selftest`. No key material is or may be stored in this file.
# Emitted by test/XrplMemoReference.t.sol, computed in Solidity, transcribed programmatically rather
# than by hand. If these ever disagree the encoder is wrong and must not be used: a mismatch is only
# discovered on chain, after the XRP is spent.
#
# Fixture: PA 0x221B34142F7d1c6761472130AA5652e731a25237 (rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh),
# BOOK/FXRP as the Coston2 constants above, 1,000 FXRP, tier 0, setup nonce 0, walletId 0.
REFERENCE = json.loads(r"""
{
 "setup_approve_calldata": "0x095ea7b30000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc46ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
 "setup_executeUserOp_callData": "0x2b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b30000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc46ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000000000000000000000000000000000000000000000",
 "setup_abi_encode_userOp": "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000221b34142f7d1c6761472130aa5652e731a2523700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000002e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001442b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b30000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc46ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
 "setup_memo": "0xff0000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000221b34142f7d1c6761472130aa5652e731a2523700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000002e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001442b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b30000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc46ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
 "setup_memo_len": 810,
 "borrow_open_calldata": "0x89a86ad30000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000003b9aca000000000000000000000000000000000000000000000000000000000000000000",
 "borrow_executeUserOp_callData": "0x2b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc4600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000006489a86ad30000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
 "borrow_abi_encode_userOp": "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000221b34142f7d1c6761472130aa5652e731a2523700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001642b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc4600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000006489a86ad30000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000003b9aca000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
 "borrow_memo": "0xff0000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000221b34142f7d1c6761472130aa5652e731a2523700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001642b2ee7830000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000002529c6a1a0aaca615d1479ea24eb0710b9c3bc4600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000006489a86ad30000000000000000000000000b6a3645c240605887a5532109323a3e12273dc7000000000000000000000000000000000000000000000000000000003b9aca000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
 "borrow_memo_len": 842,
 "legacy_userOpHash": "0x7173736fbd34ee7b9696063e5f93a513648d991d1ef3540b523b73f88ac9fa50",
 "legacy_memo_42": "0xfe0000000000000f42407173736fbd34ee7b9696063e5f93a513648d991d1ef3540b523b73f88ac9fa50",
 "legacy_data_len": 1088
}
""")


def selftest() -> int:
    r = REFERENCE
    PA = "0x221B34142F7d1c6761472130AA5652e731a25237"
    AMOUNT, TIER, NONCE = 1_000_000_000, 0, 0

    got = build(PA, AMOUNT, TIER, NONCE)
    s_calls, b_calls = setup_calls(), borrow_calls(AMOUNT, TIER)
    s_cd, b_cd = encode_execute_user_op(s_calls), encode_execute_user_op(b_calls)
    legacy_calls = [(FXRP_COSTON2, 0, encode_approve(BOOK_COSTON2, AMOUNT)),
                    (BOOK_COSTON2, 0, encode_open(FXRP_COSTON2, AMOUNT, TIER))]
    legacy_data = encode_user_op(PA, NONCE, encode_execute_user_op(legacy_calls))

    checks = [
        # production 0xFF, step 1
        ("setup: approve calldata",       "0x" + s_calls[0][2].hex(),                r["setup_approve_calldata"]),
        ("setup: executeUserOp callData", "0x" + s_cd.hex(),                         r["setup_executeUserOp_callData"]),
        ("setup: abi.encode(userOp)",     "0x" + encode_user_op(PA, NONCE, s_cd).hex(), r["setup_abi_encode_userOp"]),
        ("setup: full 0xFF memo",         got["setup"]["memo_hex"],                  r["setup_memo"]),
        # production 0xFF, step 2
        ("borrow: open calldata",         "0x" + b_calls[0][2].hex(),                r["borrow_open_calldata"]),
        ("borrow: executeUserOp callData","0x" + b_cd.hex(),                         r["borrow_executeUserOp_callData"]),
        ("borrow: abi.encode(userOp)",    "0x" + encode_user_op(PA, NONCE + 1, b_cd).hex(), r["borrow_abi_encode_userOp"]),
        ("borrow: full 0xFF memo",        got["borrow"]["memo_hex"],                 r["borrow_memo"]),
        # legacy 0xFE
        ("legacy: userOpHash",            "0x" + keccak(legacy_data).hex(),          r["legacy_userOpHash"]),
        ("legacy: 42-byte memo",          "0x" + memo_fe(PA, NONCE, legacy_calls, 0, 1_000_000).hex(),
                                                                                     r["legacy_memo_42"]),
    ]

    bad = 0
    for name, a, b in checks:
        ok = a.lower() == b.lower()
        bad += 0 if ok else 1
        print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
        if not ok:
            # point at the first differing byte rather than dumping two 1,700-char strings
            x, y = a.lower(), b.lower()
            i = next((k for k in range(min(len(x), len(y))) if x[k] != y[k]), min(len(x), len(y)))
            print("      first difference at nibble %d (byte %d)" % (i, max(0, (i - 2) // 2)))
            print("      solidity: ...%s" % y[max(0, i - 20):i + 20])
            print("      python  : ...%s" % x[max(0, i - 20):i + 20])

    # lengths, asserted rather than reported, because the cap is what makes this design work
    for label, got_len, want_len in (
        ("setup memo is %d bytes" % r["setup_memo_len"],  got["setup"]["memo_len"],  r["setup_memo_len"]),
        ("borrow memo is %d bytes" % r["borrow_memo_len"], got["borrow"]["memo_len"], r["borrow_memo_len"]),
    ):
        ok = got_len == want_len
        bad += 0 if ok else 1
        print("  [%s] %s" % ("PASS" if ok else "FAIL", label))

    for label, n in (("setup", got["setup"]["memo_len"]), ("borrow", got["borrow"]["memo_len"])):
        ok = n <= XRPL_MEMO_CAP
        bad += 0 if ok else 1
        print("  [%s] %s memo fits the %d-byte XRPL cap (%d, %d to spare)"
              % ("PASS" if ok else "FAIL", label, XRPL_MEMO_CAP, n, XRPL_MEMO_CAP - n))

    # the nonces must differ by exactly one, in that order
    ok = got["borrow"]["nonce"] == got["setup"]["nonce"] + 1
    bad += 0 if ok else 1
    print("  [%s] borrow nonce is setup nonce + 1" % ("PASS" if ok else "FAIL"))

    # F1 regression: with the allowance already set there is no setup Payment to advance the nonce,
    # so the borrow must be signed for the CURRENT nonce, not nonce+1.
    skip = build(PA, AMOUNT, TIER, 7, needs_setup=False)
    ok = skip["borrow"]["nonce"] == 7 and "setup" not in skip
    bad += 0 if ok else 1
    print("  [%s] returning user (allowance set): borrow at the CURRENT nonce, no setup memo"
          % ("PASS" if ok else "FAIL"))

    # F2 regression: what goes in an XRPL Memo field must be bare hex. xrpl-py accepts a 0x prefix at
    # construction and only fails at serialization, so this is caught here instead of at submit time.
    md = got["borrow"]["memo_data"]
    ok = (not md.lower().startswith("0x")) and md == md.upper() and len(md) % 2 == 0
    try:
        bytes.fromhex(md)
    except ValueError:
        ok = False
    bad += 0 if ok else 1
    print("  [%s] memo_data is bare, even-length, uppercase hex (XRPL Memo ready)"
          % ("PASS" if ok else "FAIL"))
    ok = md.lower() == got["borrow"]["memo_hex"][2:].lower()
    bad += 0 if ok else 1
    print("  [%s] memo_data and memo_hex are the same bytes" % ("PASS" if ok else "FAIL"))

    print("  [INFO] legacy batched 0xFE _data is %d bytes, over the %d cap -- which is why the "
          "production shape splits" % (r["legacy_data_len"], XRPL_MEMO_CAP))
    print("\n%s" % ("ALL MATCH SOLIDITY" if bad == 0 else "%d MISMATCH(ES) - DO NOT USE" % bad))
    return 1 if bad else 0


# --------------------------------------------------------------------------- chain helpers

def _chain(rpc):
    from web3 import Web3
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
    mac = w3.eth.contract(
        address=to_checksum_address(MASTER_ACCOUNT_CONTROLLER),
        abi=[
            {"name": "getPersonalAccount", "type": "function", "stateMutability": "view",
             "inputs": [{"name": "_xrplOwner", "type": "string"}], "outputs": [{"type": "address"}]},
            {"name": "getNonce", "type": "function", "stateMutability": "view",
             "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
        ])
    erc20 = lambda addr: w3.eth.contract(address=to_checksum_address(addr), abi=[
        {"name": "balanceOf", "type": "function", "stateMutability": "view",
         "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
        {"name": "allowance", "type": "function", "stateMutability": "view",
         "inputs": [{"type": "address"}, {"type": "address"}], "outputs": [{"type": "uint256"}]},
    ])
    return w3, mac, erc20


def _minting_info(w3, asset_manager, max_agents=5):
    """Lot size and the agents a user can actually send XRP to, read from the AssetManager.

    Capped at `max_agents` so a busy network does not turn one CLI call into dozens of RPC round
    trips. The cap is REPORTED in the output rather than silently applied -- a truncated list that
    looks complete is how someone concludes there is no capacity when there is.
    """
    am = w3.eth.contract(address=to_checksum_address(asset_manager), abi=[
        {"name": "lotSize", "type": "function", "stateMutability": "view",
         "inputs": [], "outputs": [{"type": "uint256"}]},
        {"name": "assetMintingDecimals", "type": "function", "stateMutability": "view",
         "inputs": [], "outputs": [{"type": "uint8"}]},
        {"name": "getAvailableAgentsList", "type": "function", "stateMutability": "view",
         "inputs": [{"type": "uint256"}, {"type": "uint256"}],
         "outputs": [{"type": "address[]"}, {"type": "uint256"}]},
    ])
    lot = am.functions.lotSize().call()
    dec = am.functions.assetMintingDecimals().call()
    vaults, total = am.functions.getAvailableAgentsList(0, max_agents).call()

    agents = []
    for v in vaults:
        # getAgentInfo returns a large struct; call it raw and pull the checksum-valid XRPL address
        # rather than vendoring an ABI that can change under us.
        try:
            raw = w3.eth.call({"to": to_checksum_address(asset_manager),
                               "data": keccak(text="getAgentInfo(address)")[:4]
                                       + abi_encode(["address"], [v])})
            a = _xrpl_address_in(raw)
        except Exception:
            a = None
        agents.append({"agent_vault": v, "underlying_xrpl_address": a,
                       "usable": a is not None})
    return {
        "lot_size_units": lot, "asset_minting_decimals": dec,
        "lot_size_xrp": lot / (10 ** dec),
        "min_payment_xrp": lot / (10 ** dec),
        "payment_must_be_whole_lots": True,
        "agents_total_available": total,
        "agents_listed": len(agents),
        "agents_truncated": total > len(agents),
        "agents": agents,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest", help="diff every intermediate against the Solidity reference")

    for name, helptext in (("build", "build the two production memos for a real XRPL address"),
                           ("state", "read the personal account's live nonce, balance and allowance")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("--xrpl", required=True, help="XRPL classic address, e.g. rHb9...")
        p.add_argument("--rpc", default="https://coston2-api.flare.network/ext/C/rpc")
        p.add_argument("--book", default=BOOK_COSTON2)
        p.add_argument("--fxrp", default=FXRP_COSTON2)
        p.add_argument("--asset-manager", default=ASSET_MANAGER_FXRP_COSTON2)
        p.add_argument("--no-agents", action="store_true",
                       help="skip the agent lookup (fewer RPC calls, but no destination address)")
        if name == "build":
            p.add_argument("--amount", type=float, required=True,
                           help="FXRP to lock as collateral, human units")
            p.add_argument("--tier", type=int, default=0)

    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(selftest())

    # Derive the account and nonce from chain rather than guessing either.
    w3, mac, erc20 = _chain(a.rpc)
    pa = mac.functions.getPersonalAccount(a.xrpl).call()
    nonce = mac.functions.getNonce(pa).call()
    tok = erc20(a.fxrp)
    bal = tok.functions.balanceOf(pa).call()
    allow = tok.functions.allowance(pa, to_checksum_address(a.book)).call()

    if a.cmd == "state":
        st = {"xrpl_address": a.xrpl, "personal_account": pa, "chain_id": w3.eth.chain_id,
              "nonce": nonce, "fxrp_balance_6dp": bal, "fxrp_balance": bal / 1e6,
              "allowance_to_book": str(allow),
              "setup_already_done": allow == MAX_UINT256,
              "next_borrow_nonce": nonce if allow == MAX_UINT256 else nonce + 1}
        if not a.no_agents:
            st["where_to_send"] = _minting_info(w3, a.asset_manager)
        print(json.dumps(st, indent=2))
        return

    amount = int(round(a.amount * 1e6))
    # The allowance decides whether there IS a setup step, and therefore which nonce the borrow must
    # be signed for. Passing it in rather than warning about it afterwards is F1.
    out = build(pa, amount, a.tier, nonce, book=a.book, fxrp=a.fxrp,
                needs_setup=(allow != MAX_UINT256))
    out["xrpl_address"] = a.xrpl
    out["chain_id"] = w3.eth.chain_id
    out["fxrp_balance_now_6dp"] = bal
    out["setup_already_done"] = (allow == MAX_UINT256)
    if not a.no_agents:
        out["where_to_send"] = _minting_info(w3, a.asset_manager)

    # The borrow locks `amount`, which must be in the account WHEN THE BORROW EXECUTES -- that is the
    # balance now plus whatever the two Payments mint. Stated rather than silently assumed, because
    # an insufficient balance reverts on chain after the XRP is gone.
    out["warnings"] = []
    if out["setup_already_done"]:
        out["warnings"].append(
            "Allowance is already set, so there is no setup step. The single borrow memo above is "
            "already signed for the current nonce (%d) -- nothing to rebuild." % nonce)
    w = out.get("where_to_send")
    if w:
        if w["agents_truncated"]:
            out["warnings"].append(
                "Showing %d of %d available agents (capped to keep this to one quick call)."
                % (w["agents_listed"], w["agents_total_available"]))
        if not any(g["usable"] for g in w["agents"]):
            out["warnings"].append(
                "No agent returned a checksum-valid XRPL address. Do NOT guess a destination.")
        n_pay = 2 if out["setup_required"] else 1
        out["warnings"].append(
            "Every Payment must be a whole multiple of the %g XRP lot size, so this costs %d "
            "Payment(s) of at least %g XRP each. The XRP in the setup Payment is not lost: it mints "
            "FXRP into your personal account and the borrow can lock it."
            % (w["lot_size_xrp"], n_pay, w["lot_size_xrp"]))
    if bal < amount:
        out["warnings"].append(
            "The account holds %.6f FXRP now but the borrow locks %.6f. The shortfall must be "
            "covered by the FXRP these Payments mint, or the borrow reverts on chain."
            % (bal / 1e6, amount / 1e6))
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
