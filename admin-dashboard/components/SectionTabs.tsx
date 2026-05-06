"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export interface Tab {
  label: string;
  href: string;
}

export default function SectionTabs({ tabs }: { tabs: Tab[] }) {
  const pathname = usePathname();

  // Longest-prefix match: most specific tab wins.
  // e.g. at /marketplace/requests → "Requests" wins over "All Activity"
  const activeHref = tabs
    .filter((t) => pathname === t.href || pathname.startsWith(t.href + "/"))
    .sort((a, b) => b.href.length - a.href.length)[0]?.href ?? tabs[0]?.href;

  return (
    <div className="flex gap-1 border-b border-gray-200 mb-6 overflow-x-auto">
      {tabs.map(({ label, href }) => {
        const active = href === activeHref;
        return (
          <Link
            key={href}
            href={href}
            className={`whitespace-nowrap px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors ${
              active
                ? "border-brand-600 text-brand-700"
                : "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
            }`}
          >
            {label}
          </Link>
        );
      })}
    </div>
  );
}
