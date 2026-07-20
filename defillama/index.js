// DefiLlama TVL adapter for Lodestar.
// Drop this into DefiLlama-Adapters/projects/lodestar/index.js at mainnet launch.
//
// Lodestar is no-liquidation, fixed-term lending on Flare: lock yield-bearing collateral
// (FXRP, sFLR, stXRP), borrow USD₮0 at a tier LTV, repay by a deadline. Only the calendar
// can default a loan; price never liquidates.
//
// TVL      = idle USD₮0 in the LodestarPool + collateral (FXRP, sFLR, stXRP) locked in the
//            LodestarLoanBook + the first-loss reserve buffer (USD₮0) held in the book.
// Borrowed = outstanding USD₮0 loaned to borrowers (pool.principalOut). That USD₮0 sits in
//            borrowers' wallets, so it is NOT part of TVL, only reported as `borrowed`.
//
// sumTokensExport reads the on-chain balances the two contracts actually hold, so principal
// that is lent out correctly drops out of TVL automatically.

const { sumTokensExport } = require('../helper/unwrapLPs')

// ---- fill these two from the DeployMainnet broadcast (they do not exist until mainnet deploy) ----
const POOL = '0x0000000000000000000000000000000000000000' // TODO: LodestarPool
const BOOK = '0x0000000000000000000000000000000000000000' // TODO: LodestarLoanBook

// ---- verified Flare mainnet token addresses (fork-proven in the audit) ----
const USDT0 = '0xe7cd86e13AC4309349F30B3435a9d337750fC82D' // 6dp  · pool asset / borrow currency
const FXRP = '0xAd552A648C74D49E10027AB8a618A3ad4901c5bE' //  6dp  · XRP (FAssets)
const SFLR = '0x12e605bc104e93B45e1aD99F9e555f659051c2BB' // 18dp  · Sceptre staked FLR (LST)
const STXRP = '0x4c18ff3c89632c3dd62e796c0afa5c07c4c1b2b3' //  6dp  · Firelight staked XRP (LST)

const tokens = [USDT0, FXRP, SFLR, STXRP]

async function borrowed(api) {
  const principalOut = await api.call({ target: POOL, abi: 'uint256:principalOut' })
  api.add(USDT0, principalOut)
}

module.exports = {
  methodology:
    'TVL counts USD₮0 supplied to the LodestarPool plus collateral (FXRP, sFLR, stXRP) locked in the ' +
    'LodestarLoanBook and its first-loss reserve buffer. Borrowed is the outstanding USD₮0 loaned to ' +
    'borrowers (pool.principalOut), reported separately from TVL.',
  // set `start` to the mainnet deploy block once DeployMainnet has broadcast, so backfill is clean
  start: 0,
  flare: {
    tvl: sumTokensExport({ owners: [POOL, BOOK], tokens }),
    borrowed,
  },
}
