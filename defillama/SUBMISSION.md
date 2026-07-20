# Lodestar → DefiLlama listing (launch-day runbook)

Everything needed to list Lodestar on DefiLlama. **Cannot be submitted until mainnet is live**
(DefiLlama indexes real mainnet TVL, not testnet — Coston2 faucet tokens have no market price).
The moment mainnet is deployed and seeded, this is a same-day PR.

---

## Prerequisites (must be true before submitting)
- [ ] Lodestar deployed to **Flare mainnet** (DeployMainnet broadcast, ownership transferred to the Safe).
- [ ] Pool seeded and real USD₮0 / collateral actually locked (non-trivial TVL).
- [ ] Pashov audit report published (link it in the metadata — helps the listing land clean).

## Step 1 — finish the adapter (`index.js` in this folder)
- [ ] Fill `POOL` = mainnet **LodestarPool** address (from the DeployMainnet broadcast).
- [ ] Fill `BOOK` = mainnet **LodestarLoanBook** address.
- [ ] Set `start` to the mainnet **deploy block number** (clean historical backfill).
- Token addresses are already filled and audit-verified: USD₮0, FXRP, sFLR, stXRP.

## Step 2 — open the adapter PR
1. Fork **github.com/DefiLlama/DefiLlama-Adapters**.
2. Create `projects/lodestar/index.js` and paste this folder's `index.js` (with the addresses filled).
3. Test locally: `npm test -- projects/lodestar` (should print a non-zero Flare TVL + borrowed).
4. Open a PR titled `Add Lodestar (Flare)` with a one-line description. No need to request review;
   they monitor the queue. Allow ~24h after merge for the frontend to show it.

## Step 3 — protocol metadata (submitted with / alongside the listing)
| Field | Value |
|---|---|
| Name | Lodestar |
| Category | **Lending** (no-liquidation, fixed-term) |
| Chain | Flare |
| Website | https://lodestarprotocol.xyz |
| Twitter | @lodestar_flr |
| GitHub | https://github.com/lodestarprotocol/lodestar |
| Logo | submit the Lodestar mark (PNG, square) |
| Audit | link the Pashov Audit Group report |
| Description | No-liquidation, fixed-term lending on Flare. Lock yield-bearing collateral (FXRP, sFLR, stXRP), borrow USD₮0 at a tier LTV, repay by a deadline. Price never liquidates; only the calendar can default a loan. |
| Oracle | Flare FTSOv2 (enshrined) |

## Step 4 — pricing gotcha to verify at submit time
- USD₮0 (stable) and **FXRP** (= XRP) price trivially. No action.
- **sFLR** and **stXRP** are LSTs. Confirm DefiLlama already has a price feed for each; if not,
  point their pricing at the underlying (sFLR → FLR × Sceptre rate; stXRP → XRP × Firelight rate),
  or coordinate with the DefiLlama team in the PR. Not a blocker, just verify so TVL prices correctly.

## Notes
- `tvl` uses `sumTokensExport` over [Pool, Book] for [USD₮0, FXRP, sFLR, stXRP]. Because it reads
  contract balances, USD₮0 that is lent out is automatically excluded from TVL.
- `borrowed` reads `pool.principalOut()` (outstanding USD₮0 loans).
- Flare is already a supported DefiLlama chain, so no chain onboarding is required.
