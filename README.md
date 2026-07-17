# Lodestar ⛓️ — no-liquidation, fixed-term lending on Flare

> Borrow USDT0 against your FXRP / sFLR. **No margin calls, no health factor — only the calendar can default you.** [belay = the climbing rope that catches your fall]

Lodestar is fixed-term, no-liquidation lending built for Flare. Lock yield-bearing
collateral, receive USDT0 at a tier LTV, repay by a deadline. A price crash can never
liquidate you; the only thing that can is missing your deadline, and even then, after a
grace window, the loan settles behind an FTSO price floor, lenders are made whole first,
and any surplus (including collateral yield) returns to you.

## Why it's good

1. **Yield-bearing collateral keeps working.** Locked sFLR keeps earning staking + FlareDrops; its appreciation returns to the borrower on repay. An optional lender-side skim can instead route that yield to lenders.
2. **FTSOv2 native oracle** — enshrined, decentralized, free, flash-loan-resistant. The price feed is the same one that secures the chain, not a DEX spot a flash loan can bend.
3. **Real LTV on quality collateral** — FXRP and sFLR are far less volatile than memecoins, so borrowers get meaningful capital efficiency (50–60% LTV) without any liquidation risk.
4. **Fee-only, no token** — lenders earn borrower fees plus optional collateral yield; no emissions, no inflation, nothing to farm or dump.

## The market thesis (on-chain, July 2026)

- Flare has real, live stablecoin borrow demand against XRP collateral, with stablecoin borrow APY running in the mid-teens.
- **FXRP is the dominant collateral on Flare** and XRP is one of the largest assets in crypto with almost no DeFi utility — a market that wants stablecoin liquidity against XRP without the liquidation risk that makes leveraged XRP terrifying.
- No-liquidation lending on Flare is an open, largely untested category. Lodestar is a clean, honestly-accounted product for it.

## Contracts

- `LodestarOracle` — FTSOv2 USD valuation (direct feeds for FXRP; feed + LST-rate for sFLR)
- `LodestarPool` — ERC4626 lender vault (USDT0); share price rises with fees/yield
- `LodestarLoanBook` — open / repay / rollover / permissionless default settlement

## Settlement (v1.3)

Default resolution is deadline-triggered and permissionless. After the grace window a
loan can be resolved two ways, both bounded by a **descending (Dutch) price floor** that
starts at 100% of the FTSO value and eases to 85% over 24h:

- **`buyout`** — anyone pays USDT0 at the current floor and takes the collateral in-kind.
  No DEX dependency, any size.
- **`settleSwap`** — a keeper routes the sale through an owner-whitelisted DEX router with
  their own calldata; the contract only accepts it if the exact sale amount left and the
  USDT0 received clears the floor.

Expected losses are marked into the ERC4626 share price the moment a loan is underwater
(permissionless `impair`), a first-loss reserve buffer absorbs shortfalls ahead of lenders,
and the origination fee is netted at open so a defaulter has always paid it.

## Audit & tests

See [`SECURITY.md`](./SECURITY.md) for the full bug-class → defense map, the v1.3/v1.3.2
change log, and the three-part adversarial review (settlement/arithmetic, access/oracle/
reentrancy, fuzzing/economic-gaming). Test surface:

- **Unit + property** (`test/Lodestar.t.sol`, `test/OracleDecimals.t.sol`) — full lifecycle,
  extreme-crash mid-term marking, Dutch-floor decay, bounty/oracle/rounding regressions.
- **Adversarial** (`test/security/`) — each test *tries* to break a security property.
- **Invariant fuzz** (`test/invariant/`) — 6 core + 9 stress invariants (solvency,
  no-double-resolution, no-free-value-extraction, buffer identity) held over 256k calls
  each at 512×500, plus 8 economic-game tests.
- **Live-Flare fork** (`test/fork/`) — real FTSO reads and a full default settled through
  the **real SparkDEX V3.1 router** on mainnet state.

```shell
forge test                                            # full suite
forge test --match-path 'test/fork/*' \
  --fork-url https://flare-api.flare.network/ext/C/rpc  # mainnet-state fork tests
FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=500 \
  forge test --match-contract 'LodestarStress'        # deep invariant campaign
```

## Live

- **App:** https://lodestarprotocol.xyz
- **Network:** Coston2 testnet (chainId 114), priced by the live Coston2 FTSOv2
- **Contracts (v1.4):**
  - `LodestarLoanBook` — [`0xa2617dc8d885B84CBC1840a45ab9CFb1aD2773bE`](https://coston2-explorer.flare.network/address/0xa2617dc8d885B84CBC1840a45ab9CFb1aD2773bE)
  - `LodestarPool` — `0xa07C779abD010fb9483388F9726F354eADA6f93d`
  - `LodestarOracle` — `0xdDcB5cAA9A82e6A3fF4539274fF7e362F6b566a4`
  - collateral: FTestXRP `0x0b6A…3dc7` · stable: USD₮0 `0xC1A5…E71F`

## Status

v1.4 — **87/87 tests pass** (30 unit + 4 oracle-decimals fuzz + 11 adversarial + 11 v1.4
hardening regressions + 6 core invariants + 9 stress invariants at 384×400 + 8 economic-game +
4 live-Flare fork). **Two adversarial review rounds (9 agents total)** complete (see
`SECURITY.md`): no external fund-theft or drain path; the findings were lender-vs-lender fairness
seams and retroactive-governance risk, all fixed (monotonic impairment, per-loan term snapshots,
oracle haircut + tighter staleness, settlement-aware buffer) or documented (lazy-mark window,
buffer-as-cushion, USDT0 unit-of-account). **Deployed to Coston2.** Not yet mainnet; owner is a
single EOA pending a multisig + timelock, with a per-parameter disposition in `SECURITY.md`.

```shell
forge build && forge test -vv
# deploy: forge script script/Deploy.s.sol:Deploy --rpc-url $COSTON2_RPC --account lodestar-deployer --broadcast
```
