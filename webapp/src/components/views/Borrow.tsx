import { useEffect, useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { MARKETS, type MarketKey, CONTRACTS } from '../../config/contracts'
import { useProtocol } from '../../hooks/useProtocol'
import { useBalances } from '../../hooks/useBalances'
import { useActions } from '../../hooks/useActions'
import { Card } from '../ui'
import { ConnectButton } from '../ConnectButton'
import { usd, priceUsd, from6, to6, dateShort, num } from '../../lib/format'

export function Borrow({ preset }: { preset?: MarketKey }) {
  const { isConnected } = useAccount()
  const p = useProtocol()
  const bal = useBalances()
  const { borrow } = useActions(() => bal.refetch())

  const [coll, setColl] = useState<MarketKey>(preset ?? 'FXRP')
  const [tier, setTier] = useState(0)
  const [amt, setAmt] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (preset) {
      setColl(preset)
      setTier(0)
    }
  }, [preset])

  const m = MARKETS[coll]
  const t = m.tiers[tier]
  const price: Record<MarketKey, number> = { FXRP: p.xrpPrice, STXRP: p.xrpPrice, SFLR: p.flrPrice }
  const px = price[coll]

  const a = parseFloat(amt) || 0
  const quote = useMemo(() => {
    const value = a * px
    const principal = (value * t.ltv) / 100
    const fee = (principal * t.fee) / 100
    const due = Date.now() + t.days * 86400e3
    return { value, principal, fee, receive: principal - fee, due }
  }, [a, px, t])

  const walletBal = coll === 'FXRP' ? from6(bal.fxrp) : 0

  const onBorrow = async () => {
    if (!m.live) return
    const amount = to6(amt)
    if (amount <= 0n) return
    setBusy(true)
    await borrow(CONTRACTS.FXRP, amount, tier)
    setBusy(false)
    setAmt('')
  }

  return (
    <div className="grid lg:grid-cols-[1fr_360px] gap-6 items-start">
      {/* left: form */}
      <div className="flex flex-col gap-6">
        <Card>
          <h2 className="font-bold mb-4">Choose collateral</h2>
          <div className="grid grid-cols-3 gap-2.5">
            {(Object.keys(MARKETS) as MarketKey[]).map((k) => {
              const mk = MARKETS[k]
              const on = k === coll
              return (
                <button
                  key={k}
                  disabled={!mk.live}
                  onClick={() => {
                    setColl(k)
                    setTier(0)
                  }}
                  className={`relative rounded-xl border p-3 text-left transition-colors ${
                    on ? 'border-brand/50 bg-brand/10' : 'border-line hover:border-line/80 bg-panel2'
                  } ${!mk.live ? 'opacity-45 cursor-not-allowed' : ''}`}
                >
                  <img src={mk.img} alt="" className="h-7 w-7 rounded-full" />
                  <div className="font-semibold text-sm mt-2">{mk.name}</div>
                  <div className="text-[11px] text-ink3">{mk.live ? mk.sub : 'Coming soon'}</div>
                </button>
              )
            })}
          </div>
        </Card>

        <Card>
          <h2 className="font-bold mb-4">Term</h2>
          <div className="grid sm:grid-cols-2 gap-2.5">
            {m.tiers.map((tt, i) => (
              <button
                key={i}
                onClick={() => setTier(i)}
                className={`rounded-xl border p-4 text-left transition-colors ${
                  i === tier ? 'border-brand/50 bg-brand/10' : 'border-line hover:border-line/80 bg-panel2'
                }`}
              >
                <div className="font-semibold">{tt.name}</div>
                <div className="text-[13px] text-ink2 mt-0.5">
                  {tt.days} days · {tt.fee}% fee
                </div>
                <div className="text-[12px] text-brand mt-1">up to {tt.ltv}% LTV</div>
              </button>
            ))}
          </div>
        </Card>

        <Card>
          <div className="flex items-center justify-between mb-4">
            <h2 className="font-bold">Lock {m.name}</h2>
            {isConnected && (
              <button
                className="text-[12px] text-ink3 hover:text-ink2"
                onClick={() => setAmt(String(Math.floor(walletBal * 1e6) / 1e6))}
              >
                Balance: {num(walletBal)} {m.name} · Max
              </button>
            )}
          </div>
          <div className="flex items-center gap-2 bg-panel2 border border-line rounded-xl px-3.5 py-3 focus-within:border-brand/60">
            <input
              className="flex-1 bg-transparent outline-none tabular-nums text-lg"
              inputMode="decimal"
              placeholder="0.00"
              value={amt}
              onChange={(e) => setAmt(e.target.value)}
            />
            <span className="field-suffix">{m.name}</span>
          </div>
          <div className="text-[12px] text-ink3 mt-2">
            ≈ {usd(quote.value)} at {px ? priceUsd(px) : '…'} · priced by FTSOv2
          </div>
        </Card>
      </div>

      {/* right: sticky quote */}
      <Card className="lg:sticky lg:top-24">
        <h2 className="font-bold mb-4">Your loan</h2>
        <Row label="You receive" value={usd(quote.receive)} strong />
        <Row label="Fixed fee" value={usd(quote.fee)} />
        <Row label="Repay by deadline" value={usd(quote.principal)} />
        <Row label="Due date" value={dateShort(quote.due)} />
        <div className="h-px bg-line my-4" />
        <p className="text-[13px] text-ink2 leading-relaxed mb-4">
          Locking <b className="text-ink">{num(a)} {m.name}</b> ({usd(quote.value)}) at {t.ltv}% LTV.
          {coll !== 'FXRP' && ` Your ${m.name} keeps earning staking yield the whole term.`} Miss the
          deadline and the only consequence is the loan settles against your collateral, never before.
        </p>
        {!isConnected ? (
          <ConnectButton />
        ) : !m.live ? (
          <button className="btn-ghost w-full" disabled>
            {m.name} coming soon
          </button>
        ) : (
          <button className="btn-primary w-full" disabled={busy || a <= 0} onClick={onBorrow}>
            {busy ? 'Confirming…' : 'Borrow ' + usd(quote.receive)}
          </button>
        )}
      </Card>
    </div>
  )
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex items-center justify-between py-1.5">
      <span className="text-sm text-ink2">{label}</span>
      <span className={`tabular-nums ${strong ? 'text-lg font-bold text-ink' : 'text-ink'}`}>{value}</span>
    </div>
  )
}
