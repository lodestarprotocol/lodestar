import { useState } from 'react'
import { Card } from '../ui'

const FAQS: { q: string; a: string }[] = [
  {
    q: 'What does "no liquidation" actually mean?',
    a: 'Your loan can only settle at its fixed deadline, never before. Price swings during the term cannot trigger a liquidation. If your collateral falls in value, that risk is the lender\'s, priced into the upfront fee.',
  },
  {
    q: 'What happens if I miss my deadline?',
    a: 'Missing the deadline is the only event that closes your loan. At that point the protocol settles the loan against your collateral. There is no penalty spiral and no keeper seizing your position early.',
  },
  {
    q: 'How is the borrow cost calculated?',
    a: 'One fixed fee, charged upfront, based on your chosen term and collateral tier. There is no variable interest rate. You see the exact fee and repayment amount before you confirm.',
  },
  {
    q: 'Does my staked collateral keep earning?',
    a: 'Yes. Liquid staking tokens like sFLR and stXRP keep accruing their staking yield the entire time they are locked as collateral. You get that yield back along with your collateral when you repay.',
  },
  {
    q: 'How do lenders earn?',
    a: 'Suppliers of USD₮0 receive lodUSD₮0 shares. Borrower fees accrue to the pool, raising each share\'s value in USD₮0 over time. Yield comes from real borrowing demand, not token emissions.',
  },
  {
    q: 'Can I withdraw my deposit anytime?',
    a: 'Yes, up to the available (un-borrowed) liquidity in the pool. Redeem your lodUSD₮0 shares back to USD₮0 whenever you want; there is no lockup.',
  },
  {
    q: 'What is this running on right now?',
    a: 'This is the Coston2 testnet build (Flare\'s test network, chain ID 114). Grab free C2FLR, FXRP and USD₮0 from the Flare faucet to try every feature end to end with no real funds.',
  },
  {
    q: 'Is the protocol audited?',
    a: 'The core contracts are immutable (no proxy, no admin mint) and have completed an external audit. The settlement design uses a Dutch floor, buyout and impairment mark to close defaulted loans fairly.',
  },
]

export function Faq() {
  const [open, setOpen] = useState<number | null>(0)
  return (
    <div className="max-w-3xl flex flex-col gap-3">
      {FAQS.map((f, i) => {
        const isOpen = open === i
        return (
          <Card key={i} className="!p-0 overflow-hidden">
            <button
              className="w-full flex items-center justify-between gap-4 text-left px-5 py-4"
              onClick={() => setOpen(isOpen ? null : i)}
            >
              <span className="font-semibold">{f.q}</span>
              <span className={`text-ink3 transition-transform ${isOpen ? 'rotate-45' : ''}`}>+</span>
            </button>
            {isOpen && <p className="px-5 pb-5 -mt-1 text-sm text-ink2 leading-relaxed">{f.a}</p>}
          </Card>
        )
      })}
      <Card className="!bg-panel2 text-center">
        <p className="text-sm text-ink2">
          Still stuck? Try it live on testnet, grab tokens from the{' '}
          <a className="text-brand underline" href="https://faucet.flare.network/coston2" target="_blank" rel="noreferrer">
            Flare faucet
          </a>
          .
        </p>
      </Card>
    </div>
  )
}
