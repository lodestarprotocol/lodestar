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

## Live

- **App:** https://lodestarprotocol.xyz
- **Network:** Coston2 testnet (chainId 114), priced by the live Coston2 FTSOv2
- **Contracts:**
  - `LodestarLoanBook` — [`0x462dB8e9925b1AE2C6Bd35795dC1eFb92c995d62`](https://coston2-explorer.flare.network/address/0x462dB8e9925b1AE2C6Bd35795dC1eFb92c995d62)
  - `LodestarPool` — `0x6a4fBfa36bEa8424e227357C5c9A6df843d9cd95`
  - `LodestarOracle` — `0x7b8C70e81Abd4e248A971262B5BEe5752Df63374`
  - collateral: FTestXRP `0x0b6A…3dc7` · stable: USD₮0 `0xC1A5…E71F`

## Status

v1 — 8/8 tests pass (6 unit + 2 live-Flare fork), security-audited (see `SECURITY.md`), **deployed to Coston2**. Not yet mainnet; owner is a single EOA pending a multisig + timelock.

```shell
forge build && forge test -vv
# deploy: forge script script/Deploy.s.sol:Deploy --rpc-url $COSTON2_RPC --account lodestar-deployer --broadcast
```
