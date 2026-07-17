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

## Not yet done (blockers before mainnet)

- [ ] Owner → **Gnosis Safe multisig + timelock** on all param setters
- [ ] Real Flare wiring: FTSOv2 registry address, XRP/USD + FLR/USD feed IDs, Sceptre sFLR rate provider, USDT0 + FXRP token addresses
- [x] **Fork tests** against live Flare (FTSO reads, real sFLR rate, real SparkDEX settlement)
- [ ] Optional lender-side yield skim (currently all LST appreciation returns to borrower)
- [ ] Per-loan **position NFT** + partial repayment
- [ ] External audit + invariant/fuzz suite (utilization never > cap; Σ principalOut == Σ active-loan principals; pool solvency)
- [ ] Reentrancy/■ regression PoCs ported from prior sessions

**Status: v1 scaffold. Not audited. Not deployed. Do not send mainnet funds.**
