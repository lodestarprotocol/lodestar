/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // dark fintech palette
        base: '#0a0e14',      // page background
        panel: '#111722',     // cards
        panel2: '#0d131c',    // inset
        line: '#1e2733',      // borders
        ink: '#e8eef6',       // primary text
        ink2: '#8ca0b8',      // secondary text
        ink3: '#5b6b80',      // muted
        brand: '#4da3ff',     // accent blue
        brand2: '#2b7fe0',
        ok: '#3fd08a',
        warn: '#f5b74e',
        danger: '#f0605d',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      borderRadius: {
        xl: '14px',
        '2xl': '18px',
      },
      keyframes: {
        shimmer: {
          '100%': { transform: 'translateX(100%)' },
        },
        fadeup: {
          '0%': { opacity: '0', transform: 'translateY(6px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
      },
      animation: {
        shimmer: 'shimmer 1.4s infinite',
        fadeup: 'fadeup .25s ease both',
      },
    },
  },
  plugins: [],
}
