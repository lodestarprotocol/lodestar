# Lodestar mainnet launch runbook

Ordered steps. Nothing here is irreversible until step 5. The deploy script refuses to run with any
unverified (immutable) address, so a wrong token/feed cannot slip through.

## 0. Prerequisites (in progress)
- [x] External audit complete.
- [x] Deploy wallet `0x59b7fb215e9C73A25B358929462A107E1fEc5088` (vanity, ends 88). Key sealed in
      `C:\Users\cyber\lodestar-deploy\wallets\deploy.pk` (never printed).
- [ ] **Fund the deploy wallet with FLR** (send to the address above; gas for ~3 deploys + wiring, ~50-100 FLR is ample).
- [x] Mainnet FtsoV2 resolved on-chain: `0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20` (filled in DeployMainnet.s.sol).
- [x] 5 multisig signer wallets generated (`wallets/signer_1..5.key`).

## 1. Fill the remaining mainnet addresses in `script/DeployMainnet.s.sol`
These must be VERIFIED against official sources (they are immutable):
- `USDT0`  - USD₮0 (Tether omnichain) token on Flare mainnet, 6dp.
- `FXRP`   - FAssets FXRP token on Flare mainnet, 6dp.
- `SFLR` + `SFLR_RATE`  - Sceptre sFLR (candidate `0x12e605bc104e93B45e1aD99F9e555f659051c2BB`) + its rate provider. *Optional* — leave 0 to launch FXRP-only.
- `STXRP` + `STXRP_RATE` - stXRP + rate provider. *Optional*.
- `SPARKDEX` / `ENOSYS` / `BLAZESWAP` - settlement routers. *Optional* (buyout works with none whitelisted).
Also review: tier LTV/duration/fee, `HAIRCUT_LST`, `CAP_LAUNCH_USD18` (start small), `MIN_PRINCIPAL`.

## 2. Create the governance Safe (you control it)
- Open the Flare Safe UI, connect one signer, create a **3-of-5** Safe with the five signer addresses.
- Record the Safe address. (Reminder: before it holds real deposits, move at least 3 of the 5 keys
  to separate devices/hardware — 5 keys in one folder is a multisig in name only.)

## 3. Deploy (point at OUR node for speed + privacy)
```
export DEPLOYER=0x59b7fb215e9C73A25B358929462A107E1fEc5088
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url http://127.0.0.1:9650/ext/bc/C/rpc \
  --private-key $(cat /c/Users/cyber/lodestar-deploy/wallets/deploy.pk) \
  --broadcast --slow
```
Record the printed Oracle / Pool / Book addresses.

## 4. Verify on-chain BEFORE handing over control
- `oracle.feeds(FXRP/…)` set with correct feedId, rateProvider, maxStale (<=1h), haircut.
- `book.tiers`, `exposureCapUsd18`, `minPrincipal`, whitelisted routers all correct.
- `pool.loanBook() == book`, and `owner()` on all three still == deployer.
- Optionally open one tiny loan and repay it end-to-end.

## 5. Hand ownership to the Safe (point of no return)
```
export ORACLE=0x... POOL=0x... BOOK=0x... MULTISIG=0x<safe>
export RESERVE=0x<treasury>   # optional: revenue destination; defaults to the Safe
forge script script/TransferOwnership.s.sol:TransferOwnership \
  --rpc-url http://127.0.0.1:9650/ext/bc/C/rpc \
  --private-key $(cat /c/Users/cyber/lodestar-deploy/wallets/deploy.pk) --broadcast --slow
```
The script first moves the reserve OFF the hot deploy EOA (to RESERVE, default the Safe) so withdrawn
profit + yield-skim route to the treasury, then transfers ownership and asserts all three report
`owner() == Safe` and `reserve() == RESERVE`.

## 6. Bootstrap + go live
- Seed the lender pool with USD₮0 (the deploy already seeds any USD₮0 the deployer holds; add more via `pool.deposit`).
- Point the keeper at mainnet: edit `C:\Users\cyber\lodestar-keeper\config.json` (rpc -> `http://127.0.0.1:9650/ext/bc/C/rpc`,
  chain_id 14, mainnet book/pool/oracle/stable/collaterals, fill `routers`, set `dry_run` false), put the
  keeper key in `.keeper` (chmod 600), deploy to the Netcup node under pm2 (own key, no clash with mystic).
- Update the dapp to mainnet addresses + partial-repay UI + FAQ.
- Wire monitoring/alerts (share price, utilization, impairment, defaults).
