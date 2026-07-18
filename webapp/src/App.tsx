import { useEffect, useState } from 'react'
import { Layout, type ViewKey } from './components/Layout'
import { Dashboard } from './components/views/Dashboard'
import { Borrow } from './components/views/Borrow'
import { Lend } from './components/views/Lend'
import { Portfolio } from './components/views/Portfolio'
import { Why } from './components/views/Why'
import { Economics } from './components/views/Economics'
import { Faq } from './components/views/Faq'
import type { MarketKey } from './config/contracts'

const VIEWS: ViewKey[] = ['dashboard', 'borrow', 'lend', 'portfolio', 'why', 'economics', 'faq']

function currentView(): ViewKey {
  const h = (location.hash || '#dashboard').replace('#', '') as ViewKey
  return VIEWS.includes(h) ? h : 'dashboard'
}

export default function App() {
  const [view, setView] = useState<ViewKey>(currentView())
  // borrow view can be deep-linked to a specific collateral via #borrow?FXRP
  const [borrowPreset, setBorrowPreset] = useState<MarketKey | undefined>()

  useEffect(() => {
    const onHash = () => {
      setView(currentView())
      window.scrollTo(0, 0)
    }
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const navigate = (v: ViewKey) => {
    location.hash = '#' + v
  }

  const goBorrow = (m: MarketKey) => {
    setBorrowPreset(m)
    location.hash = '#borrow'
  }

  return (
    <Layout view={view} onNavigate={navigate}>
      {view === 'dashboard' && <Dashboard onBorrow={goBorrow} />}
      {view === 'borrow' && <Borrow preset={borrowPreset} />}
      {view === 'lend' && <Lend />}
      {view === 'portfolio' && <Portfolio />}
      {view === 'why' && <Why />}
      {view === 'economics' && <Economics />}
      {view === 'faq' && <Faq />}
    </Layout>
  )
}
