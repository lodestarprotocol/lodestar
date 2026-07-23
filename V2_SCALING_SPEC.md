# V2 Scaling Spec — bucketed impairment accumulator (design, NOT yet implemented)

**Status: designed + adversarially reviewed (2026-07-23), deliberately not built in v1.8.** The
v1.6 per-loan-mark design is mainnet-final for launch. The cap (`maxActiveLoans = 300`, setter
ceiling 400) binds only beyond ~300-400 concurrent loans — with a $100 minPrincipal and launch
caps, that is years of growth away. The one prior attempt to remove the O(n) sweep (v1.7
"stateless impairment", 2026-07-17) was **rejected after a concrete landmine was found**, and the
adversarial review of THIS spec's first draft found the same landmine class hiding in its own
"option (a)" (see Refuted below). Trigger to build: sustained active-loan count > 200 (alert in
monitor.py) or a decision to raise `maxActiveLoans` beyond 400. Budget: dedicated multi-session
effort + full invariant campaigns + re-audit.

## Why O(n) exists
Lender exits call `syncImpairmentForExit` → `_syncAll`, which re-marks every active loan at the
current price so no one redeems against a stale share price. Cost: O(active loans) per exit,
worst case ~20-25k gas/loan in a mass-crash. The cap keeps the worst-case sweep under ~27% of
Flare's 28M block gas limit.

## Core decomposition (unit-pinned)
Per `_markLoanRaise`, a loan's mark at whole-token price `price18` (1e18 USD) is, in stable units:

```
markStable(price18) = max(0, principalStable − price18 · effColl · stableUnit / (unit · 1e18))
effColl             = collAmount · (10000 − keeperBps_frozen) / 10000     // frozen at open
```

The mark hits zero at the threshold price
`T18 = principalStable · unit · 1e18 / (effColl · stableUnit)` (1e18 USD scale — NOTE the
explicit `1e18/stableUnit` factor; dropping it is a silent 1e12 bug for a 6dp stable).
Aggregate over one collateral at price `P18`:

```
aggStable(P18) = Σ_{loans: T18 > P18} principalStable
               − (P18 · stableUnit / (unit · 1e18)) · Σ_{loans: T18 > P18} effColl
```

## Bucketing
Per collateral, a fixed ladder of **log-spaced price ticks**. Sizing note: 256 ticks over a
`0.001x … 11x` span is ~3.7%/tick (11,000^(1/256)); ~345 ticks are needed for ~2.7%. Pick span
and count per collateral asset class; the conservatism bound below is "one tick width".
Each bucket holds `sumPrincipal[b]` and `sumEffColl[b]`. A loan lives in the bucket containing
its `T18`.

- **open**: compute `T18`, add both sums — O(1). Store `bucketIdx` + `effColl` on the loan.
- **close (repay / settle / buyout)**: subtract the loan's stored contribution — O(1).
- **partialRepay AND addCollateral**: BOTH mutate principal and/or collAmount, so both recompute
  `T18` and MOVE the loan between buckets (subtract old contribution, add new) — O(1). The first
  draft omitted addCollateral; that omission breaks exact subtraction.
- **sweep at price P18**: snap the sweep price DOWN to the nearest tick edge `P↓ ≤ P18`, include
  every bucket strictly above `P↓`, and evaluate the linear form at `P↓`. Evaluating at the true
  `P18` while including the straddling bucket UNDER-marks (loans with `T ≤ P < upperTick`
  contribute negatively and offset genuine marks — optimistic, the phantom-solvency direction).
  With `P↓`-snapping every per-loan term ≥ its true mark and the over-mark is ≤ one tick width
  per loan: conservative, never optimistic.
- Complexity: O(#buckets) per sweep with plain iteration. (Plain suffix sums cost O(#buckets)
  per WRITE; a Fenwick tree gives O(log #buckets) both sides — only worth it if #buckets grows.)

## REFUTED: aggregate raise-only high-water ("option a" of the first draft)
A raise-only high-water on the AGGREGATE is **structurally incompatible** with per-bucket
subtraction. Failure sequence (found in adversarial review): two 40k loans mark 32k each in a
crash (aggregate high-water 64k) → price fully recovers (raise-only holds 64k) → both loans
repay; each loan's "current-price contribution" is 0, so nothing is subtracted →
`impairedLoss = 64k` with `principalOut = 0`: invariant 1 violated with NO attacker, and 64k of
real lender stable is stranded forever (`totalAssets` permanently understated; `unimpair` is
onlyLoanBook and no live loan carries the mark). The only escape — per-loan struck marks — is
exactly v1.6, and re-raising them each sweep is O(n) writes again.

**Therefore v2 must be a pure recompute (old "option b")**: `impairedLoss` per collateral is
recomputed from the buckets at each sweep (deposit AND exit both sync-before-price, as the pool
already does). The anti-skim property (v1.6's per-loan raise-only) must then be re-established
by the sync-before-price discipline alone: deposit → the deposit-time sweep re-marks at current
price BEFORE shares are minted; recovery → the next sweep lowers the aggregate for EVERYONE
symmetrically (no single actor can time it against the others because every entry/exit resyncs
first). This claim is plausible but NOT proven — it needs its own dedicated adversarial round
with the deposit→recover→redeem game replayed against the recompute semantics. That open
question is the main reason v2 is not a drop-in.

## Oracle-down close (the v1.7 class re-enters through this door)
`buyout` deliberately settles during an FTSO outage (cached-price fallback past
`oracleFallbackDelay`). v1.6 survives because `_clearImpairment` reverses the STORED per-loan
mark without needing a price. A recompute design cannot re-derive the aggregate at close with
the oracle down. v2 requirement: on close during oracle-down, subtract the loan's LAST-KNOWN
bucket contribution (stored `bucketIdx`/`effColl`/`principal` — price-free) and flag the
collateral for a full re-bucket sweep at the next live price. Never leave a closed loan's
contribution in the sums.

## Invariants that must survive (port the existing campaigns)
1. `impairedLoss ≤ principalOut` at all times, including immediately after settle/buyout of the
   most-underwater loan, and through the buyout path's exact ordering (clear BEFORE
   `onPrincipalReturned`).
2. Anti-skim: deposit → impair-recovered → redeem never profits (see the open question above).
3. Close-time exact reversal: open/close random sequences net the sums to zero drift (fuzz),
   including partialRepay and addCollateral moves.
4. Sweep gas at 400/1000/4096 loans measured; only then may `maxActiveLoans` rise.
