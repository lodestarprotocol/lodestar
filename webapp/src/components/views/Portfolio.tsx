import { useState } from 'react'
import { useAccount } from 'wagmi'
import { usePositions, type LoanRow } from '../../hooks/usePositions'
import { useActions } from '../../hooks/useActions'
import { Card, EmptyState } from '../ui'
import { ConnectButton } from '../ConnectButton'
import { usd, from6, from12, to6, dateShort, num } from '../../lib/format'

export function Portfolio() {
  const { isConnected } = useAccount()
  const pos = usePositions()
  const { repay, partialRepay, withdraw } = useActions(() => pos.refetch())

  if (!isConnected) {
    return (
      <Card>
        <div className="text-center py-10">
          <div className="font-semibold mb-1">Not connected</div>
          <div className="text-sm text-ink2 mb-5">Connect a wallet to see your loans and deposits.</div>
          <div className="inline-block"><ConnectButton /></div>
        </div>
      </Card>
    )
  }

  const lendValue = pos.shares > 0n ? from6(pos.lendValue) : 0

  return (
    <div className="flex flex-col gap-6">
      {/* lend position */}
      <Card>
        <div className="flex items-center justify-between mb-4">
          <h2 className="font-bold">Your deposit</h2>
          <a href="#lend" className="text-[13px] text-brand hover:underline">Supply more</a>
        </div>
        {pos.shares > 0n ? (
          <div className="flex items-center justify-between bg-panel2 border border-line rounded-xl p-4">
            <div>
              <div className="text-xl font-bold tabular-nums">{usd(lendValue)}</div>
              <div className="text-[12px] text-ink3">
                {num(from12(pos.shares))} lodUSD₮0 · redeemable anytime
              </div>
            </div>
            <button className="btn-ghost" onClick={() => withdraw(pos.shares)}>Withdraw</button>
          </div>
        ) : (
          <EmptyState title="No deposit" sub="Supply USD₮0 to start earning fees." />
        )}
      </Card>

      {/* loans */}
      <Card>
        <h2 className="font-bold mb-4">Your loans</h2>
        {pos.loans.length === 0 ? (
          <EmptyState title="No open loans" sub="Lock collateral on the Borrow tab to get USD₮0." />
        ) : (
          <div className="flex flex-col gap-3">
            {pos.loans.map((l) => (
              <LoanCard key={l.id} loan={l} onRepay={repay} onPartial={partialRepay} />
            ))}
          </div>
        )}
      </Card>
    </div>
  )
}

function LoanCard({
  loan,
  onRepay,
  onPartial,
}: {
  loan: LoanRow
  onRepay: (id: number, due: bigint) => Promise<void>
  onPartial: (id: number, amount: bigint, principal: bigint) => Promise<void>
}) {
  const [showPartial, setShowPartial] = useState(false)
  const [payAmt, setPayAmt] = useState('')
  const due = loan.principal // repay amount = principal owed

  const overdue = loan.dueAt * 1000 < Date.now()

  return (
    <div className="bg-panel2 border border-line rounded-xl p-4">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div>
          <div className="font-semibold">{num(from6(loan.collAmount))} FXRP locked</div>
          <div className="text-[12px] text-ink3">
            borrowed {usd(from6(loan.principal))} · repay {usd(from6(due))} by{' '}
            <span className={overdue ? 'text-danger' : ''}>{dateShort(loan.dueAt * 1000)}</span>
          </div>
        </div>
        <div className="flex gap-2">
          <button className="btn-ghost !py-1.5 !px-3 text-[13px]" onClick={() => setShowPartial((s) => !s)}>
            Pay down
          </button>
          <button className="btn-danger !py-1.5 !px-3 text-[13px]" onClick={() => onRepay(loan.id, due)}>
            Repay
          </button>
        </div>
      </div>
      {showPartial && (
        <div className="mt-3 pt-3 border-t border-line flex items-center gap-2 flex-wrap justify-end">
          <span className="text-[12px] text-ink3 mr-auto">Pay down part of the debt; collateral stays locked.</span>
          <div className="flex items-center gap-2 bg-base border border-line rounded-lg px-3 py-2 max-w-[180px]">
            <input
              className="w-full bg-transparent outline-none tabular-nums text-sm"
              inputMode="decimal"
              placeholder="Amount"
              value={payAmt}
              onChange={(e) => setPayAmt(e.target.value)}
            />
            <span className="field-suffix text-[12px]">USD₮0</span>
          </div>
          <button
            className="btn-danger !py-1.5 !px-3 text-[13px]"
            onClick={() => onPartial(loan.id, to6(payAmt), loan.principal)}
          >
            Confirm
          </button>
        </div>
      )}
    </div>
  )
}
