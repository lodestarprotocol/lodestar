import { createConfig, fallback, http } from 'wagmi'
import { injected } from 'wagmi/connectors'
import { coston2, COSTON2_RPCS } from './chain'

// fallback() rotates through RPCs on failure; batch.multicall coalesces every
// read this frame into a single Multicall3 call → fast, never hammers one node.
const transport = fallback(
  COSTON2_RPCS.map((url) =>
    http(url, {
      batch: { batchSize: 512, wait: 16 },
      retryCount: 2,
      retryDelay: 300,
    }),
  ),
  { rank: false },
)

export const wagmiConfig = createConfig({
  chains: [coston2],
  connectors: [injected({ shimDisconnect: true })],
  transports: { [coston2.id]: transport },
  batch: { multicall: { batchSize: 1024, wait: 16 } },
  cacheTime: 4_000,
  pollingInterval: 12_000,
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
