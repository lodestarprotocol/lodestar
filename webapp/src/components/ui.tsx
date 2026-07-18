import type { ReactNode } from 'react'

export function Skeleton({ className = '' }: { className?: string }) {
  return <span className={`skeleton inline-block align-middle ${className}`} />
}

// A stat that shows a shimmer while loading, then the value — never a bare "0".
export function Stat({
  label,
  value,
  sub,
  loading,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  loading?: boolean
}) {
  return (
    <div className="card p-4 sm:p-5">
      <div className="stat-label">{label}</div>
      <div className="mt-2 stat-value">
        {loading ? <Skeleton className="h-7 w-24 rounded-md" /> : value}
      </div>
      {sub !== undefined && (
        <div className="mt-1 text-[13px] text-ink2">
          {loading ? <Skeleton className="h-4 w-16 rounded" /> : sub}
        </div>
      )}
    </div>
  )
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <div className={`card p-5 sm:p-6 ${className}`}>{children}</div>
}

export function EmptyState({ title, sub }: { title: string; sub: string }) {
  return (
    <div className="text-center py-10 px-6">
      <div className="font-semibold text-ink">{title}</div>
      <div className="text-sm text-ink2 mt-1">{sub}</div>
    </div>
  )
}

export function LivePill({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-[12px] text-ink2">
      <span className="relative flex h-2 w-2">
        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-ok/60" />
        <span className="relative inline-flex rounded-full h-2 w-2 bg-ok" />
      </span>
      {children}
    </span>
  )
}
