import { useReadContracts } from 'wagmi'
import { CONTRACTS, FEED, SEED_LP } from '../config/contracts'
import { FTSO_ABI, POOL_ABI } from '../config/abis'
import { feedPrice, from6, from12 } from '../lib/format'

const pool = { address: CONTRACTS.POOL, abi: POOL_ABI } as const
const ftso = { address: CONTRACTS.FTSO, abi: FTSO_ABI } as const

export type ProtocolStats = {
  tvl: number
  borrowed: number
  available: number
  utilization: number
  sharePrice: number
  activeLoans: number
  lenders: number
  xrpPrice: number
  flrPrice: number
  isLoading: boolean
  isError: boolean
}

// One multicall covers every dashboard number. TanStack Query caches it and
// refetches on an interval, so values stay live without blanking or hammering.
export function useProtocol(): ProtocolStats {
  const { data, isLoading, isError } = useReadContracts({
    contracts: [
      { ...pool, functionName: 'totalAssets' }, // 0
      { ...pool, functionName: 'principalOut' }, // 1
      { ...pool, functionName: 'totalSupply' }, // 2
      { address: CONTRACTS.BOOK, abi: [{ type: 'function', name: 'activeLoanCount', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] }] as const, functionName: 'activeLoanCount' }, // 3
      { ...ftso, functionName: 'getFeedById', args: [FEED.XRP] }, // 4
      { ...ftso, functionName: 'getFeedById', args: [FEED.FLR] }, // 5
      // seed-LP share balances → active lender count (indices 6..)
      ...SEED_LP.map((a) => ({ ...pool, functionName: 'balanceOf' as const, args: [a] as const })),
    ] as any,
    query: {
      refetchInterval: 12_000,
      staleTime: 8_000,
      // keep showing the last good numbers while refetching (no flicker to zero)
      placeholderData: (prev) => prev,
    },
  })

  const ok = <T,>(i: number): T | undefined =>
    data && data[i]?.status === 'success' ? (data[i].result as T) : undefined

  const ta = ok<bigint>(0)
  const po = ok<bigint>(1)
  const ts = ok<bigint>(2)
  const loans = ok<bigint>(3)
  const xrp = ok<readonly [bigint, number, bigint]>(4)
  const flr = ok<readonly [bigint, number, bigint]>(5)

  const tvl = from6(ta)
  const borrowed = from6(po)
  const available = Math.max(0, tvl - borrowed)
  const utilization = tvl > 0 ? (100 * borrowed) / tvl : 0
  const sharePrice = ts && Number(ts) > 0 ? tvl / from12(ts) : 1

  let lenders = 0
  if (data) {
    for (let i = 0; i < SEED_LP.length; i++) {
      const bal = ok<bigint>(6 + i)
      if (bal && bal > 0n) lenders++
    }
  }

  return {
    tvl,
    borrowed,
    available,
    utilization,
    sharePrice,
    activeLoans: loans ? Number(loans) : 0,
    lenders: lenders || (tvl > 0 ? 1 : 0),
    xrpPrice: xrp ? feedPrice(xrp[0], xrp[1]) : 0,
    flrPrice: flr ? feedPrice(flr[0], flr[1]) : 0,
    isLoading,
    isError,
  }
}
