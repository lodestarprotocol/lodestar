# Lodestar — audit scope

**Commit: `c0fc6b1a` — `Let anyone put capital in front of the lenders, and stop the owner taking it back`**
Repo: `github.com/lodestarprotocol/lodestar`, branch `main`. Prepared 2026-08-06.

This supersedes the two hashes previously discussed, `43ee872` and `1a66b01`. The delta from
`1a66b01` is **36 added lines and 1 changed line in one file** — see §4.

---

## 1. What it is

No-liquidation fixed-term lending on Flare. Lock yield-bearing collateral (FXRP, sFLR, stXRP),
borrow USD₮0 at a tier LTV, repay by a deadline.

**There is no liquidation price.** Only the deadline can end a loan. On default (deadline + 48h
grace) anyone may settle: collateral is sold behind a Dutch floor that decays from 100% to 85% of
the FTSOv2 oracle price over 24h, lenders are made whole first, and any surplus — including LST
staking yield earned during the term — goes back to the borrower.

Fee-only, no protocol token. Core is immutable: `Ownable2Step` + `ReentrancyGuard`, no proxy, no
upgrade path.

---

## 2. In scope

| File | Lines | SLOC |
|---|---|---|
| `src/LodestarLoanBook.sol` | 1,103 | **712** |
| `src/LodestarOracle.sol` | 231 | 127 |
| `src/LodestarPool.sol` | 185 | 117 |
| `src/flare/FirelightRateAdapter.sol` | 37 | 22 |
| `src/flare/FlareAddresses.sol` | 31 | 15 |
| `src/flare/SceptreRateAdapter.sol` | 24 | 15 |
| `src/interfaces/*.sol` (3 files) | 32 | 18 |
| **Total** | **1,644** | **1,026** |

Solidity 0.8.28, OpenZeppelin 5.1.0, Foundry.

Out of scope: `web/` (the dapp), `webapp/`, `script/`, `quest/`, `test/`, and the off-repo keeper
bot. No changes are planned to the in-scope files before the engagement starts.

---

## 3. Architecture

**`LodestarLoanBook`** — origination, repayment, partial repayment, rollover, default settlement,
the first-loss buffer. Holds all collateral.

**`LodestarPool`** — ERC-4626 over USD₮0. Lenders deposit, receive `lodUSD₮0`. Deposits and
withdrawals force an impairment sweep before pricing shares, so nobody can exit at a stale-high
share price. `maxWithdraw`/`maxRedeem` clamp to idle liquidity.

**`LodestarOracle`** — prices collateral off Flare's enshrined FTSOv2, with a per-collateral
haircut, a mandatory staleness bound, and a rate clamp on LST rate providers bounded to a fixed arm
epoch.

**Adapters** — sFLR and stXRP are LST wrappers whose rate providers do not share an interface;
these normalise them.

---

## 4. Delta since `1a66b01` (the hash previously discussed)

**Solidity: 36 insertions, 1 deletion, entirely in `LodestarLoanBook.sol`.** Everything else in the
18 intervening commits is dapp, docs or tests.

The change adds `fundReserve()` and `reserveFloor`:

- `fundReserve(uint256)` — permissionless. Anyone may add stable to the first-loss buffer. Credits
  the **balance delta**, not `amount`, so a fee-on-transfer stable cannot credit more than arrived.
  `nonReentrant` is load-bearing rather than defensive: `_swapViaRouter` measures settlement
  proceeds as a stable balance delta, so a router callback funding the reserve inside that window
  would double-count the same stable and break `stable.balanceOf(book) == reserveBalance`.
- `withdrawReserve` now floors at `pool.impairedLoss() + reserveFloor`, so the owner cannot withdraw
  contributed capital back out.
- `_distribute` clamps `reserveFloor` down to `reserveBalance` when the buffer absorbs a loss, so
  contributed capital is consumed first and `reserveFloor <= reserveBalance` always holds. Fee
  income that rebuilds the buffer afterwards is protocol surplus and stays withdrawable.

**Why it exists:** before this, nobody — including us — could subordinate capital ahead of lenders.
The buffer only grew from fee cuts and from a default penalty that is only collected when the loan
was already solvent, i.e. exactly when the buffer was not needed.

---

## 5. Tests

**244 non-fork tests, 0 failures.** Plus 10 fork tests against live Flare mainnet state (one heavy
Algebra 2-hop test is gated behind `HEAVY_FORK=1`; it 429s on public RPCs).

Four invariant campaigns run **128,000 calls each with 0 reverts**, covering system solvency,
`totalAssets` underflow, no-free-value-extraction, no-double-resolution, custody of collateral and
stable, the active-loan array, and `reserveFloor <= reserveBalance`.

```
forge test --no-match-path "test/fork/*"        # 244 pass
FORK_RPC=<flare rpc> forge test --match-path "test/fork/*"
```

---

## 6. Where we would focus a reviewer

Not a list of known issues — these are the areas where we think the consequences of a mistake are
worst, in rough order.

1. **Settlement waterfall and the Dutch floor** (`settleSwap`, `buyout`, `_distribute`). Router
   calldata is caller-supplied; the defences are a router allowlist, an exact-collateral-delta
   check, a proceeds sanity ceiling, and a floor check. Keeper bounty is zero when the loan is
   underwater and zero on self-settle.
2. **Impairment accounting.** Per-loan marks are raise-only mid-life and reverse only at close. A
   stateless recompute design was evaluated and rejected because settling a deeply underwater loan
   left a stale mark and underflowed `totalAssets`.
3. **The `reserveFloor` change in §4** — newest code, least exposure.
4. **Oracle rate clamp** on LST providers, particularly the arm-epoch bound on cumulative drift.
5. **The sweep-gas bound.** `maxActiveLoans` (400 hard ceiling) exists so a withdrawal can never be
   gas-bricked by the impairment sweep.
6. **Per-loan term snapshots.** `loanTerms[id]` freezes LTV, fee, penalty, keeper bps, grace and the
   settle curve at open, so no owner parameter change can retroactively alter an open loan.

---

## 7. Prior work

Eight internal adversarial rounds, including a run of your own `solidity-auditor` skill before this
engagement. Findings and adjudications, including refuted candidates with reasoning, are in
`audit/PREAUDIT_FINDINGS_ADDENDUM.md` and `audit/LODESTAR_AUDIT_REPORT.md`.

The one unprivileged bug found in that process: `rollover` was callable by any address, letting a
third party roll another user's loan into a different tier. Fixed and regression-tested.

---

## 8. Live deployment

Coston2 testnet, v1.7, ~11 weeks of continuous operation: **3,690+ loans written, 2,500+ lenders,
0 lender losses, share price 1.171**. Default settlement has executed on live contracts many times,
including a deliberate underwater fire-drill on a throwaway instance that exercised impairment
marking, share-price markdown, a marked-down lender exit, and the reserve-first waterfall.

Mainnet is not deployed. Remaining blockers are operational: this audit, then a 3-of-5 Safe with
hardware keys, then deploy. Governance is multisig-only by deliberate choice — no timelock, because
a timelock would cripple emergency `setPaused` while the per-loan term snapshot already prevents
retroactive changes to open loans.
