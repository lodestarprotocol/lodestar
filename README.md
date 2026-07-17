# Lodestar ⛓️ — no-liquidation, fixed-term lending on Flare

> Borrow USDT0 against your FXRP / sFLR. **No margin calls, no health factor — only the calendar can default you.** [belay = the climbing rope that catches your fall]

Lodestar is a Bowline-style fixed-term lending protocol, redesigned for Flare. Lock
yield-bearing collateral, receive USDT0 at a tier LTV, repay by a deadline. A price
crash can never liquidate you; the only thing that can is missing your deadline — and
even then, after a grace window, a keeper settles behind an FTSO price floor, lenders are
made whole first, and any surplus (including collateral yield) returns to you.

## Why it's better than Bowline, and native to Flare

1. **Yield-bearing collateral keeps working.** Locked sFLR keeps earning staking + FlareDrops; its appreciation returns to the borrower on repay (a built-in rebate Bowline's dead memecoin/stock collateral cannot offer). Optional lender-side skim can instead route yield to lenders to beat Kinetic's ~13–17% supply APY.
2. **FTSOv2 native oracle** — enshrined, decentralized, free, flash-loan-resistant. No Chainlink dependency (the exact trust model Cyclo proved works on Flare).
3. **Higher LTV on quality collateral** — FXRP/sFLR are far less volatile than memecoins, so 50–60% LTV vs Bowline's 20–30% meme tiers. That's the capital efficiency Kinetic borrowers actually want, minus the liquidation risk.
4. **Fee-only, no token** — lenders earn borrower fees + (optional) collateral yield; no emissions, no inflation.

## The market thesis (on-chain, July 2026)

- Flare has **$12.5M actively borrowed on Kinetic** — real borrow demand.
- **FXRP is the dominant collateral** ($23.7M supplied to Kinetic) and stablecoin borrow APY runs **13–17%** — a market screaming for stablecoin liquidity against volatile collateral.
- Cyclo (the only no-liq option) is **declining** ($1.06M → $172k) — but its mechanism is broken (lock $1, sell a floating $0.26 token), so the *category* is untested with a clean product. Lodestar is that clean product.

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
- **Contracts (v1.3.2):**
  - `LodestarLoanBook` — [`0x15A37F0AF4559684A88C2Af16378530cB37a38c1`](https://coston2-explorer.flare.network/address/0x15A37F0AF4559684A88C2Af16378530cB37a38c1)
  - `LodestarPool` — `0x91265e26F8488890Df5b6BB2cded8eFFb99Ed2A4`
  - `LodestarOracle` — `0xdA022A1643D7CdfDC8822acf7018D79b0c0FD643`
  - collateral: FTestXRP `0x0b6A…3dc7` · stable: USD₮0 `0xC1A5…E71F`

## Status

v1.3.2 — **76/76 tests pass** (30 unit + 4 oracle-decimals fuzz + 9 adversarial + 6 core
invariants + 9 stress invariants + 8 economic-game + 4 live-Flare fork, plus the deep
invariant campaign at 512×500). Three-part adversarial review complete (see `SECURITY.md`);
no CRITICAL/HIGH fund-theft path, findings hardened. **Deployed to Coston2.** Not yet
mainnet; owner is a single EOA pending a multisig + timelock (the remaining blocker).

```shell
forge build && forge test -vv
# deploy: forge script script/Deploy.s.sol:Deploy --rpc-url $COSTON2_RPC --account lodestar-deployer --broadcast
```
