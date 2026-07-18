import { useActivity, timeAgo } from '../hooks/useActivity'
import { Card, EmptyState, Skeleton } from './ui'
import { usd, from6, num, shortAddr } from '../lib/format'
import { EXPLORER } from '../config/chain'

export function RecentActivity() {
  const { items, isLoading } = useActivity(12)

  return (
    <Card className="!p-0 overflow-hidden">
      <div className="px-5 sm:px-6 py-4 border-b border-line">
        <h2 className="font-bold">Recent activity</h2>
        <div className="text-[12px] text-ink3">on-chain loans on Coston2</div>
      </div>

      {isLoading && items.length === 0 ? (
        <div className="p-5 flex flex-col gap-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-10 w-full rounded-lg" />
          ))}
        </div>
      ) : items.length === 0 ? (
        <EmptyState title="No activity yet" sub="Loans will appear here as they happen." />
      ) : (
        <div className="divide-y divide-line/60">
          {items.map((a) => (
            <a
              key={a.id}
              href={`${EXPLORER}/address/${a.borrower}`}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-3 px-5 sm:px-6 py-3.5 hover:bg-panel2/40 transition-colors"
            >
              <span className={`h-2 w-2 rounded-full shrink-0 ${a.active ? 'bg-ok' : 'bg-ink3'}`} />
              <div className="min-w-0 flex-1">
                <div className="text-sm text-ink">
                  <span className="font-mono text-ink2">{shortAddr(a.borrower)}</span> borrowed{' '}
                  <b>{usd(from6(a.principal))}</b>
                </div>
                <div className="text-[12px] text-ink3">
                  against {num(from6(a.collAmount))} FXRP {a.active ? '· open' : '· closed'}
                </div>
              </div>
              <div className="text-[12px] text-ink3 shrink-0">{timeAgo(a.openedAt)}</div>
            </a>
          ))}
        </div>
      )}
    </Card>
  )
}
