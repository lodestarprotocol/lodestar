import type { Address } from 'viem'

// ---- Coston2 live deployment (v1.6) ----
export const CONTRACTS = {
  FTSO: '0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d' as Address,
  ORACLE: '0x4302410FE3B1Cf99199086453C013783C5a6Bd4c' as Address,
  POOL: '0xe7D4a03f1814F3e5A3A485f2fe16EB5DC1097B8b' as Address,
  BOOK: '0x4Ca4a3a8e14d2e2F1aa29EF7904E8e0Eb7359c47' as Address,
  FXRP: '0x0b6A3645c240605887a5532109323A3E12273dc7' as Address, // FTestXRP, 6dp
  USDT0: '0xC1A5B41512496B80903D1f32d6dEa3a73212E71F' as Address, // USD₮0, 6dp
} as const

// FTSOv2 feed ids
export const FEED = {
  XRP: '0x015852502f55534400000000000000000000000000' as const,
  FLR: '0x01464c522f55534400000000000000000000000000' as const,
}

// token / share decimals — the pool mints 12dp shares over a 6dp asset (USD₮0).
// Getting this wrong is the classic Lodestar bug; keep these explicit.
export const DEC = {
  ASSET: 6, // USD₮0 and FXRP are 6dp
  SHARE: 12, // ERC4626 pool share (decimalsOffset = 6)
} as const

// testnet seed lenders (faucet wallets that supplied USD₮0); active-lender count =
// how many still hold pool shares. Cheap balanceOf reads, no getLogs.
export const SEED_LP: Address[] = [
  '0xCF9071d193E73d3eFcFcA8a9ca4bF72d97545925',
  '0x0368BdDfC65c95E7F6152987f88e5d017e3127Bf',
  '0x53fEA31E7a0Be36D2A8d746eB55b67ea85678Ab2',
  '0x60A2Cc5Fd6487E1BB826740aeD416FA4f93c7Ef1',
  '0xA4b0aB8943ECE0B8cd6eE6Bd26366E9e02fC8987',
  '0x8397dCe925c57bADb3fE48b9107f38C042D0EC34',
  '0x9363210280909D31C138009688bE6566F0c1030b',
  '0xb71e6a22884528F7eFE90388f8A3503716569D2A',
  '0x17f0809f01e6aeb2F8f06Cc58c77Bfb9218e1F30',
  '0xEF080024067C9b4A08DCeC24145A2F9f918d5570',
]

// ---- market config (matches the deployed tiers) ----
export type Tier = { name: string; days: number; ltv: number; fee: number }
export type MarketKey = 'FXRP' | 'STXRP' | 'SFLR'
export type Market = {
  key: MarketKey
  img: string
  name: string
  sub: string
  feed: `0x${string}`
  live: boolean
  tiers: Tier[]
}

export const MARKETS: Record<MarketKey, Market> = {
  FXRP: {
    key: 'FXRP',
    img: '/assets/fxrp.png',
    name: 'FXRP',
    sub: 'XRP · FAsset',
    feed: FEED.XRP,
    live: true,
    tiers: [
      { name: 'Standard', days: 7, ltv: 50, fee: 2.0 },
      { name: 'Extended', days: 30, ltv: 45, fee: 3.5 },
    ],
  },
  STXRP: {
    key: 'STXRP',
    img: '/assets/stxrp.png',
    name: 'stXRP',
    sub: 'Firelight staked XRP',
    feed: FEED.XRP,
    live: false,
    tiers: [
      { name: 'Standard', days: 7, ltv: 50, fee: 2.0 },
      { name: 'Extended', days: 30, ltv: 45, fee: 3.5 },
    ],
  },
  SFLR: {
    key: 'SFLR',
    img: '/assets/sflr.png',
    name: 'sFLR',
    sub: 'Sceptre staked FLR',
    feed: FEED.FLR,
    live: false,
    tiers: [
      { name: 'Short', days: 7, ltv: 55, fee: 2.0 },
      { name: 'Standard', days: 30, ltv: 45, fee: 3.0 },
    ],
  },
}
