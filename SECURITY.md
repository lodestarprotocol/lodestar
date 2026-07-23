# Lodestar — Security Model

Lodestar is fixed-term, no-liquidation lending on Flare. Lock yield-bearing collateral
(FXRP, sFLR) → borrow USDT0 at a tier LTV → repay by a deadline. Only the calendar can
default you; price never liquidates. This file maps each known bug-class to its defense.

## Architecture (custody & trust)

| Contract | Role | Mutability |
|----------|------|-----------|
| `LodestarPool` (ERC4626) | Holds all lender USDT0; tracks `principalOut` | Wiring immutable; `maxUtilization` owner-set |
| `LodestarLoanBook` | Loan lifecycle, collateral custody, settlement | Wiring immutable; risk params owner-set |
| `LodestarOracle` | FTSOv2 USD valuation of collateral | Feeds owner-set |

Only `LodestarLoanBook` can move pool funds (`onlyLoanBook`). `setLoanBook` is one-shot.

## Bug-class → defense

| Class | Defense |
|-------|---------|
| **Reentrancy** | `nonReentrant` on every state-changing external fn. CEI: `active=false` and exposure reduced *before* any external transfer/swap in `repay`/`settle`. |
| **Oracle manipulation** | Prices come from Flare's **enshrined FTSOv2**, not DEX spot/TWAP that flash loans can bend. Staleness guard (`maxStale`) per feed. Settlement is floored by a **descending FTSO-anchored curve** (100% at default decaying to 85% over 24h) so a keeper can neither underprice a fresh default nor be blocked forever in a crash. |
| **Price-liquidation griefing** | No price-based liquidation exists. `settle` reverts (`NotYetDefaulted`) until `dueAt + gracePeriod`. |
| **ERC4626 inflation / first-depositor** | OZ v5 ERC4626 virtual-shares mitigation. Deploy playbook seeds a small first deposit from the deployer and burns it. |
| **Bad debt / shortfall** | Conservative LTV caps (≤90% enforced, FXRP 50% / sFLR 60% at launch), per-collateral `exposureCap`, and pool `maxUtilization` (80%). Any settlement shortfall is realized transparently via the ERC4626 share price (socialized to lenders), never hidden. |
| **Keeper extraction** | Bounty `keeperBps` (5%) in-kind, **USD-capped** (`keeperCapUsd18`, default $500) and **zeroed when the borrower self-settles**; sale floored by the Dutch curve; permissionless so no single keeper is privileged. |
| **Access control** | Pool fund-movement gated to LoanBook. Param setters `onlyOwner` — owner is intended to be a **multisig behind a timelock** before mainnet (see TODO). |
| **Rounding** | `_usd18ToStable` truncates (rounds in the pool's favor). Fee/penalty use bps floor division. |
| **Collateral-token risk** | Only owner-whitelisted collaterals (a tier must be explicitly added) are borrowable; unknown tokens revert `NotSupported`. |
| **Stale/again-usable loan** | `active` flag flips before external calls; a settled/repaid loan can't be re-actioned. |

## v1.8 — 2026-07-23 (pre-mainnet trio: rate clamp, tier retire, 2-step ownership)

Closes the three accepted-risk items that did not require redesign (the fourth — the O(n)
impairment-sweep scale ceiling — is DESIGNED but deliberately deferred; see `V2_SCALING_SPEC.md`).

1. **LST rate clamp in the oracle (`setRateClamp` / `pokeRateAnchor` / `rateAnchors`).** The LST
   rate providers (Sceptre's upgradeable proxy, Firelight's vault) are trusted EXTERNAL inputs; a
   compromise could previously over-value collateral instantly, bounded only by the per-collateral
   exposure cap. The valuation path (`priceUsd18`, hence LTV, settlement floor, impairment) now
   clamps the reported rate to `anchor × (1 + 20bps/day × elapsed)`. Decreases (a real slash) pass
   through unclamped — under-valuing is always lender-conservative. The permissionless poke
   ratchets the anchor at the CLAMPED value, so a spiked provider can only crawl the anchor along
   the allowed slope (~12x real sFLR yield; a compromise is capped to +0.2%/day of over-valuation).
   `rateOf()` (yield-skim input) stays raw: the skim has its own +20% clamp and under-skimming only
   favours the borrower. Opt-in per collateral; unarmed behavior is byte-identical to v1.7.
2. **Tier retire (`setTierDisabled`).** Tiers stay append-only (a borrower's chosen index is
   stable forever) but a mispriced tier can now be closed to NEW underwriting: `open` and
   `rollover` reject a disabled index; existing loans, repay, settle and partialRepay (where a
   referenced tier can only TIGHTEN a release standard) are untouched. Lesser owner power than
   `setPaused`.
3. **Ownable2Step on all three contracts.** `transferOwnership` is now proposal-only; the deployer
   remains owner until the Safe executes `acceptOwnership()` (three Safe txs — see runbook 5b). A
   fat-fingered handoff address can no longer orphan the protocol.

Regressions: `test/security/LodestarV18Hardening.t.sol` (16 tests: spike-clamped valuation +
over-borrow blocked end-to-end, legit-growth/slash passthrough, poke ratchet, disarm, param
bounds, skim isolation; tier-disable across open/rollover/partial/close; 2-step transfer +
non-pending rejection). Full non-fork suite **189/189**, run twice, including all invariant/
stress/econ campaigns. Deploy script arms the clamp for sFLR (and stXRP when enabled) at wiring
time; keeper gains a daily `pokeRateAnchor` duty (safe to miss for months).

## Audit pass — 2026-07-16 (findings & fixes)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| A1 | Med | ERC4626 first-depositor / donation inflation | `_decimalsOffset() = 6` (10^6 virtual-share cushion) + seeded first deposit in deploy playbook |
| A2 | Med | `open()` trusted `collAmount` as received (fee-on-transfer / rebasing collateral could desync custody vs. valuation) | Value the **balance delta actually received**, not the requested amount |
| A3 | Med | Settlement floor was a hard-coded 95% (5% keeper-sandwich headroom) | Configurable `settleFloorBps`, default **98%**, bounded 50–100% |
| A4 | Low | Residual router allowance after settlement swap | `forceApprove(router, 0)` after the swap |
| A5 | Low | Dust loans (principal rounds to 0) | Reject `principal == 0` and zero received collateral (`BadParam`) |
| A6 | Low | `reserve` could be set to `address(0)` in constructor | Zero-check in constructor (setter already guarded) |

Verified by regression tests `test_RejectsDustLoan`, `test_SettleFloorEnforced` plus the existing
suite — **8/8 passing** (6 unit + 2 live-Flare fork). CEI ordering re-confirmed on `open`/`repay`/`settle`
(state flips before every external call; `nonReentrant` on all mutators). Accounting invariant checked by
hand: `principalOut` is incremented by exactly `principal` at `open` and decremented by the same at
`repay`/`settle`, so any settlement shortfall is realized transparently through the ERC4626 share price.

## Hardening v1.1 — 2026-07-17

Backed by a fuzz + adversarial battery (`test/invariant`, `test/security`):
- **Invariant suite** — 256 runs × 128k calls each, 0 reverts: `principalOut == Σ active principals`, collateral custody exact, USD exposure exact, no zero-principal loans.
- **Adversarial suite** — access control, ERC4626 inflation attack, keeper floor extraction, no-liquidation-in-term, transparent bad-debt realization, LTV cap, pause, oracle-outage fallback.

New improvements shipped (for the next redeploy; live Coston2 runs v1.0):
- **Pause switch** — `setPaused` blocks *new borrows only*; repay/rollover/settle stay open, so it never traps collateral (non-custodial).
- **Oracle-outage fallback** — if FTSO reverts during settlement, the floor bypass only unlocks once past `oracleFallbackDelay` (default 7d, bounded), so a transient outage can't underprice a sale, but bad debt is *always* eventually resolvable.
- **Gas** — `stableUnit` cached as immutable (removes an EXP from the per-loan hot path).

### Still open (accepted / deferred)
- Keeper bounty (5%, in-kind) is taken before lenders on underwater loans — accepted design; could cap by USD later.
- `rollover`/`repay` are callable by anyone on behalf of a borrower — harmless (they only *help* the borrower).
- **Lender-side yield skim** — implemented in v1.2 (`yieldSkimBps`, default **0** so borrowers keep all appreciation). When enabled (capped 50%), a share of collateral staking-appreciation (measured via the collateral's open-vs-current rate) routes to the reserve on repay. Kept out of the settlement path to avoid coupling it to DEX liquidity.
- **v1.2 gas:** `Loan` packed to 6 slots (uint128 fields, SafeCast-guarded) → open() ~21k cheaper. `openRate` packs with `active` at no extra slot. Covered by the invariant suite (512k ops) and a `test_YieldSkimRoutesAppreciationToReserve` unit test.


## v1.6 — 2026-07-17 (sweep gas hardening + slot-DoS priced out)

Adversarial review of the v1.5 sweep itself (measured, not assumed — Flare block gas limit read
on-chain = 28M):
- **Sweep gas:** healthy book ~2.4k gas/loan; worst case (mass crash, every loan underwater, every
  mark writes) ~25k gas/loan. At the old 500 cap that is ~13M gas per withdraw and the setter
  allowed 5000 (~130M, un-mineable) → a mass crash could brick withdrawals. **Fixed:** the sweep now
  batches a single `pool.impair` across the whole pass (one pool write, not N), the default cap is
  **300** (~7.5M worst case, 27% of a block) and the setter is capped at **400**. Verified in
  `test/security/LodestarSweepGas.t.sol`.
- **Slot-exhaustion DoS (new, from the cap's side effect):** an attacker can open dust loans up to
  `maxActiveLoans` and block all new borrows (`open` reverts `TooManyActiveLoans`). At a $10
  `minPrincipal` that costs ~$6k of locked capital. **Mitigation:** set a meaningful `minPrincipal`
  on mainnet (e.g. $100), which makes filling the cap cost real, locked capital (300 slots ≈ $60k+).
  Owner-tunable up to $1000. Regression `test_SlotExhaustionRequiresRealCapital`.
- **Design note (honest):** there is an inherent trilemma between (1) an always-fresh share price at
  exit, (2) bounded per-withdraw gas, and (3) unbounded concurrent-loan scale. v1.5/1.6 chose (1)+(2)
  and bounds (3) with the cap. A future version could paginate the sweep to lift the scale ceiling.

**95/95 tests.** Coston2 v1.6 (deployed 2026-07-17): Book `0x4Ca4a3a8e14d2e2F1aa29EF7904E8e0Eb7359c47`, Pool `0xe7D4a03f1814F3e5A3A485f2fe16EB5DC1097B8b`, Oracle `0x4302410FE3B1Cf99199086453C013783C5a6Bd4c`. (v1.7 stateless-impairment rework evaluated and REJECTED: it underflows `totalAssets` after settling a deeply-underwater loan; v1.6 per-loan marks give clean close-time reversal. v1.6 is the mainnet-final impairment design; truly-unbounded scale would need a bucketed accumulator as a separate audited v2.)

## v1.5 — 2026-07-17 (phantom-solvency closed on-chain)

The one item v1.4 left as "documented, run a keeper" is now fixed in the contract. The lazy-mark
window (an underwater loan sitting unmarked lets a fast lender exit at par) is closed on-chain:

- The book keeps an array of active loan ids (`activeLoanIds`, pushed at open, swap-removed at
  close) and a permissionless `syncImpairment()` that sweeps it, marking every underwater loan
  (raise-only, per-collateral price cached once so oracle reads are O(collaterals) and the loop is
  O(loans)).
- **The pool calls `syncImpairment()` at the start of every `withdraw`/`redeem`.** So the share
  price is provably fresh at the exact moment anyone exits — no lender can ever redeem against a
  stale, too-high price. A keeper calling `impairMany`/`syncImpairment` during volatility is now a
  UI-freshness convenience, not a safety dependency.
- `maxActiveLoans` (default 500, owner-settable 50–5000) bounds the sweep so a withdrawal can never
  be gas-bricked. Viable here because Flare gas is cheap; the O(n) sweep costs cents.

New invariant: `activeLoanIds` exactly equals the set of active loans (fuzz-checked). Regressions:
`test_WithdrawMarksUnmarkedUnderwaterLoan_NoParExit` (the core proof), `test_ActiveLoanArrayTracksOpenLoans`,
`test_MaxActiveLoansCapEnforced`. **91/91 tests.** Coston2 v1.5: Book
`0x89EC39E4f6B9dBa13eF1F6B805087CCDdFFB9e42`, Pool `0xf50Bdc85F5ffc3fD94C3DE47d291c4F51573B97c`,
Oracle `0x1551874aEa6450Af3723985dACcBd5cAf91803B7`. The phantom-solvency window moves from the
"documented risks" list to fixed.

## v1.4 — 2026-07-17 (six-agent deep-ocean review + hardening)

A second, deeper adversarial round: six independent agents on non-overlapping surfaces that the
first three did not frame, each assuming a malicious/creative actor and writing runnable PoCs.

1. **Lifecycle-combination & stale mark-to-market** — impair × rollover × addCollateral × settle races.
2. **Cross-loan shared global state & MEV** — shared buffer/price-cache/exposure, Dutch-auction ordering.
3. **Precision / decimals / real-token** — 18dp vs 6dp math, real FAsset FXRP semantics.
4. **Insolvency & bank-run dynamics** — withdrawal spiral, trapped lenders, buffer adequacy.
5. **Depeg & oracle basis** — wrapper-vs-underlying, sFLR NAV, USDT0, feed staleness.
6. **Retroactive governance risk** — every owner param modelled against already-open positions.

**Result: still no external fund-theft or drain.** The precision surface came back fully clean
(all mixed-decimal math rounds toward the pool; real FXRP is a 1:1 ERC20 with a latent, uninstalled
FAssets fee facet the balance-delta measurement already handles). The findings were lender-vs-lender
fairness seams and governance/retroactive risk — the class that actually hurts lending protocols.
Fixes shipped:

| Finding | Sev | Fix (v1.4) |
|---------|-----|-----------|
| Atomic stale-mark skim: deposit→impair(recovered loan)→redeem skims the reversal from lenders | HIGH | `impair` is now a **monotonic high-water mark** — it only ever RAISES the mid-life loss; the reversal happens solely at realization (`_clearImpairment` on repay/buyout/settleSwap). Removes the atomic-reversal primitive. |
| Phantom solvency: `impair` is permissionless but not mandatory, so an unmarked underwater loan lets an informed lender exit at par | HIGH | `impairMany(ids)` batch so a keeper can mark the whole book in one tx during volatility; `maxWithdraw`/`maxRedeem` now clamp to idle liquidity and the exit path reverts a semantic `InsufficientLiquidity`. (The residual lazy-mark window is inherent to any no-liquidation book; the true backstop is conservative LTV, and the buffer is a fair-weather cushion — see "documented risks".) |
| `yieldSkimBps`, `gracePeriod`, and the settle curve are read LIVE at the borrower's own repay/settlement, so an owner can retroactively confiscate yield, erase the cure window, or lower the floor under an already-open loan | HIGH | **Snapshot all three into `loanTerms[id]` at open.** Owner setters still change the defaults for NEW loans; existing loans keep the terms they were opened under. A timelock can't protect a borrower who can't exit — this can. |
| `withdrawReserve` front-run drains the first-loss buffer right before a bad settlement | MED | Settlement-aware guard: the owner can never pull the buffer below the currently-marked expected loss (`pool.impairedLoss`). |
| Wrapper-vs-underlying basis (sFLR under NAV; FXRP tail depeg) mis-values collateral in LTV/floor/impair | MED | Per-collateral `haircutBps` in the oracle (0 for 1:1 FXRP, non-zero for LSTs) so every risk decision uses realizable value, not par. |
| `maxStale` up to 1 day allowed borrowing against a stale-high price during a crash | MED | Bound tightened to **≤ 1 hour**; deploy sets FXRP at 15 min (FTSO updates ~90s). |
| Donated stable strands and breaks the `book stable == reserveBalance` bookkeeping | LOW | `sweepStableDonations` recovers any stable above the tracked buffer. |

Documented (not code-fixable) risks now explicit below: the lazy-mark phantom-solvency window and the
recommended keeper; the buffer as a ~40bps fair-weather cushion, not a crash backstop (LTV is the real
one); FXRP's latent FAssets fee facet; USDT0 as the unit of account (lenders bear USDT0, not USD); and
the exact params that must be timelocked/immutable before mainnet. All verified: **87/87 tests**
(30 unit + 4 oracle-fuzz + 11 adversarial + 11 v1.4 regressions + 6 core + 9 stress invariants at
384×400 + 8 econ-games + 4 live-Flare fork). Coston2 v1.4: Book
`0xa2617dc8d885B84CBC1840a45ab9CFb1aD2773bE`, Pool `0xa07C779abD010fb9483388F9726F354eADA6f93d`,
Oracle `0xdDcB5cAA9A82e6A3fF4539274fF7e362F6b566a4`.

## v1.3.2 — 2026-07-17 (three-part adversarial review + hardening)

Three independent adversarial reviews were run against v1.3.1, each on a non-overlapping
surface, every actor assumed malicious:
1. **Settlement & arithmetic** — Dutch floor, waterfall, reserve buffer, rounding, share-price sandwich.
2. **Access control, oracle, reentrancy** — router calldata, pool/book boundary, cache poisoning, owner blast radius.
3. **Fuzzing & economic gaming** — invariant campaign at 512×500 (256k calls/invariant), new solvency/no-double-resolve/no-free-extraction invariants, 8 economic-game tests.

**Result: no CRITICAL or HIGH fund-theft path.** The reviews confirmed (with reasoning) that
`totalAssets` cannot underflow, the settlement waterfall has no double-spend/surplus-theft,
`balanceOf(book) == reserveBalance` holds on every path, the pool trust boundary is airtight,
a malicious whitelisted router cannot take more than the sale amount or misroute proceeds, and
the owner blast radius is bounded to draining the first-loss *buffer* and griefing settlement,
never lender principal (fully covered by the multisig+timelock migration). Findings fixed:

| Finding | Sev | Fix (v1.3.2) |
|---------|-----|--------------|
| Keeper bounty carved ahead of the floor on underwater loans | MED | `_bountyAmount` returns 0 when the loan is underwater (collateral value < principal); underwater defaults settle via `buyout` (no bounty) or a keeper accepting gas-only. Bounty now only ever comes from surplus. |
| `impair` hard-reverts while FTSO is stalled (reopens the exit window during a crash) | MED | `impair` falls back to the cached last-good price if the live oracle reverts, so marking works during an outage — exactly when a crash hits. |
| Yield-skim trusts an unbounded LST rate provider | MED | recognized appreciation clamped to +20% over the term; an abnormal/manipulated rate skims the borrower nothing. |
| Buyout cache-decay reaches zero → cheap-sniper in a prolonged outage | MED | oracle-down floor decays to a **non-zero minimum (20%)** of the cached-price floor, not zero. |
| `impair` recovery estimate optimistic vs floor slack | LOW | accepted-minor: marking is mark-to-oracle net of the keeper haircut; the residual (floor slack of a below-par loan) is dust and trued up at settlement. Documented rather than over-marked (avoids the mirror buy-cheap-before-recovery game). |
| Scaled oracle price could floor to zero and pass | LOW | `priceUsd18` reverts `BadPrice` on a zero *scaled* price, not just a zero raw feed value. |
| Cross-contract reentrancy via a hookable token (not reachable with USDT0/FXRP) | INFO | `nonReentrant` added to the pool's `deposit`/`mint`/`withdraw`/`redeem` as defense in depth. |
| "Buffer double-spend via arbitrary router calldata" (reported HIGH) | — | **Disproven as a drain:** `_swapViaRouter` only ever approves the router for `toSell` collateral, never stable, so a whitelisted router cannot pull the buffer; injecting stable only helps lenders. Kept a proceeds sanity-ceiling (reject proceeds > 1.5× oracle value of what sold) as defense in depth, plus a regression test. |

Regression tests added: `test_ImpairWorksWhileOracleStalled`, `test_UnderwaterSettleSwapPaysNoBounty`,
`test_HealthySettleSwapStillPaysBounty`, `test_ProceedsCeilingRejectsInjection`,
`test_YieldSkimClampedOnAbnormalRate`, `test_OracleScaledZeroReverts`, plus
`test/invariant/LodestarStress.t.sol` (9 invariants) and `test/invariant/LodestarEconGames.t.sol`
(8 games). Coston2 v1.3.2: Book `0x15A37F0AF4559684A88C2Af16378530cB37a38c1`, Pool
`0x91265e26F8488890Df5b6BB2cded8eFFb99Ed2A4`, Oracle `0xdA022A1643D7CdfDC8822acf7018D79b0c0FD643`.
**76/76 tests green.**

## v1.3.1 — 2026-07-17 (extreme-scenario hardening)

`impair(id)` is now callable on any active loan, not only defaulted ones. In a tail crash
(e.g. an 80% single-day move) a loan can be underwater mid-term; anyone can now mark that
expected loss into the ERC4626 share price immediately, so no lender can redeem at par ahead
of the markdown. It remains accounting-only — the borrower keeps full repay/recover optionality
and the collateral never moves — and the mark auto-reverses if price recovers or the loan is
repaid. Coston2 v1.3.1: Book `0x1957E04fA22Aa84E6B61DCC02ea67D66Eff2D5f3`, Pool
`0x0D5af8Ff7425D67Fbe0F55BE1c5AB68490f5e4c6`, Oracle `0x57F4A29dC332aB48AA56a04aB1cC97734bBF32A2`.
Battery: 52 tests green (48 unit/security/oracle/invariant + 4 mainnet fork incl. real SparkDEX settlement),
incl. `test_ExtremeCrashMidTerm_ImpairTracksAndReverses` and `test_ImpairHealthyLoanIsNoOp`.

## v1.3 settlement redesign — 2026-07-17 (foundation review)

Driven by a three-agent review (mechanism economics + measured mainnet DEX depth + 9.5y drawdown
calibration). Full battery green: 40 unit/security/oracle tests, 6 invariants over the fuzz
campaign, and 4 live-Flare **mainnet fork tests including a real settlement through the
SparkDEX V3.1 router** (`test_fork_SettleSwapThroughRealSparkDEX`).

| Change | Why |
|--------|-----|
| **Dutch settlement floor** (`settleStartBps` 100% -> `settleFloorMinBps` 85% over `settleDecayPeriod` 24h) | A static 98% floor deadlocks in a crash (DEX leads the lagged FTSO down) and caps settle size at ~2% of pool depth. The descending curve keeps early anti-extraction and guarantees liveness. |
| **`buyout(id, maxCost)`** — anyone pays stable at the current floor, takes the collateral in-kind | Zero DEX dependency, any size. Measured mainnet depth caps atomic swaps at ~$168k single-route; buyout removes the ceiling. Borrower buying out their own default = late repayment at market price (allowed, no bounty involved). |
| **`settleSwap(id, router, calldata, minOut)`** — owner-whitelisted router + keeper calldata; contract enforces exact sale amount and stable-delta >= floor | The v1.2 V2-router interface reaches <$500 of mainnet depth; 96% of FXRP/USDT0 liquidity sits behind V3/Algebra interfaces. Route-agnostic execution unlocks it; the floor stays the security boundary. |
| **Cached last-good price** (`lastPrice18`) | FTSO outage past `oracleFallbackDelay` now decays the floor from the cached price to zero over 30 days, instead of dropping instantly to zero (killed a keeper self-sandwich extraction in the outage tail). |
| **Rollover LTV re-check** (`Undercollateralized`) + `addCollateral` cure | Unconditional extensions let an underwater borrower buy 90 days of a mispriced put (drawdown data: 4-7% breach for XRP, 33-43% for the old FLR tiers). Every calendar extension must re-qualify at current prices. |
| **Fee netted from disbursement** | Fee is earned with probability 1 (a defaulter has already paid it); repay is principal-only; waterfall simplifies to principal -> penalty -> surplus. |
| **Permissionless `impair(id)`** + pool `impairedLoss` | Marks a loan's expected loss into the share price. v1.3.1: callable on ANY active loan (was default-only), so an extreme mid-term crash is marked-to-market the moment it puts a loan underwater — closing the informed-lender exit window even before default. Healthy loans mark zero; accounting-only (never touches borrower/collateral); reversed on price recovery or repay, trued up at settlement. |
| **First-loss reserve buffer** (`reserveBalance` held in the book) | Fee cuts + penalties accumulate on-chain and automatically cover lender shortfalls before anything else; owner withdrawals are explicit (`withdrawReserve`). |
| **Bounty hygiene** | USD cap ($500 default), zero bounty on self-settlement, `minPrincipal` dust guard. |
| **Tighter bounds** | `addTier` LTV <= 70% (was 90), `keeperBps` <= 10% (was 20), oracle `maxStale` mandatory (0 forbidden, <= 1 day). |
| **sFLR tier calibration** | Planned 65/60 replaced by 55 (7d) / 45 (30d): FLR does a -30% week ~2x/yr and grinds -8%/month; the old tiers breached in up to 43% of historical 90d windows. |

## Documented risks (by design, disclose to users; not code bugs)

- ~~**Lazy-mark phantom-solvency window.**~~ FIXED on-chain in v1.5: the pool calls `syncImpairment()` (which sweeps and marks the whole active book) at the start of every `withdraw`/`redeem`, so the share price is always fresh at exit. A marking keeper is now optional (UI freshness), not a safety requirement.
- **First-loss buffer is a fair-weather cushion (~40 bps of principal), not a crash backstop.** It absorbs small idiosyncratic shortfalls; in a correlated crash it depletes and lenders eat the raw remainder. The real protection is the LTV, not the buffer. Do not market the buffer as crash insurance.
- **Exit liquidity is idle-balance-bounded and FCFS.** Redemption ≤ `available()`; principal that is lent out cannot be redeemed until it returns. In a run, the slow are temporarily illiquid (correctly priced, not lost). A withdrawal queue / exit fee is a candidate future design.
- **USDT0 is the unit of account.** "Lenders made whole" means USDT0 units, not dollars; lenders bear USDT0 depeg risk by choosing to lend USDT0. No USDT0/USD feed is wired (candidate: a band-check to pause new borrows on depeg).
- **FXRP latent fee facet.** Real FXRP can become fee-on-transfer via FAssets governance (not installed today). The balance-delta measurement handles it, but never assume FXRP is a plain ERC20.
- **LST rate trust.** sFLR/stXRP valuation uses FTSO(underlying) × the provider's on-chain staking rate. Before enabling those tiers, bound the rate-of-change (or use a direct FTSO LST feed if available) and set a per-collateral haircut.

## Not yet done (blockers before mainnet)

- [ ] Owner → **multisig + timelock**, with per-parameter disposition (from the retroactive-param review):
  - **Immutable / long-timelock:** `oracle.setFeed` (a feed swap is the compromised-key drain vector; existing loans already snapshot their curve/grace/skim, but a feed swap still mis-values NEW opens and the live settlement floor).
  - **Snapshotted at open (done in v1.4, no timelock needed):** `yieldSkimBps`, `gracePeriod`, settle curve — existing loans are immune to changes.
  - **Short-timelock:** `withdrawReserve` (now also settlement-aware), `setReserve`, `keeperCapUsd18`, `setRiskParams`, `setRouterAllowed`.
  - **Hot is acceptable:** `setPaused`, `setMaxUtilization` (cannot trap lenders — redeem isn't gated by it).
  - Set a **non-zero `exposureCap` at launch** (done in deploy) so a compromised key can't over-borrow unbounded.
- [ ] Real Flare wiring: FTSOv2 registry, XRP/USD + FLR/USD feed IDs, Sceptre/Firelight rate providers (+ rate-of-change bound + haircut), USDT0 + FXRP token addresses
- [x] **Fork tests** against live Flare (FTSO reads, real sFLR rate, real SparkDEX settlement)
- [x] Two adversarial review rounds (9 agents total), all findings fixed or documented
- [ ] Marking keeper for the phantom-solvency window
- [ ] Per-loan **position NFT** + partial repayment
- [ ] External audit
- [ ] Optional: withdrawal queue / exit fee; USDT0 band-check

**Status: deployed to Coston2 testnet (v1.4). Two internal adversarial rounds complete; no external
audit yet. Not on mainnet. Do not send mainnet funds.**
