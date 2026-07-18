import { useState } from 'react'
import { Card } from '../ui'
import { usd, pct } from '../../lib/format'

export function Economics() {
  const [out, setOut] = useState(500000)
  const [turn, setTurn] = useState(12)
  const [fee, setFee] = useState(2.5)
  const [split, setSplit] = useState(20)

  const gross = out * (fee / 100) * turn
  const proto = gross * (split / 100)
  const lenders = gross - proto
  const apy = out > 0 ? (lenders / out) * 100 : 0

  return (
    <div className="flex flex-col gap-6 max-w-3xl">
      <Card>
        <h2 className="text-xl font-bold mb-2">Protocol fee model</h2>
        <p className="text-ink2 leading-relaxed">
          There is no interest rate curve. Each loan pays one fixed fee upfront. That fee is split
          between lenders (the option premium they earn) and the protocol reserve (which backstops
          rare shortfalls). Move the sliders to see how the numbers flow.
        </p>
      </Card>

      <Card>
        <div className="grid sm:grid-cols-2 gap-x-8 gap-y-5">
          <Slider label="Average borrowed" value={out} min={10000} max={5000000} step={10000} fmt={usd} onChange={setOut} />
          <Slider label="Loan turnover / yr" value={turn} min={1} max={52} step={1} fmt={(v) => v + '×'} onChange={setTurn} />
          <Slider label="Fixed fee" value={fee} min={0.5} max={6} step={0.1} fmt={(v) => v.toFixed(1) + '%'} onChange={setFee} />
          <Slider label="Protocol share" value={split} min={0} max={50} step={1} fmt={(v) => v + '%'} onChange={setSplit} />
        </div>
      </Card>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <MiniStat label="Gross fees / yr" value={usd(gross)} />
        <MiniStat label="To protocol" value={usd(proto)} />
        <MiniStat label="To lenders" value={usd(lenders)} />
        <MiniStat label="Lender APY" value={pct(apy)} accent />
      </div>

      <Card>
        <h3 className="font-bold mb-3">Why fixed fees beat interest curves here</h3>
        <ul className="space-y-3 text-sm text-ink2">
          <li className="flex gap-3"><Dot /> <span>Borrowers know their total cost the instant they open the loan, no rate can drift against them.</span></li>
          <li className="flex gap-3"><Dot /> <span>Fees are collected upfront, so the pool is paid before it takes any duration risk.</span></li>
          <li className="flex gap-3"><Dot /> <span>The protocol share compounds into a reserve that absorbs the occasional walk-away loss.</span></li>
        </ul>
      </Card>
    </div>
  )
}

function Slider({
  label, value, min, max, step, fmt, onChange,
}: {
  label: string; value: number; min: number; max: number; step: number; fmt: (v: number) => string; onChange: (v: number) => void
}) {
  return (
    <div>
      <div className="flex justify-between mb-1.5">
        <span className="text-sm text-ink2">{label}</span>
        <span className="text-sm font-semibold tabular-nums">{fmt(value)}</span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="w-full accent-brand"
      />
    </div>
  )
}

function MiniStat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="card p-4">
      <div className="stat-label">{label}</div>
      <div className={`mt-1.5 text-xl font-bold tabular-nums ${accent ? 'text-ok' : 'text-ink'}`}>{value}</div>
    </div>
  )
}

function Dot() {
  return <span className="mt-1.5 h-1.5 w-1.5 rounded-full bg-brand shrink-0" />
}
