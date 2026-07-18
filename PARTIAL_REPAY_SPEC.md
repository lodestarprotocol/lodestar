# Partial Repay — design spec + invariants + adversarial test matrix

Status: **SPEC ONLY. No core code written yet.** This document is the surface review to sign off
before touching the immutable `LodestarLoanBook`. Scope: add `partialRepay`, skip position-NFT
(peripheral, later).

## 1. Motivation (what it must make better, nothing more)
1. Let a borrower pay down part of the principal **with cash they actually have** (full close +
   reopen is not available to a cash-short borrower, who is exactly the one who needs to de-risk).
2. Reduce and right-size outstanding debt so **default frequency and size drop** — a direct lender
   benefit in a no-liquidation book.
3. Optionally reclaim a **proportional, LTV-bounded** slice of collateral early.

## 2. Function surface

```solidity
/// @notice Pay down part of a loan's principal, optionally reclaiming a bounded slice of collateral.
/// @param id              loan id
/// @param repayAmount     stable to repay; 0 < repayAmount < principal (use repay() for the full close)
/// @param collateralOut   gross collateral to remove from the position (0 = pure paydown, no oracle needed)
/// @param tierIndex       tier whose LTV the REMAINING position must satisfy (only read if collateralOut > 0)
/// @param minCollateralReceived  slippage guard on the net collateral the borrower receives (after yield-skim)
function partialRepay(
    uint256 id,
    uint256 repayAmount,
    uint256 collateralOut,
    uint256 tierIndex,
    uint256 minCollateralReceived
) external nonReentrant;
```

Design choices baked into the signature:
- **`collateralOut == 0` is a first-class fast path**: no oracle read, no tier check. A borrower can
  always de-risk by paying down, even during an FTSO outage. Only *releasing* collateral needs a
  live price.
- Released collateral always goes to `L.borrower`, never `msg.sender` (a third party may pay down a
  loan; it can never strip the owner's collateral). Mirrors `repay`, where anyone may pay.
- The remaining position re-qualifies at a caller-chosen tier exactly like `rollover` — no worse than
  a fresh open at that tier (70% LTV hard ceiling still binds).

## 3. Ordering (CEI) — state flips before any transfer

Checks:
1. `L.active` else `NotActive`.
2. `repayAmount != 0 && repayAmount < L.principal` else `BadParam` (full close ⇒ `repay`).
3. `newPrincipal = L.principal - repayAmount; newPrincipal >= minPrincipal` else `BadParam` (no dust loans).
4. If `collateralOut > 0`:
   - `!isDefaulted(id)` else `NotYetDefaulted`-class revert (once in the settlement window collateral
     flows through settlement, never a strip). Pure paydown stays allowed post-default (cure path).
   - `tierIndex < tiers[collateral].length` else `BadTier`.
   - `collateralOut <= L.collAmount`.
   - LTV re-check at CURRENT price on the remainder (see §5).

Effects (storage):
5. `L.principal = newPrincipal`.
6. Exposure: `dExp = mulDiv(L.principalUsd18, repayAmount, oldPrincipal)` **rounded DOWN**;
   `exposureUsd18[collateral] -= dExp`; `L.principalUsd18 -= dExp`. (Remainder is cleared exactly at
   final close; sum over the lifecycle is exact, intermediate cap stays conservatively tight.)
7. Impairment true-up (realized-only, §4): `u = min(L.impairedLoss, repayAmount)`; if `u > 0`
   `pool.unimpair(u)`; `L.impairedLoss -= u`.
8. If `collateralOut > 0`: `L.collAmount -= collateralOut`.

Interactions (external, after all storage writes):
9. `pool.pull(msg.sender, repayAmount)` then `pool.onPrincipalReturned(repayAmount)`.
10. If `collateralOut > 0`: compute yield-skim on the released portion (§6), send `skim` to `reserve`
    and `collateralOut - skim` to `L.borrower`; require `collateralOut - skim >= minCollateralReceived`.

`nonReentrant` on the function; released collateral may be a hookable token, but every pool mutator is
`nonReentrant` and withdraw/redeem sync first, so a reentered exit cannot price against a transient state.

## 4. Impairment rule (the crux — must never understate)

`impairedLoss` is a **raise-only high-water mark**; the only sanctioned reduction paths are
`_clearImpairment` (at close) and settlement true-up. Partial repay adds one more sanctioned
reduction, and it is bounded to **realized cash only**:

> On partial repay the mark may fall by **at most `repayAmount`** (`u = min(L.impairedLoss, repayAmount)`),
> and it is **never recomputed from price/collateral**. No upward re-mark here — raising stays the job of
> `impair()` / `syncImpairment()`.

Why this is skim-proof and honest:
- The reduction is backed 1:1 by stable pulled into the pool, so `totalAssets` moves by exactly
  `+min(oldImpaired, repayAmount) >= 0` — up, and fully cash-backed. No unrealized recovery is ever
  credited, so the documented `deposit → (downward re-mark) → redeem` skim cannot be reconstructed
  through this path (an attacker pays `repayAmount` to move the mark by `<= repayAmount`, spread across
  all shares ⇒ strictly negative EV).
- If a collateral-release paydown leaves the loan genuinely healthy but the mark still carries a stale
  residual (because we refuse price-based downward marks), that residual only makes the share price
  **conservatively low** in the interim and is reversed in full by `_clearImpairment` at close. Safe
  direction. And any later crash is still caught by the raise-only `syncImpairment()` the pool runs
  before every exit, on the *new* (smaller principal, smaller collateral).

## 5. LTV re-check on collateral release (anti-strip)

Identical shape to `rollover`, applied to the **remaining** position at the **current** oracle price:

```
remColl   = L.collAmount - collateralOut
remValue18 = oracle.usdValue18(collateral, remColl)   // refreshes price cache like open/rollover
remPrincipalUsd18 = ceilDiv(newPrincipal * 1e18, stableUnit)   // round UP (require more collateral)
require( remValue18 * tiers[collateral][tierIndex].ltvBps / 10_000 >= remPrincipalUsd18 )
```

Consequences:
- An **underwater** loan can never release collateral (the inequality fails), so stripping value ahead
  of lenders is impossible.
- A healthy loan can release down to exactly the chosen tier's LTV — no more levered than a fresh open.
- `collateralOut == 0` skips this whole block (and the oracle), keeping paydown alive oracle-down.

## 6. Yield-skim on released collateral (no dodging)

Release must skim staking appreciation on the released portion, or a borrower could peel all collateral
via partial releases and dodge the skim that a full `repay` would take. Reuse the existing clamped
formula (20% appreciation cap, `skimBps` from the loan's snapshot) on `collateralOut`:

```
gain = collateralOut * (min(nowRate, 1.2*openRate) - openRate) / min(nowRate, 1.2*openRate)   // if nowRate>openRate
skim = gain * loanTerms[id].skimBps / 10_000
borrower receives collateralOut - skim ; reserve receives skim
```

Refactor `_returnCollateral` into an amount-parameterized helper so full `repay` (amount = collAmount)
and partial release (amount = collateralOut) share one audited path. Full-repay behavior is byte-identical
to today.

## 7. Rounding table (every tie favors the pool / lenders)

| Quantity | Direction | Why |
|---|---|---|
| exposure freed `dExp` | **down** | free less cap now; exact remainder cleared at close |
| `remPrincipalUsd18` in LTV check | **up** | require strictly more collateral to pass |
| impairment reduction `u` | exact `min()` | no rounding; realized-only |
| yield-skim `skim` | **down** on borrower's favor? | skim is a protocol take; round DOWN skim = borrower-favored, matches existing `_returnCollateral` clamp philosophy |
| principal `newPrincipal` | exact | `-= repayAmount` |

## 8. Invariants (the checklist the tests encode)

- **I1** principal: strictly `-= repayAmount`; `newPrincipal >= minPrincipal`; `repayAmount < oldPrincipal`.
- **I2** `principalOut`: `-= repayAmount` exactly; returns to baseline over open→partials→close.
- **I3** exposure: `exposureUsd18` and `L.principalUsd18` fall by the same `dExp`; full lifecycle nets to 0; never underflows (clamped).
- **I4** no strip: after any release, remainder satisfies tier LTV at current price; underwater ⇒ release reverts.
- **I5** no skim: `deposit → partialRepay → redeem` in one block is never profitable; mark never understated.
- **I6** share price: Δ`totalAssets` from partial repay `== +min(oldImpaired, repayAmount) >= 0`, fully cash-backed.
- **I7** custody: contract collateral balance falls by exactly `collateralOut`; borrower gets `collateralOut - skim`, reserve gets `skim`.
- **I8** skim not dodgeable: N partial releases skim the same total as one full repay of the same collateral.
- **I9** reentrancy: hookable collateral cannot re-enter an exit at a transient price.
- **I10** oracle-down liveness: `collateralOut == 0` works with the oracle reverting; release requires a live price.
- **I11** post-default: paydown allowed while active (cure); release reverts once defaulted.
- **I12** third party: a non-borrower payer can pay down; released collateral still goes to the borrower.

## 9. Adversarial test matrix (write RED first, against the signature above)

`test/security/LodestarPartialRepay.t.sol`

- **T1** paydown happy path (c=0): principal −r, collateral unchanged, pool +r, share price flat when healthy, later full repay returns all collateral.
- **T2** release happy path: pay r + release c passing LTV; borrower gets c−skim; remainder healthy; exposure −proportional.
- **T3** strip attack: release that leaves remainder under LTV ⇒ revert; any release on an underwater loan ⇒ revert.
- **T4** dust/bounds: `newPrincipal < minPrincipal` ⇒ revert; `r == principal` ⇒ revert; `r == 0` ⇒ revert.
- **T5** impairment skim: crash → `impair`; attacker deposits, `partialRepay`, `redeem`; assert net EV ≤ 0 and share value never exceeds honest.
- **T6** impairment true-up: impaired loan, `pool.impairedLoss` falls by exactly `min(oldImpaired, r)`; final `_clearImpairment` reverses the remainder with no underflow.
- **T7** exposure/cap: open to the cap, partial repay, assert freed `dExp` (floored), a new open uses exactly the freed cap, full close zeroes exposure.
- **T8** skim not dodgeable: appreciated LST, one full repay vs many partial releases skim the same total to reserve.
- **T9** oracle-down: paydown (c=0) succeeds with oracle reverting; release (c>0) reverts.
- **T10** post-default: after `dueAt+grace`, paydown succeeds, release reverts.
- **T11** reentrancy: malicious hookable collateral reentering `redeem` during release ⇒ blocked, accounting consistent.
- **T12** precision fuzz: random sequences of partial repays then close; `principalOut`, `exposureUsd18`, `impairedLoss`, collateral balance all return to baseline exactly (no drift, no underflow).
- **T13** third-party payer: non-borrower pays down; released collateral goes to borrower; payer cannot receive it.
- **T14** slippage guard: `minCollateralReceived` above the net (after skim) ⇒ revert.
- **T15** settlement race: partial repay then settle the remainder (buyout + settleSwap); totals reconcile, no double-release.

## 10. Explicitly out of scope for v1
- Position-NFT / transferable positions → peripheral `PositionManager` later, zero core change.
- Increasing principal (draw more) → not added; open a new loan.
- Changing `dueAt` on partial repay → time is untouched; extension stays `rollover`'s job.
```
