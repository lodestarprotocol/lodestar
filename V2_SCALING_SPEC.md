# V2 Scaling Spec — bucketed impairment accumulator (design, NOT yet implemented)

**Status: designed, deliberately not built in v1.8.** The v1.6 per-loan-mark design is
mainnet-final for launch. The cap (`maxActiveLoans = 300`, setter ceiling 400) binds only
beyond ~300-400 concurrent loans — with a $100 minPrincipal and launch caps, that is years of
growth away. The one prior attempt to remove the O(n) sweep (v1.7 "stateless impairment",
2026-07-17) was **rejected after a concrete landmine was found**: recomputing aggregate
impairment while dropping per-loan marks broke close-time reversal — settling a deeply
underwater loan reduced `principalOut` while a stale aggregate `impairedLoss` remained,
underflowing `totalAssets` (concrete: 2×40k loans @80% util, crash, buyout both →
36k + 0 − 64k < 0). Any v2 must carry that lesson: **per-loan (or per-bucket) contributions
must be exactly subtractable at close.**

## Why O(n) exists
Lender exits call `syncImpairmentForExit` → `_syncAll`, which re-marks every active loan at
the current price so no one redeems against a stale share price. Cost: O(active loans) per
exit, worst case ~20-25k gas/loan in a mass-crash (every mark writes). The cap keeps the
worst-case sweep under ~27% of Flare's 28M block gas limit.

## Design: per-collateral threshold buckets with subtractable sums
A loan's mark at whole-token price `P` is:

```
mark(P) = max(0, principalStable − P · effColl / unit)
effColl = collAmount · (10000 − keeperBps_frozen) / 10000   // precomputed at open
```

`mark(P) > 0` iff `P < T` where the loan's **threshold price** `T = principalStable · unit / effColl`.
So the aggregate over one collateral at price `P` is:

```
agg(P) = Σ_{loans: T > P} principalStable  −  (P / unit) · Σ_{loans: T > P} effColl
```

Maintain per collateral a fixed ladder of **log-spaced price ticks** (e.g. 256 ticks spanning
±99.9%/+1000% of a reference price, ~2.7% per tick). Each bucket `b` holds two sums:
`sumPrincipal[b]`, `sumEffColl[b]`. A loan lives in the bucket containing its `T`.

- **open**: compute `T`, add to its bucket's two sums — O(1).
- **close (repay / settle / partial)**: subtract its exact contribution from the same bucket
  (store the loan's bucket index + effColl at open; partialRepay recomputes T and MOVES the
  loan between buckets, still O(1)). This is the v1.7 landmine fix: contributions are always
  exactly reversible because they are stored per-loan and summed per-bucket.
- **sweep at price P**: walk buckets with tick > P, accumulate the two sums, compute `agg(P)`
  — O(#buckets) = O(256) regardless of loan count. With suffix sums maintained on write,
  O(log n) or O(1) reads are possible but not needed at Flare gas prices.
- **conservatism at bucket granularity**: treat every loan in a bucket as having that bucket's
  LOWER tick as its threshold? No — use the UPPER tick edge, which over-marks by ≤ one tick
  width (~2.7%): conservative for lenders (share price marginally low), never optimistic.
  Exact truth restored per-loan at settlement (`_distribute` true-up), same as v1.6.

## Invariants that must survive (port the existing campaigns)
1. `totalAssets` never underflows: `impairedLoss ≤ principalOut` at all times, including
   immediately after any settle/buyout of the most-underwater loan (the v1.7 killer).
2. Raise-only between closes at a fixed price set (anti-skim: deposit → mark-recovered →
   redeem must remain unprofitable). Note: with an aggregate recompute, a PRICE RISE lowers
   `agg(P)` mid-life — v1.6 forbids that per-loan (raise-only high-water). v2 must either
   (a) keep a raise-only high-water on the AGGREGATE per collateral, reversed only by closes
   (preserves v1.6 economics exactly), or (b) prove the deposit-before-recovery skim is
   closed by the deposit-time sweep alone. **Default to (a); (b) needs its own adversarial
   round.**
3. Close-time exact reversal: settle/repay of loan i changes the aggregate by exactly
   −contribution(i) (fuzz: open/close random sequences net to zero drift).
4. Sweep gas at 400/1000/4096 loans ≤ a few hundred k (measure; the cap can then rise 10x+).

## Migration & effort
New `ImpairmentLadder` library + LoanBook wiring (open/close/partial/sweep call sites),
per-loan `bucketIdx`/`effColl` fields, ~30 targeted tests + ported invariant handlers
(Stress + Invariant + Sflr 18dp + econ games, 512k-call campaigns) + 2 adversarial review
rounds minimum. This is a dedicated multi-session effort and MUST be re-audited — do not
slip it into a release. Trigger to build: sustained active-loan count > 200 (alert in
monitor.py) or a decision to raise `maxActiveLoans` beyond 400.
