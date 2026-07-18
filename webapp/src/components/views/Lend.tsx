import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useProtocol } from '../../hooks/useProtocol'
import { useBalances } from '../../hooks/useBalances'
import { useActions } from '../../hooks/useActions'
import { Card, Stat } from '../ui'
import { ConnectButton } from '../ConnectButton'
import { usd, from6, from12, to6, num, pct } from '../../lib/format'

export function Lend() {
  const { isConnected } = useAccount()
  const p = useProtocol()
  const bal = useBalances()
  const { deposit } = useActions(() => bal.refetch())
  const [amt, setAmt] = useState('')
  const [busy, setBusy] = useState(false)

  const wallet = from6(bal.usdt0)
  const position = from12(bal.shares) * p.sharePrice
  const a = parseFloat(amt) || 0

  const onDeposit = async () => {
    const amount = to6(amt)
    if (amount <= 0n) return
    setBusy(true)
    await deposit(amount)
    setBusy(false)
    setAmt('')
  }

  return (
    <div className="grid lg:grid-cols-[1fr_360px] gap-6 items-start">
      <div className="flex flex-col gap-6">
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <Stat label="Pool size" value={usd(p.tvl)} loading={p.isLoading} />
          <Stat label="Utilization" value={pct(p.utilization)} loading={p.isLoading} />
          <Stat label="Share price" value={p.sharePrice.toFixed(4)} loading={p.isLoading} />
        </div>

        <Card>
          <h2 className="font-bold mb-2">How lending works</h2>
          <p className="text-ink2 text-sm leading-relaxed">
            You supply USD₮0 and receive <b className="text-ink">lodUSD₮0</b> shares. Borrowers pay a
            fixed fee upfront on every loan; the lender share of those fees accrues to the pool, so
            your shares are worth more USD₮0 over time. There are no liquidations to wait on and no
            lockup, redeem your shares back to USD₮0 whenever you want.
          </p>
          <ul className="text-sm text-ink2 mt-4 space-y-2">
            <li className="flex gap-2"><span className="text-ok">✓</span> Yield comes from real borrower fees, not token emissions.</li>
            <li className="flex gap-2"><span className="text-ok">✓</span> Redeemable anytime up to available liquidity.</li>
            <li className="flex gap-2"><span className="text-ok">✓</span> Every loan is over-collateralized and fixed-term.</li>
          </ul>
        </Card>
      </div>

      <Card className="lg:sticky lg:top-24">
        <h2 className="font-bold mb-4">Supply USD₮0</h2>
        {isConnected && (
          <button
            className="text-[12px] text-ink3 hover:text-ink2 mb-2"
            onClick={() => setAmt(String(Math.floor(wallet * 1e6) / 1e6))}
          >
            Balance: {num(wallet)} USD₮0 · Max
          </button>
        )}
        <div className="flex items-center gap-2 bg-panel2 border border-line rounded-xl px-3.5 py-3 focus-within:border-brand/60">
          <input
            className="flex-1 bg-transparent outline-none tabular-nums text-lg"
            inputMode="decimal"
            placeholder="0.00"
            value={amt}
            onChange={(e) => setAmt(e.target.value)}
          />
          <span className="field-suffix">USD₮0</span>
        </div>
        <div className="text-[12px] text-ink3 mt-2">
          ≈ {num(p.sharePrice > 0 ? a / p.sharePrice : a)} lodUSD₮0 shares
        </div>

        {position > 0 && (
          <div className="mt-4 card !bg-panel2 p-3 text-sm">
            <div className="flex justify-between">
              <span className="text-ink2">Your current position</span>
              <span className="font-semibold text-ink tabular-nums">{usd(position)}</span>
            </div>
          </div>
        )}

        <div className="mt-4">
          {!isConnected ? (
            <ConnectButton />
          ) : (
            <button className="btn-primary w-full" disabled={busy || a <= 0} onClick={onDeposit}>
              {busy ? 'Confirming…' : 'Supply USD₮0'}
            </button>
          )}
        </div>
        <p className="text-[12px] text-ink3 mt-3 text-center">Withdraw anytime from the Portfolio tab.</p>
      </Card>
    </div>
  )
}
