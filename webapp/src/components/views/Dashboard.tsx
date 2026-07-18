import { useProtocol } from '../../hooks/useProtocol'
import { MARKETS, type MarketKey } from '../../config/contracts'
import { Stat, Card, LivePill } from '../ui'
import { RecentActivity } from '../RecentActivity'
import { usd, priceUsd, pct } from '../../lib/format'

export function Dashboard({ onBorrow }: { onBorrow: (m: MarketKey) => void }) {
  const p = useProtocol()
  const loading = p.isLoading

  const prices: Record<MarketKey, number> = {
    FXRP: p.xrpPrice,
    STXRP: p.xrpPrice,
    SFLR: p.flrPrice,
  }

  return (
    <div className="flex flex-col gap-6">
      {/* hero */}
      <Card className="!p-6 sm:!p-8 relative overflow-hidden">
        <div className="relative z-10 max-w-2xl">
          <div className="pill-ok mb-3">No liquidations · fixed term</div>
          <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight">
            Borrow against your assets without the liquidation risk.
          </h1>
          <p className="text-ink2 mt-3 leading-relaxed">
            Lock FXRP, sFLR or stXRP, borrow USD₮0 at one fixed fee, and keep your collateral
            safe until your deadline. No health factor to babysit, no surprise liquidations.
          </p>
          <div className="flex gap-3 mt-5">
            <a href="#borrow" className="btn-primary">Borrow now</a>
            <a href="#lend" className="btn-ghost">Supply &amp; earn</a>
          </div>
        </div>
        <div className="absolute -right-16 -top-16 h-64 w-64 rounded-full bg-brand/10 blur-3xl" />
      </Card>

      {/* stats */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <Stat label="Total supplied" value={usd(p.tvl)} sub="USD₮0 in the pool" loading={loading} />
        <Stat label="Borrowed" value={usd(p.borrowed)} sub={pct(p.utilization) + ' utilization'} loading={loading} />
        <Stat label="Active loans" value={String(p.activeLoans)} sub={p.lenders + ' lenders'} loading={loading} />
        <Stat label="Share price" value={p.sharePrice.toFixed(4)} sub="lodUSD₮0 → USD₮0" loading={loading} />
      </div>

      {/* markets */}
      <Card className="!p-0 overflow-hidden">
        <div className="flex items-center justify-between px-5 sm:px-6 py-4 border-b border-line">
          <h2 className="font-bold">Markets</h2>
          <LivePill>Prices live · FTSOv2</LivePill>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[640px]">
            <thead>
              <tr className="text-ink3 text-left">
                <th className="font-medium px-5 sm:px-6 py-3">Collateral</th>
                <th className="font-medium px-4 py-3">Price</th>
                <th className="font-medium px-4 py-3">Max LTV</th>
                <th className="font-medium px-4 py-3">Term</th>
                <th className="font-medium px-4 py-3">Fee from</th>
                <th className="font-medium px-4 py-3">Status</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody>
              {(Object.keys(MARKETS) as MarketKey[]).map((k) => {
                const m = MARKETS[k]
                const lo = Math.min(...m.tiers.map((t) => t.days))
                const hi = Math.max(...m.tiers.map((t) => t.days))
                const ml = Math.max(...m.tiers.map((t) => t.ltv))
                const mf = Math.min(...m.tiers.map((t) => t.fee))
                return (
                  <tr key={k} className="border-t border-line/60 hover:bg-panel2/40">
                    <td className="px-5 sm:px-6 py-3.5">
                      <div className="flex items-center gap-3">
                        <img src={m.img} alt={m.name} className="h-8 w-8 rounded-full" />
                        <div>
                          <div className="font-semibold text-ink">{m.name}</div>
                          <div className="text-[12px] text-ink3">{m.sub}</div>
                        </div>
                      </div>
                    </td>
                    <td className="px-4 py-3.5 tabular-nums text-ink">
                      {prices[k] ? priceUsd(prices[k]) : <span className="skeleton inline-block h-4 w-14 rounded" />}
                    </td>
                    <td className="px-4 py-3.5"><span className="pill">{ml}%</span></td>
                    <td className="px-4 py-3.5 font-mono text-ink2">{lo}–{hi}d</td>
                    <td className="px-4 py-3.5 font-mono text-ink2">{mf.toFixed(1)}%</td>
                    <td className="px-4 py-3.5">
                      {m.live ? <span className="pill-ok">Live</span> : <span className="pill">Soon</span>}
                    </td>
                    <td className="px-4 py-3.5 text-right pr-5 sm:pr-6">
                      {m.live ? (
                        <button className="btn-ghost !py-1.5 !px-3 text-[13px]" onClick={() => onBorrow(k)}>
                          Borrow
                        </button>
                      ) : (
                        <button className="btn-ghost !py-1.5 !px-3 text-[13px] opacity-40 cursor-default" disabled>
                          Soon
                        </button>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </Card>

      <RecentActivity />
    </div>
  )
}
