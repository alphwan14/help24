import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Help24 Admin",
  description: "Help24 Operations Dashboard",
  icons: {
    icon:     "/help24.png",
    shortcut: "/help24.png",
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
