"use client";

import { Suspense } from "react";
import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { activePageHref, sectionById, type NavPage, type NavSectionId } from "@/lib/nav";

export type Tab = NavPage;

/**
 * A section's pages as tabs, under its heading.
 *
 * The pages used to be reachable only by opening the sidebar and expanding a
 * group, which on a phone meant three taps and a drawer to see what a section
 * holds. Tabs keep them one tap away and show where you are.
 *
 * Query-aware (Promotion's "Pending review" is ?status=pending_review), so the
 * search params are read; that needs a Suspense boundary, whose fallback is the
 * same row with the path match alone.
 */
export default function SectionTabs({ tabs }: { tabs: Tab[] }) {
  return (
    <Suspense fallback={<TabRow tabs={tabs} search={null} />}>
      <WithSearch tabs={tabs} />
    </Suspense>
  );
}

/** The tabs of one section of the console, from the nav map. */
export function SectionNav({ section }: { section: NavSectionId }) {
  return <SectionTabs tabs={sectionById(section).pages} />;
}

function WithSearch({ tabs }: { tabs: Tab[] }) {
  const search = useSearchParams();
  return <TabRow tabs={tabs} search={search} />;
}

function TabRow({ tabs, search }: { tabs: Tab[]; search: URLSearchParams | null }) {
  const pathname = usePathname();
  const active = activePageHref(tabs, pathname, search) ?? tabs[0]?.href;
  if (tabs.length < 2) return null;

  return (
    <nav aria-label="Section pages" className="-mx-4 sm:mx-0 mb-6 border-b border-gray-200">
      <div className="flex gap-1 overflow-x-auto px-4 sm:px-0 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {tabs.map(({ label, href }) => {
          const isActive = href === active;
          return (
            <Link
              key={href}
              href={href}
              aria-current={isActive ? "page" : undefined}
              className={[
                "whitespace-nowrap px-3 py-2.5 text-[13px] font-medium border-b-2 -mb-px transition-colors",
                isActive
                  ? "border-brand-600 text-gray-900"
                  : "border-transparent text-gray-500 hover:text-gray-800",
              ].join(" ")}
            >
              {label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
