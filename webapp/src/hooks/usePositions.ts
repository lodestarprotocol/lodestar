import { useAccount, useReadContract, useReadContracts } from 'wagmi'
import { CONTRACTS } from '../config/contracts'
import { BOOK_ABI, POOL_ABI } from '../config/abis'

export type LoanRow = {
  id: number
  collAmount: bigint
  principal: bigint
  dueAt: number
}

export type Positions = {
  loans: LoanRow[]
  shares: bigint
  lendValue: bigint
  isLoading: boolean
  refetch: () => void
}

// Reads nextLoanId, then fans out loans(1..n) in one multicall, filtered to the
// connected wallet's active loans. Also pulls the lend position value.
export function usePositions(): Positions {
  const { address } = useAccount()
  const enabled = !!address

  const { data: nextId } = useReadContract({
    address: CONTRACTS.BOOK,
    abi: BOOK_ABI,
    functionName: 'nextLoanId',
    query: { enabled, refetchInterval: 15_000, staleTime: 8_000 },
  })

  const n = nextId ? Number(nextId) : 1
  const ids = n > 1 ? Array.from({ length: n - 1 }, (_, i) => i + 1) : []

  const { data: loanData, isLoading, refetch: refetchLoans } = useReadContracts({
    contracts: ids.map((id) => ({
      address: CONTRACTS.BOOK,
      abi: BOOK_ABI,
      functionName: 'loans' as const,
      args: [BigInt(id)] as const,
    })),
    query: { enabled: enabled && ids.length > 0, refetchInterval: 15_000, staleTime: 8_000, placeholderData: (p) => p },
  })

  const { data: lend, refetch: refetchLend } = useReadContracts({
    contracts: enabled
      ? [
          { address: CONTRACTS.POOL, abi: POOL_ABI, functionName: 'balanceOf', args: [address!] },
        ]
      : [],
    query: { enabled, refetchInterval: 15_000, staleTime: 8_000, placeholderData: (p) => p },
  })

  const shares = lend && lend[0]?.status === 'success' ? (lend[0].result as bigint) : 0n

  const { data: valueData, refetch: refetchVal } = useReadContract({
    address: CONTRACTS.POOL,
    abi: POOL_ABI,
    functionName: 'convertToAssets',
    args: [shares],
    query: { enabled: enabled && shares > 0n, refetchInterval: 15_000, staleTime: 8_000 },
  })

  const loans: LoanRow[] = []
  if (loanData && address) {
    const lower = address.toLowerCase()
    loanData.forEach((r, idx) => {
      if (r.status !== 'success') return
      const L = r.result as readonly [
        string, string, bigint, bigint, bigint, bigint, bigint, bigint, boolean, bigint, bigint,
      ]
      const active = L[8]
      const borrower = (L[0] as string).toLowerCase()
      if (active && borrower === lower) {
        loans.push({ id: ids[idx], collAmount: L[2], principal: L[3], dueAt: Number(L[7]) })
      }
    })
  }

  return {
    loans,
    shares,
    lendValue: shares > 0n && valueData ? (valueData as bigint) : 0n,
    isLoading,
    refetch: () => {
      refetchLoans()
      refetchLend()
      refetchVal()
    },
  }
}
