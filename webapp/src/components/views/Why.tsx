import { Card } from '../ui'

export function Why() {
  return (
    <div className="flex flex-col gap-6 max-w-3xl">
      <Card>
        <h2 className="text-xl font-bold mb-2">No-liquidation lending, in three ideas</h2>
        <p className="text-ink2 leading-relaxed">
          Most lending protocols can seize your collateral the moment a price wobble pushes you
          under a health factor. Lodestar removes that entirely: every loan is a fixed-term contract
          that can only ever settle at its deadline, never before.
        </p>
      </Card>

      <div className="grid sm:grid-cols-3 gap-4">
        <Idea n="1" title="Every loan is a put option">
          When you borrow, you're buying the right to walk away from your collateral at the deadline
          for the amount you owe. The fixed fee is the option premium. That's the whole model.
        </Idea>
        <Idea n="2" title="Lenders are the option writers">
          Suppliers collect those premiums. Across many loans the fees are priced to more than cover
          the rare case where a borrower walks away and the collateral has fallen in value.
        </Idea>
        <Idea n="3" title="Solvency is aggregate, not per-loan">
          The pool stays healthy as long as total fees exceed total default losses over time, so no
          single loan needs a liquidator watching it minute to minute.
        </Idea>
      </div>

      <Card>
        <h3 className="font-bold mb-3">What this means for you</h3>
        <ul className="space-y-3 text-sm text-ink2">
          <li className="flex gap-3"><Dot /> <span><b className="text-ink">Borrowers</b> never get liquidated by volatility. The only deadline that matters is the one you chose upfront.</span></li>
          <li className="flex gap-3"><Dot /> <span><b className="text-ink">Collateral keeps working.</b> Staked assets like sFLR and stXRP keep earning their yield the entire time they're locked.</span></li>
          <li className="flex gap-3"><Dot /> <span><b className="text-ink">Lenders earn real fees</b> from borrowing demand, not inflationary token emissions.</span></li>
        </ul>
      </Card>
    </div>
  )
}

function Idea({ n, title, children }: { n: string; title: string; children: React.ReactNode }) {
  return (
    <Card className="!p-5">
      <div className="h-8 w-8 rounded-lg bg-brand/20 text-brand font-bold flex items-center justify-center mb-3">{n}</div>
      <h3 className="font-semibold mb-1.5">{title}</h3>
      <p className="text-[13px] text-ink2 leading-relaxed">{children}</p>
    </Card>
  )
}

function Dot() {
  return <span className="mt-1.5 h-1.5 w-1.5 rounded-full bg-brand shrink-0" />
}
