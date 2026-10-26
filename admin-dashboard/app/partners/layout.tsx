import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Help24 Partners",
  description: "Your Help24 agent code, and the members you brought.",
  robots: { index: false, follow: false },
};

/** The partner portal's shell: none of the admin dashboard's chrome. */
export default function PartnersLayout({ children }: { children: React.ReactNode }) {
  return <div className="min-h-screen bg-page">{children}</div>;
}
