import { useState } from 'react'
import { useAccount, useConnect, useDisconnect, useSwitchChain, useChainId } from 'wagmi'
import { coston2 } from '../config/chain'
import { shortAddr } from '../lib/format'

export function ConnectButton() {
  const { address, isConnected } = useAccount()
  const { connectors, connect, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChain } = useSwitchChain()
  const chainId = useChainId()
  const [open, setOpen] = useState(false)
  const [menu, setMenu] = useState(false)

  const wrongChain = isConnected && chainId !== coston2.id

  if (isConnected && address) {
    return (
      <div className="relative">
        {wrongChain ? (
          <button className="btn-danger" onClick={() => switchChain({ chainId: coston2.id })}>
            Switch to Coston2
          </button>
        ) : (
          <button className="btn-ghost font-mono" onClick={() => setMenu((m) => !m)}>
            <span className="h-2 w-2 rounded-full bg-ok inline-block" />
            {shortAddr(address)}
          </button>
        )}
        {menu && (
          <>
            <div className="fixed inset-0 z-30" onClick={() => setMenu(false)} />
            <div className="absolute right-0 mt-2 w-44 card p-1.5 z-40">
              <a
                className="block px-3 py-2 text-sm rounded-lg hover:bg-panel2 text-ink2"
                href={`${coston2.blockExplorers.default.url}/address/${address}`}
                target="_blank"
                rel="noreferrer"
              >
                View on explorer
              </a>
              <button
                className="block w-full text-left px-3 py-2 text-sm rounded-lg hover:bg-panel2 text-danger"
                onClick={() => {
                  disconnect()
                  setMenu(false)
                }}
              >
                Disconnect
              </button>
            </div>
          </>
        )}
      </div>
    )
  }

  // de-dupe connectors by name (EIP-6963 can surface the same wallet twice)
  const seen = new Set<string>()
  const list = connectors.filter((c) => {
    if (seen.has(c.name)) return false
    seen.add(c.name)
    return true
  })

  return (
    <>
      <button className="btn-primary" onClick={() => setOpen(true)}>
        Connect Wallet
      </button>
      {open && (
        <div
          className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm flex items-center justify-center p-4"
          onClick={(e) => e.target === e.currentTarget && setOpen(false)}
        >
          <div className="card w-full max-w-sm p-5 animate-fadeup">
            <div className="flex items-center justify-between mb-1">
              <h3 className="font-bold text-lg">Connect a wallet</h3>
              <button className="text-ink3 hover:text-ink" onClick={() => setOpen(false)}>
                ✕
              </button>
            </div>
            <p className="text-sm text-ink2 mb-4">
              Pick an installed wallet. You'll be prompted to switch to Coston2 (chain 114).
            </p>
            <div className="flex flex-col gap-2">
              {list.length === 0 && (
                <p className="text-sm text-ink3 py-4 text-center">
                  No wallet detected. Install{' '}
                  <a className="text-brand underline" href="https://metamask.io/" target="_blank" rel="noreferrer">
                    MetaMask
                  </a>{' '}
                  or Rabby.
                </p>
              )}
              {list.map((c) => (
                <button
                  key={c.uid}
                  className="btn-ghost justify-start w-full py-3"
                  disabled={isPending}
                  onClick={() => {
                    connect({ connector: c, chainId: coston2.id })
                    setOpen(false)
                  }}
                >
                  {c.icon && <img src={c.icon} alt="" className="h-5 w-5 rounded" />}
                  {c.name}
                </button>
              ))}
            </div>
            <div className="text-[12px] text-ink3 mt-4 text-center">
              Chain ID 114 · Flare Testnet Coston2
            </div>
          </div>
        </div>
      )}
    </>
  )
}
