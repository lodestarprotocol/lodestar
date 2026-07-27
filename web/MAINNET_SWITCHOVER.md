# Dapp mainnet switchover checklist

What must change in `web/index.html` when the protocol goes live on Flare mainnet.
Everything here is testnet-specific and will silently misbehave if left as is.

Verified against the file on 2026-07-27. Line numbers drift, so grep the strings.

## 1. Network

- `RPCS` — Coston2 endpoints. Replace with Flare mainnet RPCs. Keep at least three,
  and keep the failover order: the first entry is what wallets get registered with.
- `CHAIN_HEX` `0x72` (114) → `0xe` (14). `CHAIN_NAME` → `Flare Mainnet`.
- `wallet_addEthereumChain` block: `nativeCurrency` C2FLR → FLR, `blockExplorerUrls`
  → `https://flare-explorer.flare.network`.
- Two hardcoded `Not connected<small>Coston2 · chainId 114</small>` strings (sidebar
  markup and the disconnect handler).

## 2. Contracts and tokens

- `ORACLE`, `POOL`, `BOOK` → the mainnet deploy addresses (from the DeployMainnet broadcast).
- `FXRP_ADDR` → `0xAd552A648C74D49E10027AB8a618A3ad4901c5bE`.
- **`MK.STXRP.addr` and `MK.SFLR.addr` are empty strings.** Fill them with the mainnet
  token addresses (stXRP `0x4c18ff3c89632c3dd62e796c0afa5c07c4c1b2b3`,
  sFLR `0x12e605bc104e93B45e1aD99F9e555f659051c2BB`). Until they are filled, those two
  markets fall back to the local `rate`/`hc` estimate instead of the oracle, which is
  exactly the drift this design removes. This is the single most important line here.
- `ADDR2MK` maps only FXRP. Add stXRP and sFLR or loan rows will mislabel collateral.
- `CDEC` already carries `SFLR:18`; confirm against the deployed token before launch.
- Drop `soon:true` from STXRP/SFLR once their tiers exist on chain, and set `live:true`.

## 3. Explorer and faucet

- `EXPLORER` const and the footer explorer link → `https://flare-explorer.flare.network`
  (Blockscout, same API shape, so `holders_count` keeps working).
- Remove the "Get test tokens" nav item and all seven `faucet.flare.network` references
  (borrow hint, lend hint, onboarding modal, quest copy). There is no mainnet faucet;
  leaving them makes the app look like a testnet.
- `Coston2 Testnet` badges (sidebar chip and topbar pill) → mainnet styling, or remove.

## 4. Things that are already correct

- Prices come from `LodestarOracle.priceUsd18` per collateral, so staking-rate drift and
  the v1.8 rate clamp are both handled automatically once the addresses above are set.
- Tiers, `minPrincipal`, `maxLoanLife` and the Extend panel all read on chain.
- Gas padding (estimate x1.4 + 50k) on all writes, needed for sweep-bearing txs.

## 5. Known follow-ups, not blockers

- The stats refresh multicalls **every loan** each cycle to compute lifetime fees,
  borrower count and the activity feed. At 900 loans on testnet this is already heavy
  and it grows without bound. Cap it (last N loans) or cache it before real volume.
- `tierDisabled` (v1.8) is probed in the Extend panel only. If a tier is ever retired,
  the borrow form should stop offering it too.
