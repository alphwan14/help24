"use client";

import Link from "next/link";
import Image from "next/image";
import { usePathname, useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { useState, useEffect } from "react";

/* ─── Types ─────────────────────────────────────────────── */
type NavChild = { label: string; href: string };
type NavItem  = {
  id: string;
  label: string;
  icon: (p: { className?: string }) => React.ReactElement;
  children: NavChild[];
};

/* ─── Navigation tree ──────────────────────────────────── */
const NAV: NavItem[] = [
  {
    id: "overview",
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
    id: "users",
    label: "Users",
    icon: UsersIcon,
    children: [
      { label: "All Users",    href: "/dashboard/users" },
      { label: "Active Users", href: "/dashboard/users/active" },
      { label: "Admin Roles",  href: "/dashboard/users/admins" },
      { label: "Suspended",    href: "/dashboard/users/suspended" },
    ],
  },
  {
    id: "marketplace",
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
    id: "payments",
    label: "Payments",
    icon: CreditCardIcon,
    children: [
      { label: "Transactions", href: "/dashboard/payments" },
      { label: "Escrow",       href: "/dashboard/payments/escrow" },
      { label: "Pending",      href: "/dashboard/payments/pending" },
      { label: "Completed",    href: "/dashboard/payments/completed" },
    ],
  },
  {
    id: "disputes",
    label: "Disputes",
    icon: ShieldIcon,
    children: [
      { label: "Open Cases", href: "/dashboard/disputes" },
      { label: "Resolved",   href: "/dashboard/disputes/resolved" },
      { label: "Refunds",    href: "/dashboard/disputes/refunds" },
    ],
  },
  {
    id: "insights",
    label: "Insights",
    icon: ChartIcon,
    children: [
      { label: "Analytics", href: "/dashboard/insights/analytics" },
      { label: "Heatmaps",  href: "/dashboard/insights/heatmap" },
      { label: "Trends",    href: "/dashboard/insights/trends" },
    ],
  },
];

/* ─── Helpers ───────────────────────────────────────────── */
function resolveActiveId(pathname: string): string | null {
  return (
    NAV.find((item) =>
      item.children.some(
        (c) => pathname === c.href || pathname.startsWith(c.href + "/")
      )
    )?.id ?? null
  );
}

/* ═══════════════════════════════════════════════════════════
   SIDEBAR — single panel, expandable nested sections
═══════════════════════════════════════════════════════════ */
export default function Sidebar() {
  const pathname    = usePathname();
  const router      = useRouter();
  const [openId,    setOpenId]    = useState<string | null>(null);
  const [signingOut, setSigningOut] = useState(false);

  const activeId = resolveActiveId(pathname);

  /* Auto-open the section that owns the current route */
  useEffect(() => {
    if (activeId) setOpenId(activeId);
  }, [activeId]);

  function toggle(id: string) {
    setOpenId((prev) => (prev === id ? null : id));
  }

  async function handleSignOut() {
    setSigningOut(true);
    await getSupabaseBrowser().auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <nav className="w-[240px] h-screen shrink-0 flex flex-col bg-gray-950 border-r border-white/[0.06] overflow-hidden">

      {/* ── Logo ── */}
      <div className="px-5 py-[17px] shrink-0 border-b border-white/[0.06]">
        <div className="flex items-center gap-3">
          {/* Circular logo badge */}
          <div className="w-8 h-8 rounded-full overflow-hidden shrink-0 ring-1 ring-white/[0.12] bg-white">
            <Image
              src="/help24.png"
              alt="Help24 logo"
              width={32}
              height={32}
              className="w-full h-full object-contain"
              priority
            />
          </div>
          <div>
            <p className="text-white font-semibold text-[13.5px] leading-none tracking-tight">
              Help24
            </p>
            <p className="text-[10px] text-gray-500 mt-[3px] tracking-widest uppercase font-medium">
              Operations
            </p>
          </div>
        </div>
      </div>

      {/* ── Nav items ── */}
      <div className="flex-1 overflow-y-auto px-2.5 py-3 space-y-px">
        {NAV.map((item) => {
          const isActive = activeId === item.id;
          const isOpen   = openId   === item.id;

          return (
            <div key={item.id}>

              {/* Section trigger */}
              <button
                onClick={() => toggle(item.id)}
                className={[
                  "relative w-full flex items-center gap-2.5 px-3 py-[9px] rounded-lg",
                  "text-[13px] font-medium transition-colors duration-100",
                  isActive
                    ? "text-white bg-white/[0.09]"
                    : "text-gray-400 hover:text-gray-200 hover:bg-white/[0.05]",
                ].join(" ")}
              >
                {/* Left accent bar for active section */}
                {isActive && (
                  <span className="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-[18px] bg-brand-400 rounded-r-full" />
                )}

                <item.icon
                  className={[
                    "w-[15px] h-[15px] shrink-0 transition-colors",
                    isActive ? "text-brand-400" : "text-gray-500",
                  ].join(" ")}
                />

                <span className="flex-1 text-left">{item.label}</span>

                <ChevronDownIcon
                  className={[
                    "w-[11px] h-[11px] shrink-0 text-gray-600 transition-transform duration-200",
                    isOpen ? "rotate-180" : "",
                  ].join(" ")}
                />
              </button>

              {/* Dropdown — animated via max-height */}
              <div
                className={[
                  "overflow-hidden transition-all duration-200 ease-out",
                  isOpen ? "max-h-[220px] opacity-100" : "max-h-0 opacity-0",
                ].join(" ")}
              >
                <div className="ml-5 mr-1 mt-0.5 mb-1.5 pl-3.5 border-l border-white/[0.07] space-y-px py-0.5">
                  {item.children.map((child) => {
                    const isCurrent =
                      pathname === child.href ||
                      pathname.startsWith(child.href + "/");
                    return (
                      <Link
                        key={child.href}
                        href={child.href}
                        className={[
                          "flex items-center gap-2 px-2.5 py-[5px] rounded-md",
                          "text-[12.5px] transition-colors duration-100",
                          isCurrent
                            ? "text-white font-medium bg-white/[0.08]"
                            : "text-gray-500 hover:text-gray-200 hover:bg-white/[0.04]",
                        ].join(" ")}
                      >
                        <span
                          className={[
                            "w-[5px] h-[5px] rounded-full shrink-0 transition-colors",
                            isCurrent ? "bg-brand-400" : "bg-gray-700",
                          ].join(" ")}
                        />
                        {child.label}
                      </Link>
                    );
                  })}
                </div>
              </div>

            </div>
          );
        })}
      </div>

      {/* ── Sign out ── */}
      <div className="shrink-0 px-2.5 py-3 border-t border-white/[0.06]">
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
  );
}

/* ─── SVG Icons ─────────────────────────────────────────── */

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

function ChevronDownIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
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
