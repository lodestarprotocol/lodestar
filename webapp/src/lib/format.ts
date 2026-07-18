// Formatting + unit helpers. All money is 6dp (USD₮0/FXRP); pool shares are 12dp.

export const usd = (n: number): string =>
  '$' + n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// asset prices want more precision than dollars
export const priceUsd = (n: number): string =>
  '$' + n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: n < 1 ? 6 : 4 })

export const num = (n: number, max = 2): string =>
  n.toLocaleString('en-US', { maximumFractionDigits: max })

export const pct = (n: number, d = 1): string => n.toFixed(d) + '%'

// bigint 6dp -> number
export const from6 = (v: bigint | undefined): number => (v === undefined ? 0 : Number(v) / 1e6)
// bigint 12dp (shares) -> number
export const from12 = (v: bigint | undefined): number => (v === undefined ? 0 : Number(v) / 1e12)

// user string -> 6dp bigint (floors to avoid dust over-spend)
export const to6 = (v: string | number): bigint => {
  const f = typeof v === 'number' ? v : parseFloat(v)
  if (!Number.isFinite(f) || f <= 0) return 0n
  return BigInt(Math.floor(f * 1e6))
}

export const shortAddr = (a?: string): string => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '')

export const dateShort = (ms: number): string =>
  new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })

// FTSO feed value+decimals -> price number
export const feedPrice = (value: bigint, decimals: number): number =>
  Number(value) / 10 ** decimals

// friendly on-chain error extraction
export function errMsg(e: unknown): string {
  const any = e as any
  return (
    any?.shortMessage ||
    any?.details ||
    any?.cause?.shortMessage ||
    any?.message ||
    String(e)
  )
}
