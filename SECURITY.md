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
| **Oracle manipulation** | Prices come from Flare's **enshrined FTSOv2**, not DEX spot/TWAP that flash loans can bend. Staleness guard (`maxStale`) per feed. Settlement swap is floored at **95% of FTSO value** so a keeper cannot route value away. |
| **Price-liquidation griefing** | No price-based liquidation exists. `settle` reverts (`NotYetDefaulted`) until `dueAt + gracePeriod`. |
| **ERC4626 inflation / first-depositor** | OZ v5 ERC4626 virtual-shares mitigation. Deploy playbook seeds a small first deposit from the deployer and burns it. |
| **Bad debt / shortfall** | Conservative LTV caps (≤90% enforced, FXRP 50% / sFLR 60% at launch), per-collateral `exposureCap`, and pool `maxUtilization` (80%). Any settlement shortfall is realized transparently via the ERC4626 share price (socialized to lenders), never hidden. |
| **Keeper extraction** | Bounty fixed at `keeperBps` (5%) in-kind; swap floored by FTSO; permissionless so no single keeper is privileged. |
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

### Still open (accepted / deferred)
- Keeper bounty (5%, in-kind) is taken before lenders on underwater loans — accepted design; could cap by USD later.
- `rollover`/`repay` are callable by anyone on behalf of a borrower — harmless (they only *help* the borrower).
- Optional **lender-side yield skim** (route part of sFLR appreciation to lenders) — designed, not yet implemented; currently all appreciation returns to the borrower.

## Not yet done (blockers before mainnet)

- [ ] Owner → **Gnosis Safe multisig + timelock** on all param setters
- [ ] Real Flare wiring: FTSOv2 registry address, XRP/USD + FLR/USD feed IDs, Sceptre sFLR rate provider, USDT0 + FXRP token addresses
- [ ] **Fork tests** against live Flare (FTSO reads, real sFLR rate, DEX router)
- [ ] Optional lender-side yield skim (currently all LST appreciation returns to borrower)
- [ ] Per-loan **position NFT** + partial repayment
- [ ] External audit + invariant/fuzz suite (utilization never > cap; Σ principalOut == Σ active-loan principals; pool solvency)
- [ ] Reentrancy/■ regression PoCs ported from prior sessions

**Status: v1 scaffold. Not audited. Not deployed. Do not send mainnet funds.**
