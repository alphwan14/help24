"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { useState } from "react";

/* ─── Types ─────────────────────────────────────────────── */
type NavChild = { label: string; href: string };
type NavItem  = {
  label: string;
  icon: (p: { className?: string }) => React.ReactElement;
  children: NavChild[];
};

/* ─── Navigation tree ──────────────────────────────────── */
const NAV: NavItem[] = [
  {
    label: "Overview",
    icon: GridIcon,
    children: [
      { label: "General",   href: "/dashboard/overview" },
      { label: "Growth",    href: "/dashboard/overview/growth" },
      { label: "Geography", href: "/dashboard/overview/geography" },
      { label: "Revenue",   href: "/dashboard/overview/revenue" },
    ],
  },
  {
    label: "Users",
    icon: UsersIcon,
    children: [
      { label: "All Users",       href: "/dashboard/users" },
      { label: "Active Users",    href: "/dashboard/users/active" },
      { label: "Admins",          href: "/dashboard/users/admins" },
      { label: "Suspended Users", href: "/dashboard/users/suspended" },
    ],
  },
  {
    label: "Marketplace",
    icon: ShoppingBagIcon,
    children: [
      { label: "All Activity", href: "/dashboard/marketplace" },
      { label: "Requests",     href: "/dashboard/marketplace/requests" },
      { label: "Offers",       href: "/dashboard/marketplace/offers" },
      { label: "Job Matches",  href: "/dashboard/marketplace/active-jobs" },
    ],
  },
  {
    label: "Payments",
    icon: CreditCardIcon,
    children: [
      { label: "Transactions",       href: "/dashboard/payments" },
      { label: "Escrow Status",      href: "/dashboard/payments/escrow" },
      { label: "Pending Payments",   href: "/dashboard/payments/pending" },
      { label: "Completed Payments", href: "/dashboard/payments/completed" },
    ],
  },
  {
    label: "Disputes",
    icon: ShieldIcon,
    children: [
      { label: "Open Disputes", href: "/dashboard/disputes" },
      { label: "Resolved",      href: "/dashboard/disputes/resolved" },
      { label: "Refunds",       href: "/dashboard/disputes/refunds" },
      { label: "Actions Taken", href: "/dashboard/disputes/actions" },
    ],
  },
  {
    label: "Insights",
    icon: ChartIcon,
    children: [
      { label: "Analytics",        href: "/dashboard/insights/analytics" },
      { label: "User Behavior",    href: "/dashboard/insights/behavior" },
      { label: "Location Heatmap", href: "/dashboard/insights/heatmap" },
      { label: "Growth Trends",    href: "/dashboard/insights/trends" },
    ],
  },
];

/* ─── Helpers ───────────────────────────────────────────── */

/** Returns the top-level section label that owns the current pathname. */
function resolveSection(pathname: string): string | null {
  return (
    NAV.find((item) =>
      item.children.some(
        (c) => pathname === c.href || pathname.startsWith(c.href + "/")
      )
    )?.label ?? null
  );
}

/* ═══════════════════════════════════════════════════════════
   SIDEBAR — renders two panels as normal flex children.
   The secondary panel's width animates 0 ↔ 220px, so the
   flex-1 <main> shrinks / grows accordingly (no overlay).
═══════════════════════════════════════════════════════════ */
export default function Sidebar() {
  const pathname  = usePathname();
  const router    = useRouter();
  const [signingOut,    setSigningOut]    = useState(false);
  const [hoveredSection, setHoveredSection] = useState<string | null>(null);

  const activeSection  = resolveSection(pathname);
  const displaySection = hoveredSection ?? activeSection;
  const panelVisible   = displaySection !== null;

  /* keep content rendered during close animation */
  const panelData    = NAV.find((n) => n.label === displaySection) ?? null;
  const PanelIcon    = panelData?.icon ?? null;

  async function handleSignOut() {
    setSigningOut(true);
    await getSupabaseBrowser().auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    /* Outer wrapper — onMouseLeave clears hover so panel reverts to active section */
    <div
      className="flex h-screen shrink-0"
      onMouseLeave={() => setHoveredSection(null)}
    >

      {/* ══════════════════════════════════════════════
          PRIMARY NAV — always visible, 172 px wide
      ══════════════════════════════════════════════ */}
      <nav className="w-[172px] h-screen shrink-0 flex flex-col bg-gray-950 border-r border-white/[0.06]">

        {/* Logo */}
        <div className="px-4 py-[18px] shrink-0 border-b border-white/[0.06]">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-lg bg-brand-600 flex items-center justify-center shrink-0 shadow-sm">
              <span className="text-white text-[13px] font-bold select-none">H</span>
            </div>
            <div className="min-w-0">
              <p className="text-white font-semibold text-[13px] leading-none tracking-tight truncate">
                Help24
              </p>
              <p className="text-gray-500 text-[11px] mt-[3px]">Admin</p>
            </div>
          </div>
        </div>

        {/* Nav items */}
        <div className="flex-1 px-2 py-3 space-y-px overflow-y-auto">
          {NAV.map((item) => {
            const isActive  = activeSection === item.label;
            const isHovered = hoveredSection === item.label;
            const highlight = isActive || isHovered;

            return (
              <button
                key={item.label}
                onMouseEnter={() => setHoveredSection(item.label)}
                className={[
                  "relative w-full flex items-center gap-2.5 px-3 py-[9px]",
                  "rounded-lg text-[13px] font-medium transition-colors duration-100",
                  highlight
                    ? "text-white bg-white/[0.11]"
                    : "text-gray-400 hover:text-gray-200 hover:bg-white/[0.05]",
                ].join(" ")}
              >
                {/* Active accent bar */}
                {isActive && (
                  <span className="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-5 bg-brand-400 rounded-r-full" />
                )}

                <item.icon
                  className={[
                    "w-[15px] h-[15px] shrink-0",
                    isActive ? "text-brand-400" : "",
                  ].join(" ")}
                />

                <span className="flex-1 text-left truncate">{item.label}</span>

                <ChevronRightIcon
                  className={[
                    "w-[10px] h-[10px] shrink-0 transition-all duration-150",
                    highlight ? "text-gray-300" : "text-gray-700",
                    isHovered ? "translate-x-[1px]" : "",
                  ].join(" ")}
                />
              </button>
            );
          })}
        </div>

        {/* Sign out */}
        <div className="shrink-0 px-2 py-3 border-t border-white/[0.06]">
          <button
            onClick={handleSignOut}
            disabled={signingOut}
            className="flex items-center gap-2.5 px-3 py-2 w-full rounded-lg text-[12px] font-medium text-gray-500 hover:text-gray-200 hover:bg-white/[0.05] transition-colors disabled:opacity-40"
          >
            <LogOutIcon className="w-[15px] h-[15px] shrink-0" />
            {signingOut ? "Signing out…" : "Sign out"}
          </button>
        </div>
      </nav>

      {/* ══════════════════════════════════════════════
          SECONDARY PANEL — width transitions 0 ↔ 220 px.
          Dark background so it layers cleanly against
          the light content area without "white flash."
      ══════════════════════════════════════════════ */}
      <div
        className={[
          "h-screen shrink-0 overflow-hidden",
          "transition-[width] duration-200 ease-out",
          panelVisible ? "w-[220px]" : "w-0",
        ].join(" ")}
      >
        {/* Inner — fixed 220 px so content doesn't wrap during animation */}
        <div className="w-[220px] h-screen flex flex-col bg-[#111318] border-r border-white/[0.07]">

          {/* Panel header */}
          <div className="shrink-0 px-4 pt-5 pb-4 border-b border-white/[0.07]">
            {panelData && PanelIcon && (
              <div className="flex items-center gap-2.5">
                <div className="w-7 h-7 rounded-lg bg-brand-600/[0.18] border border-brand-500/[0.25] flex items-center justify-center shrink-0">
                  <PanelIcon className="w-3.5 h-3.5 text-brand-400" />
                </div>
                <div className="min-w-0">
                  <p className="text-white text-[13px] font-semibold leading-none truncate">
                    {panelData.label}
                  </p>
                  <p className="text-gray-600 text-[11px] mt-[3px]">
                    {panelData.children.length} pages
                  </p>
                </div>
              </div>
            )}
          </div>

          {/* Sub-item list — re-mounts with animation when section changes */}
          <nav
            key={displaySection}
            className="flex-1 overflow-y-auto px-2.5 py-3 space-y-px nav-content-enter"
          >
            {panelData?.children.map((child) => {
              const isActive = pathname === child.href;
              return (
                <Link
                  key={child.href}
                  href={child.href}
                  className={[
                    "group flex items-center gap-2.5 px-3 py-[7px] rounded-lg",
                    "text-[13px] transition-colors duration-100",
                    isActive
                      ? "bg-white/[0.1] text-white font-semibold"
                      : "text-gray-400 hover:text-gray-100 hover:bg-white/[0.06]",
                  ].join(" ")}
                >
                  <span
                    className={[
                      "w-[5px] h-[5px] rounded-full shrink-0 transition-colors",
                      isActive
                        ? "bg-brand-400"
                        : "bg-gray-700 group-hover:bg-gray-500",
                    ].join(" ")}
                  />
                  {child.label}
                </Link>
              );
            })}
          </nav>

          {/* Panel footer */}
          <div className="shrink-0 px-4 py-3 border-t border-white/[0.06]">
            <p className="text-[11px] text-gray-600 leading-none truncate">
              {hoveredSection && hoveredSection !== activeSection
                ? `Browsing ${hoveredSection}`
                : activeSection
                  ? `In ${activeSection}`
                  : "Help24 Admin"}
            </p>
          </div>

        </div>
      </div>
    </div>
  );
}

/* ─── SVG icons ─────────────────────────────────────────── */

function GridIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z" />
    </svg>
  );
}

function UsersIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z" />
    </svg>
  );
}

function ShoppingBagIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 10.5V6a3.75 3.75 0 10-7.5 0v4.5m11.356-1.993l1.263 12c.07.665-.45 1.243-1.119 1.243H4.25a1.125 1.125 0 01-1.12-1.243l1.264-12A1.125 1.125 0 015.513 7.5h12.974c.576 0 1.059.435 1.119 1.007zM8.625 10.5a.375.375 0 11-.75 0 .375.375 0 01.75 0zm7.5 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z" />
    </svg>
  );
}

function CreditCardIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 8.25h19.5M2.25 9h19.5m-16.5 5.25h6m-6 2.25h3m-3.75 3h15a2.25 2.25 0 002.25-2.25V6.75A2.25 2.25 0 0019.5 4.5h-15a2.25 2.25 0 00-2.25 2.25v10.5A2.25 2.25 0 004.5 19.5z" />
    </svg>
  );
}

function ShieldIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m0-10.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.75c0 5.592 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.57-.598-3.75h-.152c-3.196 0-6.1-1.249-8.25-3.286zm0 13.036h.008v.008H12v-.008z" />
    </svg>
  );
}

function ChartIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z" />
    </svg>
  );
}

function ChevronRightIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
    </svg>
  );
}

function LogOutIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75" />
    </svg>
  );
}
