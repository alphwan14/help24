import type { Config } from "tailwindcss";
import { tailwindColors } from "./lib/tokens";

/**
 * ── Tailwind's own palettes are OVERRIDDEN here, not renamed ────────────────
 * `gray`, `slate`, `brand`, `indigo`, `purple`, `blue`, `green`, `emerald`,
 * `amber`, `yellow`, `orange` and `red` all resolve to Help24 tokens. Between
 * them that is essentially every one of the dashboard's 832 colour classes,
 * re-toned without touching a component — renaming would have been ~830 edits
 * to produce identical pixels.
 *
 * **`gray-400` is NOT Tailwind's `#9ca3af` in this project.** That is the
 * single most surprising thing about this file, it is deliberate, and it is
 * what lifts 114 sub-AA text uses (2.6:1) to 5.09:1. See lib/tokens.ts.
 *
 * ── Values are CSS variables, which is what makes dark mode work ────────────
 * Each name resolves to `rgb(var(--x-rgb) / <alpha-value>)`, so one class names
 * one ROLE and the theme decides its value. `bg-gray-100` is a sunken fill in
 * both themes; only the hex behind it moves.
 *
 * The `rail` family is the exception and does not follow the theme — the
 * sidebar is permanently dark. See RAIL in lib/tokens.ts for why a naive
 * inversion breaks it.
 */
const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: tailwindColors(),

      /**
       * THE TYPEFACE WAS NOT ACTUALLY WIRED UP.
       *
       * `layout.tsx` put Inter on <body> via `inter.className`, and that was
       * the whole of it — this config had no `fontFamily` at all, so Tailwind's
       * DEFAULT stacks were still in the sheet. Any element carrying
       * `font-sans` was therefore switched back off Inter onto
       * `ui-sans-serif, system-ui, …`, which is the OS font. One class, but it
       * meant the dashboard's typeface depended on whether a given element
       * happened to name it.
       *
       * `sans` now points at the same `--font-sans` variable the website uses,
       * fed by `next/font` — so the app, the website and the dashboard are one
       * typeface by construction rather than by three separate assertions.
       */
      fontFamily: {
        sans: ["var(--font-sans)", "system-ui", "sans-serif"],
        /* IDs, hashes and tokens — genuinely monospace, and deliberately NOT
           the app's `mono` ROLE, which is Inter with tabular figures for
           money. See `tabular` below. */
        mono: ["ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
        /**
         * MONEY, COUNTS, COUNTDOWNS — the app's `AppTypeScale.mono`.
         *
         * Inter with tabular figures, so columns of numbers align and a
         * changing value does not shift the layout under the reader. A
         * dashboard is mostly numbers in columns; this is the one type
         * decision that matters most here and it had no expression at all.
         */
        tabular: ["var(--font-sans)", "system-ui", "sans-serif"],
      },
      fontFeatureSettings: {
        tabular: '"tnum" 1, "cv01" 1',
      },
    },
  },
  plugins: [],
};

export default config;
