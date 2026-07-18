import { useAccount, useReadContracts } from 'wagmi'
import { CONTRACTS } from '../config/contracts'
import { ERC20_ABI, POOL_ABI } from '../config/abis'

// Wallet balances + the user's pool position, in one cached multicall.
export function useBalances() {
  const { address } = useAccount()
  const enabled = !!address

  const { data, refetch } = useReadContracts({
    contracts: enabled
      ? [
          { address: CONTRACTS.FXRP, abi: ERC20_ABI, functionName: 'balanceOf', args: [address!] },
          { address: CONTRACTS.USDT0, abi: ERC20_ABI, functionName: 'balanceOf', args: [address!] },
          { address: CONTRACTS.POOL, abi: POOL_ABI, functionName: 'balanceOf', args: [address!] },
        ]
      : [],
    query: {
      enabled,
      refetchInterval: 15_000,
      staleTime: 8_000,
      placeholderData: (prev) => prev,
    },
  })

  const val = (i: number): bigint =>
    data && data[i]?.status === 'success' ? (data[i].result as bigint) : 0n

  return {
    fxrp: val(0),
    usdt0: val(1),
    shares: val(2),
    refetch,
  }
}
