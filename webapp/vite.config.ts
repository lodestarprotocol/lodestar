import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Static SPA build → Cloudflare Pages (output dir: dist)
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
    target: 'es2020',
    rollupOptions: {
      output: {
        manualChunks: {
          // split the heavy web3 stack so first paint isn't blocked by it
          web3: ['viem', 'wagmi'],
          query: ['@tanstack/react-query'],
        },
      },
    },
  },
})
