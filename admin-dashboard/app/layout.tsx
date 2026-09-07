import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"] });

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

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={inter.className}>{children}</body>
    </html>
  );
}
