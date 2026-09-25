import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { tokensCss } from "@/lib/tokens";
import { ThemeScript } from "@/components/theme/ThemeScript";

/**
 * Inter, the same face the app bundles and the website serves. Four weights,
 * matching what ships inside the APK. `next/font/google` downloads at build
 * time and self-hosts, so there is no runtime request to Google.
 */
const inter = Inter({
  weight: ["400", "500", "600", "700"],
  subsets: ["latin"],
  variable: "--font-sans",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Help24 Admin",
  description: "Help24 Operations Dashboard",
  // THE FAVICON IS A DIFFERENT DRAWING, not a small copy of the icon. Below
  // roughly 24px antialiasing closes the gaps either side of the gold bar and
  // the mark reads as a solid blob, so the tab gets the widened-gap rendition.
  // The Apple touch icon is drawn at 180px, well clear of that, so it keeps the
  // standard tile.
  icons: {
    icon: [
      { url: "/favicon.svg", type: "image/svg+xml" },
      { url: "/favicon-32.png", type: "image/png", sizes: "32x32" },
    ],
    shortcut: "/favicon-32.png",
    apple:    "/help24.png",
  },
};

/**
 * `suppressHydrationWarning` on <html> is REQUIRED here, not cosmetic.
 *
 * ThemeScript stamps `data-theme` on that element synchronously, before React
 * hydrates — that is the entire point of it, and the only way to avoid a light
 * flash on every navigation. The cost is that the client then holds an
 * attribute the server never sent, which React reports as a hydration
 * mismatch.
 *
 * Measured across all 28 dashboard pages: **0 console errors in light** (no
 * stored preference, so the script writes nothing and there is nothing to
 * mismatch) and **28 of 28 in dark**. The suppression is scoped to this one
 * element's attributes; it does not silence the tree below it.
 */
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={inter.variable} suppressHydrationWarning>
      <head>
        {/* The token sheet before anything paints. Light on bare :root, dark
            behind prefers-color-scheme or an explicit data-theme. */}
        <style dangerouslySetInnerHTML={{ __html: tokensCss() }} />
        {/* Stamps a stored override onto <html> synchronously — the only way
            to avoid a light flash on every navigation. See ThemeScript. */}
        <ThemeScript />
      </head>
      <body className={inter.className}>{children}</body>
    </html>
  );
}
