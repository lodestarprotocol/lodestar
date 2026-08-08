# Lodestar — audit scope

**Commit: `d242c6b` — `Remove the slot-premium ramp; pin the launch config in the deploy script`**
Repo: `github.com/lodestarprotocol/lodestar`, branch `main`. Prepared 2026-08-06, re-pinned 2026-08-08.

> **The hash moved because history was rewritten on 2026-08-08.** A launch runbook had been committed
> to this public repo and was purged from all 169 commits with git-filter-repo, so every SHA quoted in
> any earlier copy of this document is gone. The CONTRACTS are byte-identical -- verified by hashing
> src/ against a pre-rewrite mirror -- and the suite is unchanged at 262 non-fork tests, 0 failures.

The pin refers to the state of `src/`. Later commits on `main` may touch this document, the dapp
or tests without changing `src/`; verify with `git diff d242c6b..main -- src/`, which must be
empty. Reviewing `main` at or after `d242c6b` therefore reviews the same contracts.

This supersedes `43ee872`, `1a66b01`, `c0fc6b1a` and `e0ac90e`. Two Solidity deltas since
`1a66b01`, both in `LodestarLoanBook.sol` and both described below: the first-loss buffer (§4) and
the `open()` slippage bound and deadline (§4b). Everything else in the intervening commits is dapp,
docs, tools or tests.

> **If you are comparing against an earlier draft of this document.** Commits `e0ac90e`, `a878a31`
> and `6d2b67a` added a *slot-exhaustion premium* — a `minPrincipal` that ramped quadratically with
> book fullness — and then two corrections to it. **All of it has been removed.** There is no
> `slotPremiumBps`, no `effectiveMinPrincipal()` and no `openFloor` in the code under review, and
> the section that described them is deliberately gone rather than marked obsolete.
>
> It was withdrawn on three grounds: the threat is unreachable at launch (the $25k per-collateral
> exposure cap runs out after ~250 loans of $100, before the 400-slot ceiling — asserted in
> `test/LaunchConfig.t.sol`); being quadratic in fullness, the floor had already doubled *for every
> borrower* at one third occupancy, which made pricing out small borrowers cheaper rather than
> dearer; and two independent review passes each found a way around a version we believed correct
> (a `partialRepay` claw-back that made the premium refundable, then a fix for that which trapped
> honest borrowers). `minPrincipal` is flat again, and slot exhaustion is priced by
> `minPrincipal * maxActiveLoans` of the griefer's own over-collateralized capital, locked for the
> term, with `setMinPrincipal` (bounded to $10k) as the reactive lever.

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
| `src/LodestarLoanBook.sol` | 1,144 | **726** |
| `src/LodestarOracle.sol` | 231 | 127 |
| `src/LodestarPool.sol` | 185 | 117 |
| `src/flare/FirelightRateAdapter.sol` | 37 | 22 |
| `src/flare/FlareAddresses.sol` | 31 | 15 |
| `src/flare/SceptreRateAdapter.sol` | 24 | 15 |
| `src/interfaces/*.sol` (3 files) | 32 | 18 |
| **Total** | **1,685** | **1,040** |

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

## 4b. Delta since `c0fc6b1a` — a slippage bound and a deadline on `open()`

**Solidity: 51 insertions, 2 deletions, entirely in `LodestarLoanBook.sol`.** Everything else in the
intervening commits is dapp, docs, tools or tests.

`open()` previously had neither, so the terms of a borrow were decided entirely at execution time by
whoever submitted the transaction: collateral is priced at the FTSOv2 reading at the moment of
inclusion. For a wallet user clicking Borrow that window is seconds. For the XRPL flow — where a
user signs an XRPL payment and an executor relays it to Flare whenever it suits them — it is
unbounded, and a submitter can wait for a local low and underwrite the loan smaller. There is no
direct profit in doing so, which makes it griefing rather than theft, but *"you know your terms up
front"* is a core claim of this protocol and without these it was not true.

```solidity
function open(address collateral, uint256 collAmount, uint256 tierIndex)
    external nonReentrant returns (uint256 id)
{
    return _open(collateral, collAmount, tierIndex);
}

function open(
    address collateral, uint256 collAmount, uint256 tierIndex,
    uint256 minOut, uint256 deadline
) external nonReentrant returns (uint256 id) {
    if (deadline != 0 && block.timestamp > deadline) revert Expired();
    id = _open(collateral, collAmount, tierIndex);
    if (minOut != 0) {
        Loan storage L = loans[id];
        if (uint256(L.principal) - uint256(L.fee) < minOut) revert Slippage();
    }
}
```

Properties worth checking:

- **The 3-argument form is preserved verbatim** and delegates with both guards disabled, so every
  existing caller behaves exactly as before. `0` means unconstrained for both parameters, which is
  what makes that delegation exact. `test_ThreeArgFormIsIdenticalToUnconstrainedFiveArg`.
- **`minOut` is measured on what the borrower RECEIVES** (`principal - fee`), not on `principal`.
  Binding it to principal would silently under-protect by the fee.
  `test_MinOutIsMeasuredOnReceivedNotPrincipal`.
- **`minOut` is checked *after* `_open` rather than before.** Reverting unwinds the whole call, so
  this is equivalent to checking before — and it keeps `_open`'s body and stack profile byte-for-byte
  what they were. This contract is compiled **without via-IR by choice**; one more local in `_open`
  overflows the stack. Same reason `deadline` is checked in the wrapper.
- **Both externals are `nonReentrant` and share one internal body.** If one delegated to the other
  the guard would re-enter and every call would revert. `test_BothEntrypointsWorkBackToBack`.
- **The deadline is `>` not `>=`**, so a borrow included in the very block the user nominated is
  honoured. `test_DeadlineExactlyNowIsAccepted`.

11 tests in `test/security/OpenGuards.t.sol`, including
`test_PriceDropBetweenQuoteAndExecutionIsRefused` (the actual scenario) and
`test_MinOutOneWeiAboveReceivedReverts` (the boundary).

*Deploy-script changes, out of scope, listed for completeness:* `DeployMainnet` now sets
`maxActiveLoans` to 400 explicitly (the constructor default is 300), sets the published risk numbers
explicitly rather than inheriting constructor defaults, and calls `setPaused(true)` before the
multisig handover. `test/LaunchConfig.t.sol` pins those constants.

---


## 5. Tests

**262 non-fork tests, 0 failures** (verified 2026-08-08 at `d242c6b`). 244 at `c0fc6b1a`; since then
+11 in `test/security/OpenGuards.t.sol` (§4b), +3 in `test/LaunchConfig.t.sol`, +3 in
`test/XrplMemoReference.t.sol` (out-of-scope tooling) and +1 gas-ceiling measurement in
`test/SweepGasCeiling.t.sol` — the ~9.9M-gas mass-crash exit sweep that justifies capping
`maxActiveLoans` at 400. Plus **19 fork tests** against live Flare and Coston2 state (one heavy
Algebra 2-hop test is gated behind `HEAVY_FORK=1`; it 429s on public RPCs). Those include the XRPL
borrow flow driven through Flare's real deployed Smart Accounts controller
(`test/fork/SmartAccountBorrow.t.sol`, `test/fork/XrplEndToEnd.t.sol`) and a 400-loan exit-sweep
ceiling measurement (`test/fork/ActiveLoanCeiling.t.sol`).

Four invariant campaigns run **128,000 calls each with 0 reverts**, covering system solvency,
`totalAssets` underflow, no-free-value-extraction, no-double-resolution, custody of collateral and
stable, the active-loan array, and `reserveFloor <= reserveBalance`.

```
forge test --no-match-path "test/fork/*"        # 262 pass
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
