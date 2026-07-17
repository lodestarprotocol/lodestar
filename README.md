# Lodestar ⛓️ no-liquidation, fixed-term lending on Flare

> Borrow USDT0 against your FXRP or sFLR. No margin calls, no health factor. Only the calendar can default you. [belay = the climbing rope that catches your fall]

Lock yield-bearing collateral, take USDT0 up to a tier LTV, repay by a deadline. A price crash never liquidates you. The only thing that can is missing your deadline, and even then, after a grace window, the loan settles behind an FTSO price floor: lenders are paid first, and any surplus (including the yield the collateral earned) comes back to you.

## Why it's good

1. **Collateral keeps working while it's locked.** sFLR keeps earning staking and FlareDrops for the whole term, and that appreciation returns to the borrower at repay. An optional lender-side skim can route it to lenders instead.
2. **FTSOv2-native pricing.** The feed is Flare's enshrined oracle, the same one that secures the chain, not a DEX spot price a flash loan can bend for a block.
3. **Real LTV on quality collateral.** FXRP and sFLR are far less volatile than memecoins, so borrowers get 50 to 60% LTV and meaningful capital efficiency with zero liquidation risk.
4. **Fee-only, no token.** Lenders earn borrower fees plus optional collateral yield. No emissions, no inflation, nothing to farm or dump.

## The market (on-chain, July 2026)

XRP is one of the largest assets in crypto and until recently had almost no DeFi utility. FXRP fixed that on Flare, and it's now the dominant collateral there, with live stablecoin borrow demand and borrow APY in the mid-teens. What's missing is a way to borrow against XRP without the liquidation risk that makes leveraged XRP terrifying. No-liquidation lending on Flare is an open, largely untested category, and Lodestar is a clean, honestly-accounted product for it.

## Contracts

- `LodestarOracle`: FTSOv2 USD valuation (direct feed for FXRP; feed plus staking-rate for sFLR), with a mandatory staleness bound and a per-collateral haircut.
- `LodestarPool`: ERC4626 lender vault in USDT0. Share price rises with fees and yield, and marks down honestly when a loan goes bad.
- `LodestarLoanBook`: the loan lifecycle. Open, repay, rollover, and permissionless default settlement.

## Settlement

Default resolution is deadline-triggered and permissionless. After the grace window a loan settles two ways, both bounded by a descending (Dutch) price floor that starts at 100% of the FTSO value and eases to 85% over 24 hours:

- `buyout`: anyone pays USDT0 at the current floor and takes the collateral in-kind. No DEX dependency, any size.
- `settleSwap`: a keeper routes the sale through an owner-whitelisted DEX router with their own calldata, and the contract only accepts it if the exact sale amount left and the USDT0 received clears the floor.

Expected losses mark into the share price the moment a loan goes underwater (permissionless `impair`, monotonic so it can't be gamed), a first-loss reserve buffer absorbs shortfalls ahead of lenders, and the origination fee is netted at open so a defaulter has always paid it. Every borrower-facing term (grace, floor curve, yield skim) is snapshotted at open, so a later parameter change can never rewrite a loan you already took.

## Audit and tests

See [`SECURITY.md`](./SECURITY.md) for the full bug-class to defense map, the change log, and the two adversarial review rounds (nine agents total): settlement and arithmetic, access and oracle and reentrancy, fuzzing and economic gaming, then a deeper round on lifecycle combinations, cross-loan state, precision, insolvency and bank-run dynamics, depeg and oracle basis, and retroactive governance. No external fund-theft or drain path was found in either round.

- **Unit and property** (`test/Lodestar.t.sol`, `test/OracleDecimals.t.sol`): full lifecycle, extreme-crash mid-term marking, Dutch-floor decay, and the bounty/oracle/rounding regressions.
- **Adversarial** (`test/security/`): each test tries to break one security property and asserts it can't.
- **Invariant fuzz** (`test/invariant/`): 6 core plus 9 stress invariants (solvency, no double-resolution, no free value extraction, buffer identity) held over hundreds of thousands of calls, plus 8 economic-game tests.
- **Live-Flare fork** (`test/fork/`): real FTSO reads and a full default settled through the real SparkDEX V3.1 router on mainnet state.

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
- **Contracts (v1.5):**
  - `LodestarLoanBook`: [`0x89EC39E4f6B9dBa13eF1F6B805087CCDdFFB9e42`](https://coston2-explorer.flare.network/address/0x89EC39E4f6B9dBa13eF1F6B805087CCDdFFB9e42)
  - `LodestarPool`: `0xf50Bdc85F5ffc3fD94C3DE47d291c4F51573B97c`
  - `LodestarOracle`: `0x1551874aEa6450Af3723985dACcBd5cAf91803B7`
  - collateral: FTestXRP `0x0b6A…3dc7`, stable: USD₮0 `0xC1A5…E71F`

## Status

v1.5, **91/91 tests passing** (30 unit, 4 oracle-decimals fuzz, 14 adversarial/hardening, 7 core and 9 stress invariants, 8 economic-game, 4 live-Flare fork). Two adversarial review rounds are done: no external fund-theft path, and the real findings were lender-vs-lender fairness seams and retroactive-governance risk, all fixed (monotonic impairment, per-loan term snapshots, oracle haircut and tighter staleness, settlement-aware buffer) or documented honestly (the buffer as a fair-weather cushion, USDT0 as the unit of account). v1.5 closes the last structural item on-chain: the pool sweeps and marks the whole active book on every withdraw/redeem, so no lender can exit against a stale share price (the marking keeper is now optional). Deployed to Coston2. Not yet mainnet: the owner is still a single EOA pending a multisig and timelock, with a per-parameter disposition written up in `SECURITY.md`.

```shell
forge build && forge test -vv
# deploy: forge script script/Deploy.s.sol:Deploy --rpc-url $COSTON2_RPC --account lodestar-deployer --broadcast
```
