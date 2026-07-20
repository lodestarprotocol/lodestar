# Lodestar Protocol - Pre-Audit AI Review Addendum

**Date:** 2026-07-20
**Codebase:** `src/` (LodestarLoanBook, LodestarPool, LodestarOracle, `src/flare/` adapters)
**Method:** Pashov Audit Group `solidity-auditor` skill (github.com/pashov/skills, v3) — 12 independent adversarial agents across math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles, asymmetry, boundary, and three gap-hunters. Every candidate was then verified against source before action.

This addendum records an AI-assisted pass run **before** the external engagement, on the principle that the auditor's own checklist should kill the cheap findings for free so the paid review spends its budget on the deep bugs. It is filed alongside the main report (`LODESTAR_AUDIT_REPORT.md`).

---

## 1. Result summary

**No Critical, no High.** One real unprivileged Low/Medium (rollover authorization), a set of owner-gated / config / hygiene Lows, and a batch of agent claims that did **not** survive source review (documented in Section 4 so they are not re-investigated).

All confirmed items were **fixed and regression-tested** in the same pass. Full suite after fixes: **green** (see Section 5).

---

## 2. Confirmed findings — fixed

### F1 (Low/Med, unprivileged) — `rollover` had no borrower authorization
`rollover(id, tierIndex)` had no `msg.sender == L.borrower` check. Because a rollover both extends the deadline and overwrites `openLtvBps[id]` (the loan's binding LTV for later partial-release), and because `newDue = block.timestamp + tier.duration` is only bounded from above, a third party could pay the fee to roll another borrower's healthy loan into a **shorter-duration tier**, moving their deadline closer to default, or flip their LTV standard — all without consent. Griefing (attacker burns the fee), but an unauthorized adverse mutation of another user's position.

**Fix:** added `if (msg.sender != L.borrower) revert NotBorrower();`. A borrower choosing a shorter tier for their *own* loan is their prerogative, so no separate anti-shorten guard is added (an early draft of that guard was a false positive — it broke legitimate same-tier rollovers where `newDue == dueAt`, and was removed).
**Tests:** `test_Rollover_OnlyBorrowerCanRoll`, `test_Rollover_BorrowerStillWorks`.

### F2 (Low, owner-gated) — `withdrawReserve` used a best-effort sweep during an outage
`withdrawReserve` called the best-effort `_syncAll()`, which silently skips loans it can't price. During an FTSO outage combined with a crash, un-priceable underwater loans stay unmarked, so `pool.impairedLoss()` (the earmark) understates the true first-loss the buffer must cover — letting a hasty/compromised owner drain it below reality.

**Fix:** `withdrawReserve` now uses the **strict** sweep (`if (!_syncAll()) revert OracleDown();`), mirroring the lender-exit path. It refuses to release the buffer until every active loan can be freshly priced.
**Test:** `test_WithdrawReserve_RefusesDuringOutage`.

### F3 (Low, config-gated) — `_floorStable` fallback ignored the current Dutch position
In the oracle-down fallback, the floor was computed from `settleFloorMinBps` regardless of where the Dutch curve actually was (`floorBps`). With launch config (fallback delay 7d ≫ decay 24h) the curve has already decayed to its minimum by fallback time, so it was a no-op — but under a `oracleFallbackDelay < settleDecayPeriod` misconfiguration the floor would jump below the level the live path would give at the same instant.

**Fix:** the fallback now applies the loan's current Dutch `floorBps` to the cached price (then decays over the outage as before), keeping the two paths consistent regardless of parameter choices. The now-unused `floorMinBps` parameter was dropped from `_floorStable`.

### F4 (Low, owner-gated) — `penaltyBps` / `keeperBps` were live, not snapshotted
The `LoanTerms` freeze at open covered grace / curve / skim but **not** `penaltyBps` (reserve cut in `_distribute`) or `keeperBps` (settle bounty + impairment recovery haircut). A compromised owner could raise either between open and settlement to enlarge the cut carved from an open loan's surplus.

**Fix:** both are now snapshotted into `LoanTerms` at open (one packed slot, 176 bits) and read from the frozen value in `_distribute`, `_markLoanRaise`, and `_bountyAmount`. `keeperCapUsd18` intentionally stays live — it only ever *caps* the bounty lower.
**Tests:** `test_PenaltyBps_FrozenAtOpen`, `test_KeeperBps_FrozenAtOpen`.

### F5 (Low / hygiene) — three defensive items
- **`buyoutCost` callable on a live loan** (state-mutating, caches price): now gated on `isDefaulted` like `buyout`. Test: `test_BuyoutCost_RevertsBeforeDefault`.
- **`oracle.rateOf` had no try/catch** in `_returnCollateralPortion`: a paused LST rate provider could brick `repay`/collateral-release when `skimBps > 0` (0 at launch). Now wrapped; on revert the skim is skipped (favours the borrower) and collateral is returned. Test: `test_RateProviderRevert_RepayStillReturnsCollateral`.
- **ERC4626 `maxWithdraw`/`maxRedeem` non-compliance**: during an outage they returned a non-zero amount while the real `withdraw`/`redeem` reverts `OracleDown`. Added a read-only `oracleReady()` view on the book; the pool's `max*` now return 0 when the book can't be freshly priced. Test: `test_MaxWithdrawAndRedeem_ZeroDuringOutage`.

---

## 3. Confirmed but intentionally NOT changed

- **`partialRepay` allows a pure paydown (`collateralOut == 0`) on a defaulted loan.** Flagged as a branch-asymmetry / penalty-avoidance path. Left as-is: it is documented, intentional (a de-risk is never blocked), and the "penalty avoidance" is dominated by `repay()`, which carries no penalty at all — so no rational borrower runs the described maneuver. No security impact.

---

## 4. Refuted — agent claims that did NOT survive source review

Recorded so they are not re-investigated:

- **"settleSwap lets a keeper settle at a discount during oracle staleness."** Refuted: a stale feed makes `_floorStable` revert `OracleDown` for the whole fallback window (`block.timestamp <= dueAt + oracleFallbackDelay`), so `settleSwap` cannot execute at a discount. The `fairMin`-skip only coincides with the regime where settlement is already blocked or legitimately at the decayed cached floor.
- **"Stale cached price grants an unearned keeper bounty."** Refuted (several agents self-refuted mid-trace): the bounty gate + `_settlementFloor` live-oracle check + `BelowFloor` revert catch it; a real crash makes the swap revert rather than pay.
- **"Free collateral when the Dutch floor decays to zero."** Refuted: the fallback pins a 20% floor and `lastPrice18` is never zero after open.
- **`totalAssets` underflow / deposit→impair→redeem skim / router reentrancy / `pool.payout(rcut)` liquidity failure.** All refuted in-trace: `impairedLoss ≤ principalOut` holds by construction; raise-only marks + `nonReentrant` seal the skim; the 80% utilization cap guarantees the rcut buffer.
- **"partialRepay penalty-bypass nets the borrower a gain."** Downgraded: dominated by `repay()` (zero penalty); not profitable.
- Assorted dust/precision items (skim truncation for sub-unit amounts, exposure drift ≤ N wei, staleness `>` vs `>=` boundary, `_to18` range) — negligible / informational, no action.

---

## 5. Verification

- Full non-fork suite after fixes: **green** (unit + adversarial + invariant campaigns of 128k+ calls each + economic-game suites). 8 new regression tests added in `test/security/LodestarPreauditFixes.t.sol`, all passing.
- The 3 existing tests that briefly failed during development were the false-positive anti-shorten guard breaking legitimate same-tier rollovers; the guard was removed and all pass.
- Reproduce: `cd belay && forge test --no-match-path "test/fork/*"`.

## 6. Note on scope

These fixes touch `src/` (immutable core, not yet on mainnet), so they land before deployment rather than as a mainnet upgrade. If the external scope commit was already pinned, it must be re-pinned to include these changes.

*Filed 2026-07-20. Contact: dev@lodestarprotocol.xyz.*
