"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import AlertsBell from "@/components/alerts/AlertsBell";
import { useAlerts } from "@/components/alerts/AlertsProvider";
import { useShell } from "@/components/ShellContext";
import { SearchGlyph } from "@/components/CommandPalette";
import type { ArbitrationIdentity } from "@/lib/arbitration-client";
import type { AdminRole } from "@/lib/api";
import {
  NAV,
  SETTINGS_HREF,
  attentionBySection,
  badgeText,
  sectionFor,
  type NavSectionId,
} from "@/lib/nav";

const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support agent",
  senior_admin: "Senior admin",
  super_admin: "Super admin",
};

type Attention = Partial<Record<NavSectionId, { count: number; high: boolean }>>;

function useAttention(): Attention {
  const alerts = useAlerts();
  const list = alerts?.data?.alerts;
  return useMemo(() => attentionBySection(list ?? []), [list]);
}

/**
 * Sign out of both identities: the arbitration bearer cookie first, then the
 * Supabase session. Clearing only one leaves the other active (split brain).
 * Neither goes through Next's router, whose queued navigations once left
 * "Signing out" hanging; a full page load also drops the dashboard from memory.
 */
async function signOut() {
  try {
    await fetch("/api/admin/session", { method: "DELETE" });
  } catch {
    /* still end the Supabase session */
  }
  try {
    await getSupabaseBrowser().auth.signOut();
  } finally {
    window.location.assign("/login");
  }
}

/* ═══════════════════════════════════════════════════════════
   The console's chrome.
   Desktop (lg+): a flat dark rail. One row per section, with a count where
   work is waiting; a section's pages are tabs on the page itself.
   Phone: a dark top bar (where you are, search, alerts) and a bottom bar for
   the four places work arrives, plus More for everything else.
═══════════════════════════════════════════════════════════ */
export default function Sidebar({
  supabaseEmail,
  arbitration,
}: {
  supabaseEmail: string | null;
  arbitration: ArbitrationIdentity;
}) {
  const pathname = usePathname();
  const [moreOpen, setMoreOpen] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const attention = useAttention();
  const { openSearch } = useShell();
  const active = sectionFor(pathname)?.id ?? null;
  const onSettings = pathname === SETTINGS_HREF || pathname.startsWith(SETTINGS_HREF + "/");

  useEffect(() => setMoreOpen(false), [pathname]);

  useEffect(() => {
    document.body.style.overflow = moreOpen ? "hidden" : "";
    return () => {
      document.body.style.overflow = "";
    };
  }, [moreOpen]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setMoreOpen(false);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  function handleSignOut() {
    setSigningOut(true);
    void signOut();
  }

  const footer = (
    <AccountFooter
      email={supabaseEmail}
      arbitration={arbitration}
      onSettings={onSettings}
      signingOut={signingOut}
      onSignOut={handleSignOut}
    />
  );

  const title = onSettings ? "Settings" : (NAV.find((s) => s.id === active)?.label ?? "Help24");

  return (
    <>
      {/* ── Desktop rail ─────────────────────────────────────── */}
      <nav
        aria-label="Console"
        className="hidden lg:flex lg:flex-col lg:w-[232px] lg:h-screen lg:shrink-0 bg-rail-950 border-r border-white/[0.06]"
      >
        <div className="flex items-center gap-2.5 px-4 h-14 shrink-0">
          <Image src="/help24.png" alt="Help24" width={28} height={28} className="w-7 h-7 shrink-0" priority />
          <span className="text-white font-semibold text-[14px] tracking-tight">Help24</span>
          <span className="text-rail-500 text-[12px]">Console</span>
          <div className="ml-auto -mr-1">
            <AlertsBell placement="rail" />
          </div>
        </div>

        <div className="px-3 pb-2 shrink-0">
          <button
            onClick={openSearch}
            className="w-full flex items-center gap-2.5 h-9 px-3 rounded-lg bg-white/[0.05] border border-white/[0.06] text-rail-400 hover:text-rail-200 hover:bg-white/[0.08] transition-colors"
          >
            <SearchGlyph className="w-[14px] h-[14px]" />
            <span className="text-[12.5px]">Search</span>
            <kbd className="ml-auto text-[10.5px] font-sans text-rail-500">Ctrl K</kbd>
          </button>
        </div>

        <ul className="flex-1 overflow-y-auto px-3 py-2 space-y-0.5">
          {NAV.map((s) => (
            <li key={s.id}>
              <RailLink
                href={s.href}
                label={s.label}
                icon={ICONS[s.id]}
                active={active === s.id}
                badge={attention[s.id]}
              />
            </li>
          ))}
        </ul>

        {footer}
      </nav>

      {/* ── Phone top bar ────────────────────────────────────── */}
      <header className="lg:hidden fixed top-0 inset-x-0 z-30 h-14 bg-rail-950 border-b border-white/[0.06] flex items-center gap-3 pl-4 pr-2">
        <Image src="/help24.png" alt="Help24" width={26} height={26} className="w-[26px] h-[26px] shrink-0" priority />
        <span className="text-white font-semibold text-[15px] tracking-tight truncate">{title}</span>
        <div className="ml-auto flex items-center gap-1">
          <button
            onClick={openSearch}
            aria-label="Search"
            className="w-9 h-9 flex items-center justify-center rounded-lg text-rail-400 hover:text-white hover:bg-white/[0.08]"
          >
            <SearchGlyph className="w-[18px] h-[18px]" />
          </button>
          <AlertsBell placement="topbar" />
        </div>
      </header>

      {/* ── Phone bottom bar ─────────────────────────────────── */}
      <nav
        aria-label="Primary"
        className="lg:hidden fixed bottom-0 inset-x-0 z-30 bg-rail-950 border-t border-white/[0.06] pb-[env(safe-area-inset-bottom)]"
      >
        <ul className="grid grid-cols-5 h-16">
          {BOTTOM.map((id) => {
            const s = NAV.find((x) => x.id === id)!;
            return (
              <li key={id}>
                <TabLink
                  href={s.href}
                  label={SHORT[id]}
                  icon={id === "overview" ? HomeIcon : ICONS[id]}
                  active={active === id}
                  badge={attention[id]}
                />
              </li>
            );
          })}
          <li>
            <button
              onClick={() => setMoreOpen(true)}
              aria-expanded={moreOpen}
              className={[
                "w-full h-full flex flex-col items-center justify-center gap-1 text-[10.5px] font-medium",
                moreOpen || onSettings || (active !== null && !(BOTTOM as readonly NavSectionId[]).includes(active))
                  ? "text-white"
                  : "text-rail-500",
              ].join(" ")}
            >
              <span className="relative">
                <MenuIcon className="w-[22px] h-[22px]" />
                {moreHasWork(attention) && (
                  <span className="absolute -top-0.5 -right-1 w-2 h-2 rounded-full bg-caution-500 ring-2 ring-rail-950" />
                )}
              </span>
              More
            </button>
          </li>
        </ul>
      </nav>

      {/* ── Phone "More" sheet ───────────────────────────────── */}
      <div
        aria-hidden
        onClick={() => setMoreOpen(false)}
        className={[
          "lg:hidden fixed inset-0 z-40 bg-black/60 transition-opacity duration-200",
          moreOpen ? "opacity-100" : "opacity-0 pointer-events-none",
        ].join(" ")}
      />
      <div
        // A dialog only while open; closed, it is inert and hidden from
        // assistive tech (it stays mounted so it can slide).
        role={moreOpen ? "dialog" : undefined}
        aria-modal={moreOpen ? true : undefined}
        aria-label="All sections"
        aria-hidden={moreOpen ? undefined : true}
        inert={!moreOpen}
        className={[
          "lg:hidden fixed inset-x-0 bottom-0 z-50 max-h-[85vh] flex flex-col",
          "bg-rail-950 border-t border-white/[0.08] rounded-t-2xl",
          "transition-transform duration-300 ease-out",
          moreOpen ? "translate-y-0" : "translate-y-full",
        ].join(" ")}
      >
        <div className="flex items-center justify-between px-5 pt-4 pb-2 shrink-0">
          <p className="text-[13px] font-semibold text-white">All sections</p>
          <button
            onClick={() => setMoreOpen(false)}
            className="text-[13px] font-medium text-rail-400 hover:text-white px-2 py-1"
          >
            Done
          </button>
        </div>
        <ul className="overflow-y-auto px-3 pb-2 grid grid-cols-1 gap-0.5">
          {NAV.map((s) => (
            <li key={s.id}>
              <RailLink
                href={s.href}
                label={s.label}
                icon={ICONS[s.id]}
                active={active === s.id}
                badge={attention[s.id]}
                large
              />
            </li>
          ))}
        </ul>
        <div className="pb-[env(safe-area-inset-bottom)]">{footer}</div>
      </div>
    </>
  );
}

const BOTTOM = ["overview", "disputes", "trust-safety", "payments"] as const satisfies readonly NavSectionId[];
const SHORT: Record<(typeof BOTTOM)[number], string> = {
  overview: "Home",
  disputes: "Disputes",
  "trust-safety": "Safety",
  payments: "Payments",
};

function moreHasWork(a: Attention): boolean {
  return Object.entries(a).some(([id, v]) => !(BOTTOM as readonly string[]).includes(id) && (v?.count ?? 0) > 0);
}

/* ─── Pieces ────────────────────────────────────────────── */

function Badge({ badge, compact = false }: { badge?: { count: number; high: boolean }; compact?: boolean }) {
  if (!badge || badge.count <= 0) return null;
  return (
    <span
      className={[
        "inline-flex items-center justify-center rounded-full font-semibold tabular-nums leading-none",
        compact ? "min-w-[16px] h-[16px] px-1 text-[9.5px]" : "min-w-[20px] h-[20px] px-1.5 text-[11px]",
        badge.high ? "bg-critical-500 text-white" : "bg-white/[0.1] text-rail-200",
      ].join(" ")}
    >
      {badgeText(badge.count)}
    </span>
  );
}

function RailLink({
  href,
  label,
  icon: Icon,
  active,
  badge,
  large = false,
}: {
  href: string;
  label: string;
  icon: IconCmp;
  active: boolean;
  badge?: { count: number; high: boolean };
  large?: boolean;
}) {
  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={[
        "relative flex items-center gap-3 px-3 rounded-lg font-medium transition-colors",
        large ? "h-12 text-[15px]" : "h-9 text-[13px]",
        active ? "text-white bg-white/[0.08]" : "text-rail-400 hover:text-rail-200 hover:bg-white/[0.04]",
      ].join(" ")}
    >
      {active && <span className="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-4 bg-brand-400 rounded-r-full" />}
      <Icon className={["w-4 h-4 shrink-0", active ? "text-brand-400" : "text-rail-500"].join(" ")} />
      <span className="flex-1 truncate">{label}</span>
      <Badge badge={badge} />
    </Link>
  );
}

function TabLink({
  href,
  label,
  icon: Icon,
  active,
  badge,
}: {
  href: string;
  label: string;
  icon: IconCmp;
  active: boolean;
  badge?: { count: number; high: boolean };
}) {
  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={[
        "w-full h-full flex flex-col items-center justify-center gap-1 text-[10.5px] font-medium transition-colors",
        active ? "text-white" : "text-rail-500 hover:text-rail-300",
      ].join(" ")}
    >
      <span className="relative">
        <Icon className={["w-[22px] h-[22px]", active ? "text-brand-400" : ""].join(" ")} />
        <span className="absolute -top-1.5 left-3.5">
          <Badge badge={badge} compact />
        </span>
      </span>
      {label}
    </Link>
  );
}

function AccountFooter({
  email,
  arbitration,
  onSettings,
  signingOut,
  onSignOut,
}: {
  email: string | null;
  arbitration: ArbitrationIdentity;
  onSettings: boolean;
  signingOut: boolean;
  onSignOut: () => void;
}) {
  const initial = email ? email[0].toUpperCase() : "?";
  const role = arbitration.connected && arbitration.role ? ROLE_LABELS[arbitration.role] : null;

  return (
    <div className="shrink-0 border-t border-white/[0.06] p-3 space-y-0.5">
      <Link
        href={SETTINGS_HREF}
        aria-current={onSettings ? "page" : undefined}
        title="Settings"
        className={[
          "flex items-center gap-3 px-2 py-2 rounded-lg transition-colors",
          onSettings ? "bg-white/[0.08]" : "hover:bg-white/[0.04]",
        ].join(" ")}
      >
        <span className="w-8 h-8 rounded-full bg-rail-800 ring-1 ring-white/[0.08] flex items-center justify-center text-[12px] font-semibold text-rail-200 shrink-0 select-none">
          {initial}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[12.5px] text-rail-200 truncate leading-tight">{email ?? " "}</span>
          <span className={["block text-[11px] leading-tight mt-0.5", role ? "text-rail-500" : "text-rail-accent"].join(" ")}>
            {role ?? "No admin access"}
          </span>
        </span>
        <CogIcon className="w-4 h-4 text-rail-500 shrink-0" />
      </Link>
      <button
        onClick={onSignOut}
        disabled={signingOut}
        className="w-full flex items-center gap-3 px-3 h-9 rounded-lg text-[12.5px] font-medium text-rail-500 hover:text-rail-200 hover:bg-white/[0.04] transition-colors disabled:opacity-40"
      >
        <LogOutIcon className="w-4 h-4 shrink-0" />
        {signingOut ? "Signing out" : "Sign out"}
      </button>
    </div>
  );
}

/* ─── Icons (24px grid, 1.75 stroke) ───────────────────── */

type IconCmp = (p: { className?: string }) => React.ReactElement;

function svg(d: string | string[]): IconCmp {
  const paths = Array.isArray(d) ? d : [d];
  const Cmp = ({ className }: { className?: string }) => (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      {paths.map((p) => (
        <path key={p} strokeLinecap="round" strokeLinejoin="round" d={p} />
      ))}
    </svg>
  );
  return Cmp;
}

const GridIcon = svg("M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25a2.25 2.25 0 01-2.25-2.25v-2.25z");
const HomeIcon = svg("M2.25 12l8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25");
/* Operations: a pulse line, for "what is happening now" (it was a sliders icon, which reads as settings). */
const PulseIcon = svg("M3 12h4l2.25-6 4.5 12L16 12h5");
const UsersIcon = svg("M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z");
const BagIcon = svg("M15.75 10.5V6a3.75 3.75 0 10-7.5 0v4.5m11.356-1.993l1.263 12c.07.665-.45 1.243-1.119 1.243H4.25a1.125 1.125 0 01-1.12-1.243l1.264-12A1.125 1.125 0 015.513 7.5h12.974c.576 0 1.059.435 1.119 1.007z");
const CardIcon = svg("M2.25 8.25h19.5M2.25 9h19.5m-16.5 5.25h6m-6 2.25h3m-3.75 3h15a2.25 2.25 0 002.25-2.25V6.75A2.25 2.25 0 0019.5 4.5h-15a2.25 2.25 0 00-2.25 2.25v10.5A2.25 2.25 0 004.5 19.5z");
/* Disputes: scales, for weighing two sides (the shield now belongs to Trust and safety alone). */
const ScaleIcon = svg("M12 3v17.25m0 0c-1.472 0-2.882.265-4.185.75M12 20.25c1.472 0 2.882.265 4.185.75M18.75 4.97A48.416 48.416 0 0012 4.5c-2.291 0-4.545.16-6.75.47m13.5 0c1.01.143 2.01.317 3 .52m-3-.52l2.62 10.726c.122.499-.106 1.028-.589 1.202a5.988 5.988 0 01-2.031.352 5.988 5.988 0 01-2.031-.352c-.483-.174-.711-.703-.59-1.202L18.75 4.971zm-16.5.52c.99-.203 1.99-.377 3-.52m0 0l2.62 10.726c.122.499-.106 1.028-.589 1.202a5.989 5.989 0 01-2.031.352 5.989 5.989 0 01-2.031-.352c-.483-.174-.711-.703-.59-1.202L5.25 4.971z");
const ShieldIcon = svg("M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z");
/* Partners: a person being added, since partners bring members in (it shared the Users icon). */
const UserPlusIcon = svg("M19 7.5v3m0 0v3m0-3h3m-3 0h-3m-2.25-4.125a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zM4 19.235v-.11a6.375 6.375 0 0112.75 0v.109A12.318 12.318 0 0110.374 21c-2.331 0-4.512-.645-6.374-1.766z");
const MegaphoneIcon = svg("M10.34 15.84c-.688-.06-1.386-.09-2.09-.09H7.5a4.5 4.5 0 110-9h.75c.704 0 1.402-.03 2.09-.09m0 9.18c.253.962.584 1.892.985 2.783.247.55.06 1.21-.463 1.511l-.657.38c-.551.318-1.26.117-1.527-.461a20.845 20.845 0 01-1.44-4.282m3.102.069a18.03 18.03 0 01-.59-4.59c0-1.586.205-3.124.59-4.59m0 9.18a23.848 23.848 0 018.835 2.535M10.34 6.66a23.847 23.847 0 008.835-2.535m0 0A23.74 23.74 0 0018.795 3m.38 1.125a23.91 23.91 0 011.014 5.395m-1.014 8.855c-.118.38-.245.754-.38 1.125m.38-1.125a23.91 23.91 0 001.014-5.395m0-3.46c.495.413.811 1.035.811 1.73 0 .695-.316 1.317-.811 1.73m0-3.46a24.347 24.347 0 010 3.46");
const ChartIcon = svg("M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z");
const MenuIcon = svg("M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5");
const CogIcon = svg([
  "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 010 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 010-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28z",
  "M15 12a3 3 0 11-6 0 3 3 0 016 0z",
]);
const LogOutIcon = svg("M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75");

const ICONS: Record<NavSectionId, IconCmp> = {
  overview: GridIcon,
  operations: PulseIcon,
  users: UsersIcon,
  marketplace: BagIcon,
  payments: CardIcon,
  disputes: ScaleIcon,
  "trust-safety": ShieldIcon,
  partners: UserPlusIcon,
  promotion: MegaphoneIcon,
  insights: ChartIcon,
};
