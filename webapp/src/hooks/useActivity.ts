import { useReadContract, useReadContracts } from 'wagmi'
import { CONTRACTS } from '../config/contracts'
import { BOOK_ABI } from '../config/abis'

export type Activity = {
  id: number
  borrower: string
  collAmount: bigint
  principal: bigint
  openedAt: number
  active: boolean
}

// Reads the whole loan book via one multicall and returns recent loans, newest
// first. No getLogs → never rate-limits on the public RPC.
export function useActivity(limit = 12): { items: Activity[]; isLoading: boolean } {
  const { data: nextId } = useReadContract({
    address: CONTRACTS.BOOK,
    abi: BOOK_ABI,
    functionName: 'nextLoanId',
    query: { refetchInterval: 15_000, staleTime: 8_000 },
  })

  const n = nextId ? Number(nextId) : 1
  const ids = n > 1 ? Array.from({ length: n - 1 }, (_, i) => i + 1) : []

  const { data, isLoading } = useReadContracts({
    contracts: ids.map((id) => ({
      address: CONTRACTS.BOOK,
      abi: BOOK_ABI,
      functionName: 'loans' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: ids.length > 0, refetchInterval: 15_000, staleTime: 8_000, placeholderData: (p) => p },
  })

  const items: Activity[] = []
  if (data) {
    data.forEach((r, idx) => {
      if (r.status !== 'success') return
      const L = r.result as readonly [
        string, string, bigint, bigint, bigint, bigint, bigint, bigint, boolean, bigint, bigint,
      ]
      items.push({
        id: ids[idx],
        borrower: L[0] as string,
        collAmount: L[2],
        principal: L[3],
        openedAt: Number(L[6]),
        active: L[8],
      })
    })
  }

  items.sort((a, b) => b.openedAt - a.openedAt)
  return { items: items.slice(0, limit), isLoading }
}

export function timeAgo(unixSec: number): string {
  if (!unixSec) return ''
  const s = Math.max(0, Math.floor(Date.now() / 1000) - unixSec)
  if (s < 60) return s + 's ago'
  const m = Math.floor(s / 60)
  if (m < 60) return m + 'm ago'
  const h = Math.floor(m / 60)
  if (h < 24) return h + 'h ago'
  return Math.floor(h / 24) + 'd ago'
}
