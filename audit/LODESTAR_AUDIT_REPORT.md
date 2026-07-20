# Lodestar Protocol - Security Review Report

**Protocol:** Lodestar, fixed-term no-liquidation lending on Flare
**Website:** https://lodestarprotocol.xyz
**Repository:** github.com/lodestarprotocol/lodestar
**Report date:** 2026-07-20
**Scope commit:** `de3ce9e` (branch `main`)
**Toolchain:** Solidity 0.8.28, OpenZeppelin v5.1.0, Foundry (forge 1.7.1)

This report compiles the complete security review record of the Lodestar core contracts: seven independent multi-reviewer adversarial rounds run between 2026-07-16 and 2026-07-19, every finding proof-of-concept-backed, plus the fuzz, invariant, and live-mainnet fork verification campaigns. It is filed as the audit record for the protocol and as the reference package for any external auditor picking up the codebase.

---

## 1. Executive summary

**Verdict: no unresolved Critical or High severity issue at the scope commit.**

Across seven adversarial rounds (roughly 30 independent reviewer passes on non-overlapping attack surfaces), the process found and fixed:

- **3 High** severity issues (keeper bounty priority, reentrant deposit skim, phantom-solvency exit during an oracle outage), all fixed with regression tests before any mainnet deployment.
- **3 High** severity design-level issues in earlier versions (atomic stale-mark skim, retroactive parameter confiscation, lazy-mark phantom solvency), all closed by contract redesign (v1.4 through v1.6).
- **4 Medium** severity issues in the final code (partialRepay tier-strip, rollover LTV snapshot staleness, reserve drain ahead of unmarked losses, keeper surplus skim), all fixed or bounded.
- A set of Low / informational items, fixed or documented.

The final suite is **129 non-fork tests green** (unit, adversarial, invariant campaigns of 128k+ calls each, economic-game suites, oracle decimals fuzz) plus mainnet fork tests that execute **real settlements through live Flare DEX liquidity** (SparkDEX V3.1 single-hop and SparkDEX V4 Algebra two-hop). Section 7 details the verification evidence.

Residual risk is concentrated in explicitly accepted, bounded items (Section 6): LST rate-provider trust (bounded by a $25k per-collateral launch cap), USDT0 as unit of account, and the first-loss buffer being a fair-weather cushion rather than a crash backstop.

---

## 2. Scope

### 2.1 Contracts in scope (src/)

| File | Role |
|---|---|
| `src/LodestarLoanBook.sol` | Loan lifecycle, collateral custody, settlement (Dutch floor, buyout, settleSwap), impairment marking, first-loss reserve |
| `src/LodestarPool.sol` | ERC4626 lender vault (USDT0), `principalOut` / `impairedLoss` accounting, exit-time impairment sync |
| `src/LodestarOracle.sol` | FTSOv2 USD valuation, per-collateral haircuts, LST rate composition, staleness guards |
| `src/flare/SceptreRateAdapter.sol` | sFLR rate adapter (`getPooledFlrByShares` to `underlyingPerShare`) |
| `src/flare/FirelightRateAdapter.sol` | stXRP rate adapter (ERC4626 `convertToAssets` over the XRP feed) |
| `src/flare/FlareAddresses.sol` | Single source of truth for verified mainnet addresses |
| `src/interfaces/*` | `IDexRouter`, `IFtsoV2`, `ILstRateProvider` |

Also reviewed: `script/DeployMainnet.s.sol`, `script/TransferOwnership.s.sol` (deploy wiring, guard asserts, mandatory pool seed), the settlement keeper (`lodestar-keeper/`, off-chain), and the production dapp (`web/index.html`).

### 2.2 Trust model

- Core wiring is **immutable**: no proxies, no upgrade path. `Pool <-> LoanBook` binding is one-shot (`setLoanBook`). Only the LoanBook can move pool funds.
- Per-loan economics (`yieldSkimBps`, grace period, settlement curve, opening tier LTV) are **snapshotted at open** into `loanTerms[id]` / `openLtvBps[id]`; owner setters affect new loans only.
- Tiers are **append-only** (no edit, no disable). Launch tiers are permanent.
- Owner (to be a 3-of-5 Safe at mainnet) controls risk parameters, feeds, router whitelist, pause (blocks new borrows only), and reserve withdrawal (sync-guarded). The reviewed owner blast radius is: drain the first-loss buffer, grief settlement, mis-value NEW opens via `setFeed`. It cannot reach lender principal or retroactively change open-loan terms.

### 2.3 Protocol model

Borrower locks yield-bearing collateral (FXRP, sFLR, stXRP) and borrows USDT0 at a tier LTV with a fixed deadline. There is no price liquidation; only the deadline plus a grace period defaults a loan. On default, permissionless settlement sells or buys out collateral behind a Dutch descending FTSO-anchored floor (100% decaying to 85% over 24h); lenders are made whole first, surplus returns to the borrower. Fees are netted at disbursement. Every loan is economically a put option the lender writes; solvency discipline is conservative LTV plus guarded caps plus loss-ratio monitoring.

---

## 3. Methodology

1. **Round 1 (2026-07-16), single-reviewer pass:** custody, CEI, rounding, first-depositor. 6 findings (A1-A6), all fixed.
2. **Round 2 (v1.3.2, three reviewers):** settlement arithmetic, access/oracle/reentrancy, fuzz and economic gaming. Invariant campaign 256k calls per invariant.
3. **Round 3 (v1.4, six reviewers):** lifecycle combinations, cross-loan shared state and MEV, precision/decimals with real-token semantics, insolvency and bank-run dynamics, depeg and oracle basis, retroactive governance. Produced the snapshot-at-open redesign.
4. **Round 4 (2026-07-18, five reviewers):** settlement/arithmetic, access/reentrancy, oracle/decimals/LST, economic gaming including partialRepay, deploy/governance. Found High #1 and High #2.
5. **Round 5 (2026-07-18, eight-round loop-until-dry workflow):** repeated independent sweeps until two consecutive rounds surfaced nothing new, plus a completeness critic. Found High #3, which three prior rounds had missed.
6. **Round 6 (2026-07-19, four + three reviewers):** PoC-backed passes on settlement, partialRepay and skim, oracle and decimals, access and DoS; then a dedicated re-audit of that day's own fixes. Found the tier-strip Medium, the reserve-guard Medium, and the rollover follow-up Medium.
7. **Round 7 (2026-07-19, three + five reviewers):** full exploit-class taxonomy (12 canonical classes, 15 PoCs), precision/overflow/cast sweep, external-dependency and liveness analysis, then a final accounting/oracle/settlement/governance/dapp pass. No new code bug; produced deploy-script and dapp defense-in-depth hardening.

All rounds assume malicious actors, require runnable PoCs for claims, and adversarially attempt to refute each other's findings. Scratch PoCs were deleted after capture; every accepted finding has a permanent regression test.

---

## 4. Findings: final codebase (fixed at scope commit)

### HIGH-1: Keeper bounty paid ahead of lenders on marginally solvent defaults
`_bountyAmount` checked full collateral value against principal, but the bounty was carved out **before** the sale. For principal <= collateral value < ~1.24x principal, the reduced sale could not clear the floor while the keeper kept its cut, shorting lenders. **Fix:** in `settleSwap`, if `floor(toSell) < principal`, the bounty is dropped and the entire collateral is sold, lenders first. Regressions: `test_BountyDroppedWhenItWouldShortLenders`, `test_BountyStillPaidWhenComfortablySolvent`.

### HIGH-2: Reverse-skim via reentrant deposit/mint during settlement callback (latent)
`deposit`/`mint` did not sync impairment the way `withdraw`/`redeem` did, so a hookable (ERC777-style) collateral could reenter during a settlement collateral transfer and deposit against a stale-low share price. Launch tokens are plain ERC20, so this was latent, but the core is immutable. **Fix:** `_syncImpairment()` added to pool `deposit` and `mint`; reentry now reverts under the held LoanBook guard. Regression suite: `test/security/LodestarReentryAudit.t.sol`.

### HIGH-3: Phantom-solvency exit via stale price cache during an FTSO outage
The marking path `_livePriceOrCache` fell back to the last cached price with no age check (`lastPriceAt` was written but never read). During an FTSO outage combined with a real crash, the exit sweep marked loans off the pre-crash stale-high price, so the share price stayed at par and an informed lender could redeem at par, dumping the realized loss on remaining lenders (PoC moved ~20k of value on a 100k pool). The settlement path guarded outages; the exit path did not. **Fix:** cache fallback removed from marking (`_liveOrZero` returns zero on any oracle revert); new `syncImpairmentForExit()` reverts `OracleDown` if any active loan cannot be freshly priced; `withdraw`/`redeem` use the strict version, `deposit`/`mint` keep best-effort sync (a depositor can only overpay itself). Settlement's own decayed cached-floor fallback is unchanged, so bad debt remains resolvable during outages. Regression: `test_ImpairRefusesStalePrice_AndExitRefusesDuringOutage`.

### MED-1: partialRepay collateral release against a caller-chosen tier LTV
The release re-check used the LTV of a caller-supplied `tierIndex`. Since partial repayment leaves the deadline unchanged, a 30d-tier borrower could point at the 7d tier's laxer LTV and strip collateral below underwriting. **Fix:** `openLtvBps[id]` recorded at open; release standard is `min(openLtvBps[id], chosenTier.ltvBps)`, so a caller can only tighten. Three regression tests.

### MED-2: rollover did not refresh the openLtvBps snapshot
Follow-up to MED-1 found by the re-audit of the fix itself: open at a lax tier, roll into a strict tier, then strip back to the stale lax LTV. **Fix:** `rollover` sets `openLtvBps[id]` to the adopted tier's LTV. Regression added.

### MED-3: withdrawReserve could drain the buffer ahead of unmarked losses
The earmark guard read `pool.impairedLoss()`, which reflects only marked losses; a hasty or compromised owner could pull the first-loss buffer ahead of a known-underwater but unmarked loan. **Fix:** `withdrawReserve` calls `_syncAll()` first (best effort; can only raise the earmark). Two regression tests including a positive control.

### MED-4: risk-free keeper surplus skim on settleSwap (reduced, residual accepted)
A keeper settling a solvent default at a fresh oracle could route the sale to capture up to ~15% surplus (the Dutch floor budget) risk-free. **Fix:** on a solvent default with a fresh oracle, `settleSwap` must remit at least fresh-oracle-value minus `settleSwapSlippageBps` (default 3%, owner-tunable 1-20%). The guard only raises the floor and is skipped when underwater or oracle-down, so crash liveness is untouched. Verified against real mainnet DEX state with the guard active. **Residual (by design):** the `buyout` path stays at the Dutch floor; that arb bears capital and price risk and is the crash-liveness mechanism. Borrowers can always self-cure via their own buyout.

### Low / informational (final code)
- Deploy script's ERC4626 inflation seed was skippable if the deploy wallet held no USDT0; now **mandatory** (`require(bal >= $10)`), an unseeded pool cannot be broadcast.
- `setMinPrincipal` ceiling raised to $10k for reactive anti-griefing escalation headroom.
- Keeper startup guard refuses placeholder/zero/no-code addresses.
- Dapp: non-finite input guard on amount parsing; HTML-escape of dynamic error text before the toast sink; gas padding (estimate x 1.4 + 50k) on all writes because the exit sweep cost drifts between estimation and inclusion (observed live as a ReentrancySentryOOG on withdraw).
- Documentation correction: a compromised owner CAN move an open loan's settlement floor via `setFeed` (floor = live oracle x frozen bps); bounded to real FTSO feeds, <= 50% haircut, and hits borrower surplus first. This is the main reason `setFeed` belongs behind the multisig.

---

## 5. Findings: design evolution (closed by redesign, v1.3 through v1.6)

These were found in earlier versions and eliminated structurally; listed so an external auditor understands why the design looks the way it does.

| Issue | Sev | Structural fix |
|---|---|---|
| Atomic stale-mark skim: deposit, impair a recovered loan, redeem the reversal | HIGH | Impairment is a **monotonic high-water mark** mid-life; reversal happens only at realization (`_clearImpairment` on close) |
| Retroactive parameter confiscation (owner changes skim/grace/curve under open loans) | HIGH | **Snapshot at open** (`loanTerms[id]`); setters affect new loans only |
| Lazy-mark phantom solvency (unmarked underwater loan lets a fast lender exit at par) | HIGH | Pool calls the impairment sweep **on-chain at every exit**; `maxActiveLoans` (300, setter cap 400) bounds sweep gas to ~7.5M worst-case vs the 28M block limit |
| Static 98% settlement floor deadlocks in a crash; V2-router interface reached < $500 of real depth | HIGH (econ) | Dutch descending floor (100% to 85% / 24h), route-agnostic `settleSwap` (whitelisted router, balance-delta floor check), any-size `buyout`, cached-price decayed floor for oracle outages |
| Rollover was an unpriced put (no LTV re-check on extension) | HIGH (econ) | Rollover re-qualifies at current prices (`Undercollateralized`), `addCollateral` cure path |
| Keeper bounty carved ahead of floor on underwater loans | MED | Bounty = 0 when underwater; bounty USD-capped ($500) and zeroed on self-settle |
| Yield-skim trusted unbounded LST rate | MED | Recognized appreciation clamped to +20% per term |
| Sweep gas brick at 500-5000 loan caps | MED | Measured on-chain (28M block): batched single `pool.impair` per sweep, cap 300/400 |
| Slot-exhaustion DoS via dust loans | MED | `minPrincipal` $100 at launch (cap-fill cost ~$67k locked), owner-escalatable to $10k |
| Stateless-impairment rework (v1.7 candidate) | n/a | **Evaluated and rejected**: recomputing pool impairment fresh underflows `totalAssets` after settling deeply underwater loans. v1.6 per-loan marks are the final design. Do not resurrect. |

Earlier fixed items (fee-on-transfer balance-delta measurement, per-collateral haircuts, maxStale <= 1h, first-depositor offset 6 + seed, `sweepStableDonations`, zero-scaled-price revert, non-zero outage floor minimum, proceeds sanity ceiling 1.5x) are detailed in `belay/SECURITY.md`.

---

## 6. Accepted risks and deferred items (disclose; not code bugs)

1. **LST rate-provider trust.** sFLR's rate provider is a proxy upgradeable by a single external EOA; stXRP's by a 2-of-N Safe. `priceUsd18` has no valuation-side rate clamp (only the yield-skim path clamps). A compromised provider enables over-borrowing **up to the per-collateral exposure cap only**. Mitigation chosen: guarded launch cap of **$25k per collateral** (raised later by multisig), instead of re-touching the audited oracle. This cap is the sole bound and MUST be set at deploy (it is, in `DeployMainnet`).
2. **Firelight stXRP donation-resistance unverified.** stXRP ships at conservative params (40/35 LTV, 6% haircut, quarter-size cap); verify the vault's donation behavior before any cap raise.
3. **First-loss buffer is a fair-weather cushion** (~40bps of principal), not a crash backstop. The LTV is the real protection. Do not market the buffer as insurance.
4. **Exit liquidity is idle-balance-bounded and first-come-first-served.** Lent-out principal cannot be redeemed until it returns; in a run the slow are temporarily illiquid, correctly priced, not lost.
5. **USDT0 is the unit of account.** Lenders bear USDT0 depeg risk by choice of asset. No USDT0/USD band-check wired (future candidate).
6. **FTSO fee activation.** `getFeedById` is payable (fee currently 0). If Flare governance activates fees, lender exits freeze while loans are active (settlement escapes via the decayed cached floor). Monitor `calculateFeeById` and `getFeedIdChanges`.
7. **FXRP fee facet.** FXRP's FAssets transfer fee is recipient-side and not attached today (verified on-chain, gated probe test on file). A flip to sender-side fee would freeze settlement. Monitor FAssets fee-facet governance and pause status.
8. **Active-slot griefing** is a parameter question, not a code gap: 300 slots at $100 minimum principal costs ~$67k locked capital to grief for a term; owner can escalate `minPrincipal` to $10k (millions to grief). Buyout guarantees settlement liveness regardless.
9. **Owner `setFeed`** can move open-loan settlement floors (Section 4, last item); it is the compromised-key vector and the primary reason for the multisig.

---

## 7. Verification evidence

### 7.1 Test suite (at scope commit `de3ce9e`)

**129/129 non-fork tests pass** (re-run and certified for this report on 2026-07-20):

- Unit + adversarial: core lifecycle, settlement waterfall, access control, oracle decimals fuzz, sweep gas measurement, reentry audit, partial-repay adversarial suite (T1-T15 + fuzz), malicious-router exfiltration probe (EvilRouter).
- **Invariant campaigns** (six suites, 128k+ calls each, zero reverts): solvency, `principalOut` conservation, collateral custody exactness, no-double-resolve, no-free-value-extraction, `totalAssets` never underflows, active-array exactness, book-stable == reserveBalance, impair-sum consistency. partialRepay is wired into both stress and invariant handlers (~20k calls per campaign).
- **Dedicated 18-decimal (sFLR) invariant suite** with its own handler (open/impair/settleSwap/buyout/partialRepay/addCollateral/price-move), probe-confirmed that settlements actually execute in-fuzz.
- Economic-game suites: impair-skim, deposit-before-unimpair, impair-spam, unsettleable-loan, reserve-drain, mark-dodge, share-price sandwich.
- Precision sweep: every `toUint128` cast bounded or reverts on the attacker's own call; 2800-dust-partialRepay drift nets to exactly zero.

### 7.2 Mainnet fork tests (live Flare state)

- `test_fork_SettleSwapThroughRealSparkDEX`: real settlement through SparkDEX V3.1 router `0x8a1E35F5...2781` (fee 500).
- `test_fork_StxrpSettleSwapThroughSparkDexV4` (HEAVY_FORK-gated): $5,275 stXRP loan settles via SparkDEX V4 Algebra two-hop (stXRP -> FXRP -> USDT0) through the live ~$5.8M pool; lenders whole, bounty paid, with the 97% fairMin guard **active**.
- `test_fork_SflrSettlesViaBuyoutOnMainnetState`: buyout path on real sFLR state.
- `test/fork/MainnetWiring.t.sol`: all mainnet addresses, feeds, and both rate adapters proven against live state (XRP $1.09, sFLR rate 1.856, stXRP rate 1.00007).
- FXRP fee-facet probe (gated): confirms recipient-side/unattached semantics.

### 7.3 Live deployment evidence (Coston2 testnet, v1.6)

Book `0x4Ca4a3a8e14d2e2F1aa29EF7904E8e0Eb7359c47`, Pool `0xe7D4a03f1814F3e5A3A485f2fe16EB5DC1097B8b`, Oracle `0x4302410FE3B1Cf99199086453C013783C5a6Bd4c` (chainId 114). As of 2026-07-20: TVL $158, 21 loans opened lifetime, 17 active, 15 lenders, share price 1.0125, zero impaired loss, zero stuck defaults. Real third-party testers run full borrow/repay lifecycles.

**Note:** Coston2 v1.6 predates fixes MED-1/2/3 and HIGH-1/2/3 refinements landed 2026-07-18/19; it is a testnet UX deployment. Mainnet deploys from the scope commit and launches WITH all fixes.

### 7.4 Reproduction

```
cd belay
forge test --no-match-path "test/fork/*"          # 129 tests, includes invariant campaigns
FORK_RPC=<flare-rpc> forge test --match-path "test/fork/*"
HEAVY_FORK=1 FORK_RPC=<flare-rpc> forge test --match-test stXRP   # heavy Algebra 2-hop settlement
```

---

## 8. Launch preconditions (governance and ops)

1. **Owner -> 3-of-5 Safe multisig.** Deliberately **no timelock**: a timelock would cripple emergency `setPaused`, and open loans are already immune to parameter changes via the at-open snapshot, which removes the usual reason for one. Signer keys are distributed to independent hardware devices before real funds.
2. `TransferOwnership.s.sol` hands all three Ownables to the Safe and **must set `reserve` to the treasury first** (script does this; asserts owner == Safe and Safe has code).
3. Launch config: lean 7d + 30d tiers only (append-only, permanent): FXRP 50/45, sFLR 45/40, stXRP 40/35 with 6% haircut and quarter cap; fees 2% / 3.5% (over-cover modeled expected loss ~18-42x); `minPrincipal` $100; `exposureCapUsd18` $25k per collateral; `maxUtilization` 80%; mandatory pool seed enforced by the deploy script.
4. Deploy script resolves FtsoV2 from the FlareContractRegistry at broadcast and hard-asserts it equals the audited constant; all placeholder addresses revert if unset.
5. Arm the settlement keeper (`lodestar-keeper/`): sync/detect/settle with simulate-before-fire, routers SparkDEX V4 Algebra (primary), V3.1, BlazeSwap; sFLR via WFLR two-hop, stXRP via FXRP two-hop.
6. Monitoring (`monitor.py`): utilization, aggregate LTV, thinnest drop-to-default, marked loss, buffer coverage, loss ratio (solvent < 100%), plus the FTSO-fee and FAssets-facet watch items from Section 6.

---

## 9. Closing statement

The codebase has been through seven adversarial review rounds with escalating independence and PoC discipline; the final three High findings each came from a later round that earlier rounds missed, which is the expected signature of a review process running to exhaustion rather than to schedule. At the scope commit the reviewers know of no unresolved path to lender or borrower fund loss within the stated trust model. The remaining risk lives in the disclosed, bounded items of Section 6 and in operational discipline (Section 8), not in contract logic.

Fixed findings must not be re-litigated without new evidence; each carries a regression test that encodes the exploit.

*Filed 2026-07-20. Contact: dev@lodestarprotocol.xyz.*
