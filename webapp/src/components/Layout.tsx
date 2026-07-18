import { useState, type ReactNode } from 'react'
import { ConnectButton } from './ConnectButton'
import { LivePill } from './ui'

export type ViewKey = 'dashboard' | 'borrow' | 'lend' | 'portfolio' | 'why' | 'economics' | 'faq'

const NAV: { key: ViewKey; label: string; group?: string }[] = [
  { key: 'dashboard', label: 'Dashboard' },
  { key: 'borrow', label: 'Borrow' },
  { key: 'lend', label: 'Lend' },
  { key: 'portfolio', label: 'Portfolio' },
  { key: 'why', label: 'Why no-liquidation', group: 'Learn' },
  { key: 'economics', label: 'Economics', group: 'Learn' },
  { key: 'faq', label: 'FAQ', group: 'Learn' },
]

export const TITLES: Record<ViewKey, [string, string]> = {
  dashboard: ['Dashboard', 'Protocol overview'],
  borrow: ['Borrow', 'Borrow against your assets'],
  lend: ['Lend', 'Supply USD₮0, earn fees'],
  portfolio: ['Portfolio', 'Your positions'],
  why: ['Why no-liquidation', 'The model, in three ideas'],
  economics: ['Economics', 'Protocol fee model'],
  faq: ['FAQ', 'Frequently asked questions'],
}

export function Layout({
  view,
  onNavigate,
  children,
}: {
  view: ViewKey
  onNavigate: (v: ViewKey) => void
  children: ReactNode
}) {
  const [drawer, setDrawer] = useState(false)

  const go = (v: ViewKey) => {
    onNavigate(v)
    setDrawer(false)
  }

  const sidebar = (
    <nav className="flex flex-col gap-0.5">
      {NAV.map((item, i) => {
        const prev = NAV[i - 1]
        const showGroup = item.group && item.group !== prev?.group
        return (
          <div key={item.key}>
            {showGroup && (
              <div className="stat-label mt-5 mb-1.5 px-3 text-ink3">{item.group}</div>
            )}
            <button
              onClick={() => go(item.key)}
              className={`w-full text-left px-3 py-2.5 rounded-xl text-sm font-medium transition-colors ${
                view === item.key
                  ? 'bg-brand/10 text-ink border border-brand/25'
                  : 'text-ink2 hover:text-ink hover:bg-panel2 border border-transparent'
              }`}
            >
              {item.label}
            </button>
          </div>
        )
      })}
    </nav>
  )

  return (
    <div className="min-h-full flex">
      {/* desktop sidebar */}
      <aside className="hidden lg:flex w-64 shrink-0 flex-col border-r border-line bg-panel/40 p-4 sticky top-0 h-screen">
        <Brand />
        <div className="mt-6 flex-1">{sidebar}</div>
        <TestnetTag />
      </aside>

      {/* mobile drawer */}
      {drawer && (
        <div className="lg:hidden fixed inset-0 z-40 flex">
          <div className="absolute inset-0 bg-black/60" onClick={() => setDrawer(false)} />
          <aside className="relative w-64 max-w-[80vw] bg-panel border-r border-line p-4 flex flex-col animate-fadeup">
            <Brand />
            <div className="mt-6 flex-1">{sidebar}</div>
            <TestnetTag />
          </aside>
        </div>
      )}

      {/* main column */}
      <div className="flex-1 min-w-0 flex flex-col">
        <header className="sticky top-0 z-20 flex items-center gap-3 px-4 sm:px-6 h-16 border-b border-line bg-base/85 backdrop-blur">
          <button
            className="lg:hidden btn-ghost !px-2.5 !py-2"
            onClick={() => setDrawer(true)}
            aria-label="Menu"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M3 6h18M3 12h18M3 18h18" />
            </svg>
          </button>
          <div className="min-w-0">
            <div className="text-sm text-ink2 truncate">
              <span className="text-ink font-semibold">Lodestar</span> / {TITLES[view][0]}
            </div>
            <div className="text-[12px] text-ink3 hidden sm:block">{TITLES[view][1]}</div>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <LivePill>Coston2</LivePill>
            <ConnectButton />
          </div>
        </header>

        <main className="flex-1 px-4 sm:px-6 py-6 max-w-6xl w-full mx-auto">{children}</main>

        <footer className="px-4 sm:px-6 py-6 border-t border-line text-[12px] text-ink3 flex flex-wrap gap-x-4 gap-y-1">
          <span>Lodestar · no-liquidation fixed-term lending on Flare</span>
          <a className="hover:text-ink2" href="https://faucet.flare.network/coston2" target="_blank" rel="noreferrer">
            Get testnet tokens
          </a>
          <span className="text-ink3">Testnet build · not financial advice</span>
        </footer>
      </div>
    </div>
  )
}

function Brand() {
  return (
    <a href="#dashboard" className="flex items-center gap-2.5 px-1">
      <img src="/assets/logo-mark.png" alt="Lodestar" className="h-8 w-8 rounded-lg" />
      <div className="font-extrabold text-lg tracking-tight">Lodestar</div>
    </a>
  )
}

function TestnetTag() {
  return (
    <div className="mt-4 card !bg-panel2 p-3 text-[12px] text-ink2 leading-relaxed">
      <div className="font-semibold text-ink mb-0.5">Coston2 testnet</div>
      Grab free C2FLR, FXRP and USD₮0 at the{' '}
      <a className="text-brand underline" href="https://faucet.flare.network/coston2" target="_blank" rel="noreferrer">
        Flare faucet
      </a>{' '}
      to try it.
    </div>
  )
}
