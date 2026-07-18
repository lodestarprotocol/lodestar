import { readContract, writeContract, waitForTransactionReceipt } from '@wagmi/core'
import { useAccount } from 'wagmi'
import { useCallback } from 'react'
import { wagmiConfig } from '../config/wagmi'
import { CONTRACTS } from '../config/contracts'
import { BOOK_ABI, ERC20_ABI, POOL_ABI } from '../config/abis'
import { useToast } from '../lib/toast'
import { errMsg, usd, from6 } from '../lib/format'
import type { Address } from 'viem'

// Ensure `spender` is allowed to pull `amount` of `token` from `owner`; approves if short.
async function ensureAllowance(token: Address, owner: Address, spender: Address, amount: bigint, onApprove: () => void) {
  const current = (await readContract(wagmiConfig, {
    address: token,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: [owner, spender],
  })) as bigint
  if (current >= amount) return
  onApprove()
  const hash = await writeContract(wagmiConfig, {
    address: token,
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [spender, amount],
  })
  await waitForTransactionReceipt(wagmiConfig, { hash })
}

async function balanceOf(token: Address, who: Address): Promise<bigint> {
  return (await readContract(wagmiConfig, { address: token, abi: ERC20_ABI, functionName: 'balanceOf', args: [who] })) as bigint
}

export function useActions(onDone?: () => void) {
  const { address } = useAccount()
  const toast = useToast()

  const borrow = useCallback(
    async (collateral: Address, amount: bigint, tier: number) => {
      if (!address) return
      const id = toast.push('Preparing borrow…')
      try {
        if ((await balanceOf(collateral, address)) < amount) {
          toast.update(id, 'Not enough collateral. Get test tokens from the <a class="underline" href="https://faucet.flare.network/coston2" target="_blank">Flare faucet</a>.', 'err')
          return
        }
        await ensureAllowance(collateral, address, CONTRACTS.BOOK, amount, () => toast.update(id, 'Approving collateral…'))
        toast.update(id, 'Borrowing…')
        const hash = await writeContract(wagmiConfig, { address: CONTRACTS.BOOK, abi: BOOK_ABI, functionName: 'open', args: [collateral, amount, BigInt(tier)] })
        await waitForTransactionReceipt(wagmiConfig, { hash })
        toast.update(id, 'Borrow complete. USD₮0 is in your wallet.', 'ok')
        onDone?.()
      } catch (e) {
        toast.update(id, 'Borrow failed: ' + errMsg(e), 'err')
      }
    },
    [address, toast, onDone],
  )

  const deposit = useCallback(
    async (amount: bigint) => {
      if (!address) return
      const id = toast.push('Preparing deposit…')
      try {
        if ((await balanceOf(CONTRACTS.USDT0, address)) < amount) {
          toast.update(id, 'Not enough USD₮0. Get test tokens from the <a class="underline" href="https://faucet.flare.network/coston2" target="_blank">Flare faucet</a>.', 'err')
          return
        }
        await ensureAllowance(CONTRACTS.USDT0, address, CONTRACTS.POOL, amount, () => toast.update(id, 'Approving USD₮0…'))
        toast.update(id, 'Supplying…')
        const hash = await writeContract(wagmiConfig, { address: CONTRACTS.POOL, abi: POOL_ABI, functionName: 'deposit', args: [amount, address] })
        await waitForTransactionReceipt(wagmiConfig, { hash })
        toast.update(id, "Deposit complete. You're now earning.", 'ok')
        onDone?.()
      } catch (e) {
        toast.update(id, 'Deposit failed: ' + errMsg(e), 'err')
      }
    },
    [address, toast, onDone],
  )

  const repay = useCallback(
    async (loanId: number, due: bigint) => {
      if (!address) return
      const id = toast.push('Preparing repay…')
      try {
        if ((await balanceOf(CONTRACTS.USDT0, address)) < due) {
          toast.update(id, 'You need ' + usd(from6(due)) + ' USD₮0 to repay this loan.', 'err')
          return
        }
        await ensureAllowance(CONTRACTS.USDT0, address, CONTRACTS.POOL, due, () => toast.update(id, 'Approving USD₮0…'))
        toast.update(id, 'Repaying…')
        const hash = await writeContract(wagmiConfig, { address: CONTRACTS.BOOK, abi: BOOK_ABI, functionName: 'repay', args: [BigInt(loanId)] })
        await waitForTransactionReceipt(wagmiConfig, { hash })
        toast.update(id, 'Repaid. Your collateral is back in your wallet.', 'ok')
        onDone?.()
      } catch (e) {
        toast.update(id, 'Repay failed: ' + errMsg(e), 'err')
      }
    },
    [address, toast, onDone],
  )

  const partialRepay = useCallback(
    async (loanId: number, amount: bigint, principal: bigint) => {
      if (!address) return
      if (amount >= principal) {
        toast.push('That covers the whole loan — use Repay to close it.', 'err')
        return
      }
      const id = toast.push('Preparing pay-down…')
      try {
        const minP = (await readContract(wagmiConfig, { address: CONTRACTS.BOOK, abi: BOOK_ABI, functionName: 'minPrincipal' })) as bigint
        if (principal - amount < minP) {
          toast.update(id, 'Leave at least ' + usd(from6(minP)) + ' owed, or use Repay to close the loan.', 'err')
          return
        }
        if ((await balanceOf(CONTRACTS.USDT0, address)) < amount) {
          toast.update(id, 'You need ' + usd(from6(amount)) + ' USD₮0 for this pay-down.', 'err')
          return
        }
        await ensureAllowance(CONTRACTS.USDT0, address, CONTRACTS.POOL, amount, () => toast.update(id, 'Approving USD₮0…'))
        toast.update(id, 'Paying down…')
        const hash = await writeContract(wagmiConfig, { address: CONTRACTS.BOOK, abi: BOOK_ABI, functionName: 'partialRepay', args: [BigInt(loanId), amount, 0n, 0n, 0n] })
        await waitForTransactionReceipt(wagmiConfig, { hash })
        toast.update(id, 'Paid down. Your debt is lower; collateral stays locked until you repay in full.', 'ok')
        onDone?.()
      } catch (e) {
        toast.update(id, 'Pay-down failed: ' + errMsg(e), 'err')
      }
    },
    [address, toast, onDone],
  )

  const withdraw = useCallback(
    async (shares: bigint) => {
      if (!address || shares <= 0n) return
      const id = toast.push('Withdrawing…')
      try {
        const hash = await writeContract(wagmiConfig, { address: CONTRACTS.POOL, abi: POOL_ABI, functionName: 'redeem', args: [shares, address, address] })
        await waitForTransactionReceipt(wagmiConfig, { hash })
        toast.update(id, 'Withdrawn to your wallet.', 'ok')
        onDone?.()
      } catch (e) {
        toast.update(id, 'Withdraw failed: ' + errMsg(e), 'err')
      }
    },
    [address, toast, onDone],
  )

  return { borrow, deposit, repay, partialRepay, withdraw }
}
