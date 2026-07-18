import { defineChain } from 'viem'

// ---- Flare Testnet Coston2 (chainId 114) ----
// Multiple public RPCs so the app fails over instead of blanking when one node 429s.
export const COSTON2_RPCS = [
  'https://coston2-api.flare.network/ext/C/rpc',
  'https://rpc.ankr.com/flare_coston2',
  'https://coston2.enosys.global/ext/C/rpc',
]

export const coston2 = defineChain({
  id: 114,
  name: 'Flare Testnet Coston2',
  nativeCurrency: { name: 'Coston2 Flare', symbol: 'C2FLR', decimals: 18 },
  rpcUrls: {
    default: { http: COSTON2_RPCS },
    public: { http: COSTON2_RPCS },
  },
  blockExplorers: {
    default: { name: 'Coston2 Explorer', url: 'https://coston2-explorer.flare.network' },
  },
  contracts: {
    // canonical Multicall3 (present on Coston2) → lets viem batch all reads into one call
    multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
  },
  testnet: true,
})

export const EXPLORER = coston2.blockExplorers.default.url
