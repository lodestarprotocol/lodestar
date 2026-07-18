import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react'

type ToastKind = 'info' | 'ok' | 'err'
type Toast = { id: number; msg: string; kind: ToastKind }

type ToastCtx = {
  push: (msg: string, kind?: ToastKind) => number
  update: (id: number, msg: string, kind?: ToastKind) => void
  dismiss: (id: number) => void
}

const Ctx = createContext<ToastCtx | null>(null)
let seq = 1

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])

  const dismiss = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), [])

  const push = useCallback((msg: string, kind: ToastKind = 'info') => {
    const id = seq++
    setToasts((t) => [...t, { id, msg, kind }])
    if (kind !== 'info') setTimeout(() => dismiss(id), 6500)
    return id
  }, [dismiss])

  const update = useCallback((id: number, msg: string, kind: ToastKind = 'info') => {
    setToasts((t) => t.map((x) => (x.id === id ? { ...x, msg, kind } : x)))
    if (kind !== 'info') setTimeout(() => dismiss(id), 6500)
  }, [dismiss])

  return (
    <Ctx.Provider value={{ push, update, dismiss }}>
      {children}
      <div className="fixed z-50 bottom-4 right-4 flex flex-col gap-2 max-w-[92vw] w-[360px]">
        {toasts.map((t) => (
          <ToastCard key={t.id} toast={t} onClose={() => dismiss(t.id)} />
        ))}
      </div>
    </Ctx.Provider>
  )
}

function ToastCard({ toast, onClose }: { toast: Toast; onClose: () => void }) {
  const color =
    toast.kind === 'ok'
      ? 'border-ok/40 bg-ok/10'
      : toast.kind === 'err'
        ? 'border-danger/40 bg-danger/10'
        : 'border-line bg-panel'
  return (
    <div className={`animate-fadeup card ${color} px-4 py-3 flex items-start gap-3 shadow-xl`}>
      <div className="text-sm text-ink flex-1" dangerouslySetInnerHTML={{ __html: toast.msg }} />
      <button onClick={onClose} className="text-ink3 hover:text-ink text-sm leading-none">
        ✕
      </button>
    </div>
  )
}

export function useToast(): ToastCtx {
  const c = useContext(Ctx)
  if (!c) throw new Error('useToast must be used within ToastProvider')
  return c
}

// small helper: close toast on unmount safety
export function useAutoClose() {
  useEffect(() => () => {}, [])
}
