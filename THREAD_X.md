# Lodestar launch thread (X) — put-option framing

1/
Every DeFi loan can liquidate you on a wick. One red candle or a slow oracle and your collateral is
gone, even when your thesis was right.

Lodestar removes liquidations entirely. No health factor. No liquidation bots. Only a deadline.

Here's how that works 🧵

2/
Lock collateral (FXRP, sFLR). Borrow USD₮0 against it for a fixed term.

A 40% crash mid-term cannot touch your position. You repay by the deadline and get your collateral
back, staking yield included.

The calendar is the only thing that can default you.

3/
Say you lock $800 of FXRP at 50% LTV.

Borrow $400 USD₮0 (you receive $392 after a flat 2% fee).
Owe $400 by the deadline.

No margin calls. Nothing hunting your liquidation price, because there isn't one.

4/
Here's the part people miss: every loan is a put option.

You buy a put on your own collateral, struck at your debt, expiring at the deadline. The fee is the
premium.

Moons? Repay and keep the upside. Craters? Walk away. Your downside is capped.

5/
So what if you never repay?

At the deadline + 48h, anyone can settle it. Your collateral sells on a descending Dutch floor (100%
down to 85% of oracle value). Lenders are paid first. You keep any surplus.

Nobody races your health to zero. There is no health to race.

6/
Why lenders sleep fine:

• Conservative LTV (needs a >50% crash before they're exposed)
• Losses marked instantly, no exit at a stale price
• A first-loss reserve funded by every fee
• Settlement always clears via the Dutch floor

An insurance book, priced to hold.

7/
No liquidations. Fixed terms. Collateral that keeps earning while it's locked.

Borrow against your XRP without a wick taking it from you.

Find your bearing. Lodestar.
[link]
