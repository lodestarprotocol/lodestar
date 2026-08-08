# Dapp mainnet switchover checklist

What must change in `web/index.html` when the protocol goes live on Flare mainnet.
Everything here is testnet-specific and will silently misbehave if left as is.

Verified against the file on 2026-08-08. Line numbers drift, so grep the strings.

> **`web/` is the Cloudflare Pages output directory. Every file in it is served publicly at
> lodestarprotocol.xyz, including anything that is not linked from the page.** This checklist and the
> dapp test scripts both used to live there and were reachable to anyone who guessed the path. Notes
> belong at the repo root next to `LAUNCH_RUNBOOK.md`, tooling in `tools/`. Before launch, run
> `git ls-files web/` and confirm you would be comfortable with a stranger reading every line of every
> file listed.

## 1. Network

- `RPCS` — Coston2 endpoints. Replace with Flare mainnet RPCs. Keep at least three,
  and keep the failover order: the first entry is what wallets get registered with.
- `CHAIN_HEX` `0x72` (114) → `0xe` (14). `CHAIN_NAME` → `Flare Mainnet`.
- `wallet_addEthereumChain` block: `nativeCurrency` C2FLR → FLR, `blockExplorerUrls`
  → `https://flare-explorer.flare.network`.
- Two hardcoded `Not connected<small>Coston2 · chainId 114</small>` strings (sidebar
  markup and the disconnect handler).

## 1b. The CSP in `web/_headers` (changing RPCS alone takes the dapp down)

`_headers` pins `connect-src` to an explicit allowlist, and every host in it is a Coston2 one:

```
connect-src 'self' https://coston2-api.flare.network https://rpc.ankr.com
            https://coston2.enosys.global https://coston2-explorer.flare.network wss:
```

Point `RPCS` at Flare mainnet without editing this and the browser blocks every RPC call
before it leaves the page. The dapp does not error, it just never fills in: no TVL, no tiers,
no prices, and `friendlyErr` never sees it because the request was refused client-side. The
only trace is a CSP violation in the console, which is not where anyone looks first.

Add each mainnet RPC host, plus the mainnet explorer, to `connect-src` in the SAME commit that
changes `RPCS`. `https://rpc.ankr.com` is already host-wide so an ankr mainnet path survives;
nothing else does. Verify after deploy by loading the site with the console open and confirming
zero `Refused to connect` lines, not merely that the page rendered.

## 2. Contracts and tokens

Every address in this section is immutable once users are transacting against it. Check each
against `src/flare/FlareAddresses.sol`, which is the single source of truth the deploy script and
the fork tests both use — do not retype them from here.

- `ORACLE`, `POOL`, `BOOK` → the mainnet deploy addresses (from the DeployMainnet broadcast).
- `FXRP_ADDR` → `0xAd552A648C74D49E10027AB8a618A3ad4901c5bE`.
- **`USDT0_ADDR` → `0xe7cd86e13AC4309349F30B3435a9d337750fC82D`.** Currently the Coston2 USD₮0.
  Missed by every earlier version of this checklist. Leave it and the Supply form, the wallet
  balance and every repay/extend approval point at a token that does not exist on mainnet — the
  user is asked to approve an address with no code, and their real USD₮0 balance shows as zero.
- **`FTSO` → `0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20`.** Currently the Coston2 FtsoV2. Also
  missed by earlier versions. Prices are read from `LodestarOracle` for anything with an address
  (see §4), so this is the fallback path rather than the main one, but it is still wrong.
- **`MK.STXRP.addr` and `MK.SFLR.addr` are empty strings.** Fill them with the mainnet
  token addresses (stXRP `0x4c18ff3c89632c3dd62e796c0afa5c07c4c1b2b3`,
  sFLR `0x12e605bc104e93B45e1aD99F9e555f659051c2BB`). Until they are filled, those two
  markets fall back to the local `rate`/`hc` estimate instead of the oracle, which is
  exactly the drift this design removes. This is the single most important line here.
- `CDEC` already carries `SFLR:18`; confirm against the deployed token before launch. This is now
  load-bearing for correctness, not just display — see below.
- Drop `soon:true` from STXRP/SFLR once their tiers exist on chain, and set `live:true`.
- **No longer a manual step:** `ADDR2MK` is derived from `MK[k].addr` by `buildAddr2Mk()`. Filling
  the address above is sufficient; loan rows can no longer mislabel collateral because someone
  forgot a second list.

> **This section used to be actively dangerous.** Before 2026-08-08 the borrow path hardcoded FXRP:
> it approved `FXRP_ADDR`, opened with `FXRP_ADDR` as collateral, and parsed the input amount at a
> fixed `1e6`. Setting `live:true` on sFLR (18dp) as instructed above would therefore have asked an
> sFLR borrower to approve **FXRP**, and — if they happened to hold FXRP — opened a loan against
> **FXRP collateral** for **10^12 times** the amount they typed, while the form, the quote and the
> LTV all described sFLR. Nothing reverts on that path; it produces a valid loan of the wrong asset
> in the wrong size.
>
> The dapp now drives the whole borrow path off `MK[COLL]` and `CDEC` (`uColl`/`collNum`/`fillAmt`),
> and refuses outright to transact against a collateral whose `addr` is still empty, so a
> half-finished switchover fails loudly instead of signing to nowhere. Verified for both 6dp and
> 18dp, including that `0.123456789012345678` sFLR survives parsing exactly.
>
> **After the switchover, before announcing: open one small loan in EACH live collateral and check
> the block explorer shows the token you selected, in the amount you typed.** That is the check that
> would have caught this.

## 3. Explorer and faucet

- `EXPLORER` const and the footer explorer link → `https://flare-explorer.flare.network`
  (Blockscout, same API shape, so `holders_count` keeps working).
- Remove the "Get test tokens" nav item and the remaining `faucet.flare.network` references
  (borrow hint, lend hint, onboarding modal, quest copy). There is no mainnet faucet; leaving them
  makes the app look like a testnet. **Set the `FAUCET` const to `""` first** — the borrow error
  path reads it and drops the faucet link automatically when it is empty, so that one is handled.
- The network badge reads from `NET_LABEL`, so set that once rather than editing badge markup.
  Grep for any remaining literal `Coston2` afterwards; the sidebar "Not connected" strings in §1
  are separate and still manual.

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

## 6. Capacity pre-checks (add before mainnet)

Two owner-set limits make `open()` revert with no friendly message. Neither binds on
testnet, but the guarded launch sets a $25k cap per collateral, so on mainnet they will
bind early and a user deserves a reason rather than a failed transaction.

- ~~**`exposureCapUsd18(collateral)`** vs `exposureUsd18(collateral)`~~ **DONE 2026-08-02.**
  Both are read per market with the other stats and `doBorrow` quotes the room left before
  the wallet is touched. A cap of `0` is uncapped on chain and a cap that failed to read is
  not a reason to refuse, so it only acts on a real number. This one matters most at launch:
  a $25k cap against a $100 `minPrincipal` binds at ~250 loans, well before the 400 slots.
- ~~**`maxActiveLoans`** vs `activeLoanCount()`~~ **DONE 2026-08-02.** `maxActiveLoans` is
  read with the other stats and `doBorrow` refuses with a plain-English reason before
  touching the wallet. Verified on the live book at 396/400 with a forced-full negative
  control. Only `open()` consumes a slot, so the message says supplying, repaying and
  extending still work, which is accurate.

Both now sit next to the existing minimum-loan pre-check in `doBorrow`. Neither gates the
preview yet, so the summary can still quote a loan the contract would refuse; the button
stops it, which is the part that costs gas.

## 7. Parameters already read from chain (do not re-hardcode)

Verified live on 2026-07-27 with negative controls. Anything added later that displays a
protocol value should follow the same rule: read it, do not print a literal.

- Prices via `LodestarOracle.priceUsd18` per collateral (counted value); market price derived
  from it using the on-chain haircut, NOT the local `hc` estimate
- Haircut via `LodestarOracle.feeds(collateral)` `haircutBps` (owner-mutable; drives the
  market-vs-counted split on tiles, borrow summary, and preview — verified 2026-07-29 with a
  poisoned-local negative control)
- Tiers (LTV, term, fee) via `tiers(collateral, i)`
- Fee split via `feeReserveBps` (drives APY, distribution amounts, labels, bar widths)
- `gracePeriod`, `settleStartBps`, `settleFloorMinBps`, `settleDecayPeriod`
- `maxUtilizationBps`, `minPrincipal`, `maxLoanLife`, `paused`
