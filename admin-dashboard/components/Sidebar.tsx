"use client";

import BrandMark from "@/components/BrandMark";
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
  SETTINGS_HREF,
  activePageHref,
  attentionBySection,
  badgeText,
  groupedNav,
  sectionFor,
  type NavSection,
  type NavSectionId,
} from "@/lib/nav";

const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support agent",
  senior_admin: "Senior admin",
  super_admin: "Super admin",
};

const RAIL_KEY = "help24-admin-rail";
const GROUPS = groupedNav();

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
    // The role AdminShell remembers for a fast first paint goes with the session.
    localStorage.removeItem("h24_admin_identity");
  } catch {
    /* private mode */
  }
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
   The console's navigation, in two layers. It follows the theme: light in
   light mode, dark in dark mode (it used to be pinned dark in both). It takes
   the page's tone with a hairline edge, so it recedes and the white cards of
   the workspace come forward.

   PRIMARY: the sidebar. Sections grouped by how often an admin goes there:
   Overview, then the Queues where work waits (with counts), then Marketplace
   and Platform. Group headings, not collapsible groups, so nothing is hidden
   behind a tap.

   SECONDARY: the active section's pages, as tabs on the page itself (and,
   on a phone, listed under the active section in the drawer as well, since
   tabs there can scroll out of view).

   Desktop: a rail that collapses to icons (remembered per browser) to give
   tables and charts the full width. Phone: a top bar and a left drawer, so
   the screen belongs to the content until you ask for the menu.
═══════════════════════════════════════════════════════════ */
export default function Sidebar({
  supabaseEmail,
  arbitration,
}: {
  supabaseEmail: string | null;
  arbitration: ArbitrationIdentity;
}) {
  const pathname = usePathname();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const attention = useAttention();
  const { openSearch } = useShell();
  const activeSection = sectionFor(pathname);
  const active = activeSection?.id ?? null;
  const onSettings = pathname === SETTINGS_HREF || pathname.startsWith(SETTINGS_HREF + "/");

  // The rail's width is a per-browser preference. Read after mount (the
  // shell's splash covers the first paint, so there is no visible jump).
  useEffect(() => {
    try {
      setCollapsed(localStorage.getItem(RAIL_KEY) === "collapsed");
    } catch {
      /* private mode: stay expanded */
    }
  }, []);

  function toggleRail() {
    setCollapsed((c) => {
      const next = !c;
      try {
        if (next) localStorage.setItem(RAIL_KEY, "collapsed");
        else localStorage.removeItem(RAIL_KEY);
      } catch {
        /* the toggle still works for this visit */
      }
      return next;
    });
  }

  useEffect(() => setDrawerOpen(false), [pathname]);

  useEffect(() => {
    document.body.style.overflow = drawerOpen ? "hidden" : "";
    return () => {
      document.body.style.overflow = "";
    };
  }, [drawerOpen]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setDrawerOpen(false);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  function handleSignOut() {
    setSigningOut(true);
    void signOut();
  }

  const title = onSettings ? "Settings" : (activeSection?.label ?? "Help24");

  return (
    <>
      {/* ── Desktop rail ─────────────────────────────────────── */}
      <nav
        aria-label="Console"
        className={[
          "hidden lg:flex lg:flex-col lg:h-screen lg:shrink-0 bg-page border-r border-gray-200",
          "transition-[width] duration-200 ease-out",
          collapsed ? "lg:w-[68px]" : "lg:w-[244px]",
        ].join(" ")}
      >
        {/* Brand and alerts */}
        <div className={["flex items-center h-14 shrink-0", collapsed ? "justify-center" : "gap-2.5 px-4"].join(" ")}>
          <BrandMark size={28} />
          {!collapsed && (
            <>
              <span className="text-gray-900 font-semibold text-[14px] tracking-tight">Help24</span>
              <div className="ml-auto -mr-1">
                <AlertsBell placement="rail" />
              </div>
            </>
          )}
        </div>

        {/* Search, and the bell when the rail is narrow */}
        <div className={["shrink-0 pb-2", collapsed ? "px-3 flex flex-col items-center gap-1" : "px-3"].join(" ")}>
          {collapsed ? (
            <>
              <IconButton label="Search (Ctrl K)" onClick={openSearch}>
                <SearchGlyph className="w-[18px] h-[18px]" />
              </IconButton>
              <AlertsBell placement="rail-compact" />
            </>
          ) : (
            <button
              onClick={openSearch}
              className="w-full flex items-center gap-2.5 h-9 px-3 rounded-lg bg-surface border border-gray-200 text-gray-500 hover:text-gray-800 hover:border-gray-300 transition-colors"
            >
              <SearchGlyph className="w-[14px] h-[14px]" />
              <span className="text-[12.5px]">Search</span>
              <kbd className="ml-auto text-[10.5px] font-sans text-gray-400">Ctrl K</kbd>
            </button>
          )}
        </div>

        {/* Grouped sections */}
        <div className={["flex-1 overflow-y-auto overflow-x-hidden pb-3", collapsed ? "px-2.5" : "px-3"].join(" ")}>
          {GROUPS.map((g) => (
            <div key={g.id} className="pt-3 first:pt-1">
              {g.label &&
                (collapsed ? (
                  <div className="mx-2 mb-2 h-px bg-gray-200" aria-hidden />
                ) : (
                  <p className="px-3 pb-1.5 text-[11px] font-medium text-gray-500">{g.label}</p>
                ))}
              <ul className="space-y-0.5">
                {g.sections.map((s) => (
                  <li key={s.id}>
                    <SectionLink section={s} active={active === s.id} badge={attention[s.id]} compact={collapsed} />
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <AccountFooter
          email={supabaseEmail}
          arbitration={arbitration}
          onSettings={onSettings}
          signingOut={signingOut}
          onSignOut={handleSignOut}
          compact={collapsed}
        />

        {/* Collapse control, out of the way at the very bottom */}
        <div className={["shrink-0 border-t border-gray-200 p-2", collapsed ? "flex justify-center" : ""].join(" ")}>
          <button
            onClick={toggleRail}
            aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            className={[
              "flex items-center gap-3 h-8 rounded-lg text-[12px] text-gray-400 hover:text-gray-800 hover:bg-gray-200/50 transition-colors",
              collapsed ? "w-10 justify-center" : "w-full px-3",
            ].join(" ")}
          >
            <PanelIcon className={["w-4 h-4 transition-transform", collapsed ? "rotate-180" : ""].join(" ")} />
            {!collapsed && "Collapse"}
          </button>
        </div>
      </nav>

      {/* ── Phone top bar ────────────────────────────────────── */}
      <header className="lg:hidden fixed top-0 inset-x-0 z-30 h-14 bg-page border-b border-gray-200 flex items-center gap-2 pl-2 pr-2">
        <button
          onClick={() => setDrawerOpen(true)}
          aria-label="Open navigation"
          aria-expanded={drawerOpen}
          className="relative w-10 h-10 flex items-center justify-center rounded-lg text-gray-600 hover:text-gray-900 hover:bg-gray-200/70"
        >
          <MenuIcon className="w-[22px] h-[22px]" />
          {hasWork(attention) && (
            <span className="absolute top-2 right-2 w-2 h-2 rounded-full bg-caution-500 ring-2 ring-page" />
          )}
        </button>
        <span className="text-gray-900 font-semibold text-[15px] tracking-tight truncate">{title}</span>
        <div className="ml-auto flex items-center gap-0.5">
          <IconButton label="Search" onClick={openSearch}>
            <SearchGlyph className="w-[18px] h-[18px]" />
          </IconButton>
          <AlertsBell placement="topbar" />
        </div>
      </header>

      {/* ── Phone drawer ─────────────────────────────────────── */}
      <div
        aria-hidden
        onClick={() => setDrawerOpen(false)}
        className={[
          "lg:hidden fixed inset-0 z-40 bg-black/40 transition-opacity duration-200",
          drawerOpen ? "opacity-100" : "opacity-0 pointer-events-none",
        ].join(" ")}
      />
      <nav
        aria-label="Mobile navigation"
        aria-hidden={drawerOpen ? undefined : true}
        inert={!drawerOpen}
        className={[
          "lg:hidden fixed inset-y-0 left-0 z-50 w-[296px] max-w-[85vw] flex flex-col",
          "bg-page border-r border-gray-200 pt-[env(safe-area-inset-top)]",
          "transition-transform duration-300 ease-out",
          drawerOpen ? "translate-x-0" : "-translate-x-full",
        ].join(" ")}
      >
        <div className="flex items-center gap-2.5 h-14 px-4 shrink-0">
          <BrandMark size={28} />
          <span className="text-gray-900 font-semibold text-[15px] tracking-tight">Help24</span>
          <button
            onClick={() => setDrawerOpen(false)}
            aria-label="Close navigation"
            className="ml-auto -mr-1 w-10 h-10 flex items-center justify-center rounded-lg text-gray-500 hover:text-gray-900 hover:bg-gray-200/70"
          >
            <XIcon className="w-5 h-5" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-3 pb-3">
          {GROUPS.map((g) => (
            <div key={g.id} className="pt-4 first:pt-1">
              {g.label && <p className="px-3 pb-1.5 text-[11.5px] font-medium text-gray-500">{g.label}</p>}
              <ul className="space-y-0.5">
                {g.sections.map((s) => (
                  <li key={s.id}>
                    <SectionLink section={s} active={active === s.id} badge={attention[s.id]} large />
                    {active === s.id && s.pages.length > 1 && <SubPages section={s} pathname={pathname} />}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="pb-[env(safe-area-inset-bottom)]">
          <AccountFooter
            email={supabaseEmail}
            arbitration={arbitration}
            onSettings={onSettings}
            signingOut={signingOut}
            onSignOut={handleSignOut}
          />
        </div>
      </nav>
    </>
  );
}

function hasWork(a: Attention): boolean {
  return Object.values(a).some((v) => (v?.count ?? 0) > 0);
}

/* ─── Pieces ────────────────────────────────────────────── */

function IconButton({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      aria-label={label}
      title={label}
      className="w-9 h-9 flex items-center justify-center rounded-lg text-gray-500 hover:text-gray-900 hover:bg-gray-200/70 transition-colors"
    >
      {children}
    </button>
  );
}

function Badge({ badge, dot = false }: { badge?: { count: number; high: boolean }; dot?: boolean }) {
  if (!badge || badge.count <= 0) return null;
  const tone = badge.high ? "bg-critical-500 text-white" : "bg-gray-200 text-gray-800";
  if (dot) {
    return (
      <span
        className={[
          "absolute -top-1 -right-1.5 min-w-[16px] h-[16px] px-1 rounded-full text-[9.5px] font-semibold leading-[16px] text-center tabular-nums ring-2 ring-page",
          tone,
        ].join(" ")}
      >
        {badgeText(badge.count)}
      </span>
    );
  }
  return (
    <span
      className={[
        "inline-flex items-center justify-center min-w-[20px] h-[20px] px-1.5 rounded-full text-[11px] font-semibold tabular-nums leading-none",
        tone,
      ].join(" ")}
    >
      {badgeText(badge.count)}
    </span>
  );
}

function SectionLink({
  section,
  active,
  badge,
  compact = false,
  large = false,
}: {
  section: NavSection;
  active: boolean;
  badge?: { count: number; high: boolean };
  compact?: boolean;
  large?: boolean;
}) {
  const Icon = ICONS[section.id];
  const label = badge && badge.count > 0 ? `${section.label}, ${badge.count} waiting` : section.label;
  return (
    <Link
      href={section.href}
      aria-current={active ? "page" : undefined}
      aria-label={compact ? label : undefined}
      title={compact ? label : undefined}
      className={[
        "relative flex items-center rounded-lg font-medium transition-colors",
        compact ? "h-10 w-12 mx-auto justify-center" : large ? "h-11 gap-3 px-3 text-[15px]" : "h-9 gap-3 px-3 text-[13px]",
        active ? "text-gray-900 bg-gray-200/70" : "text-gray-600 hover:text-gray-900 hover:bg-gray-200/50",
      ].join(" ")}
    >
      {active && <span className="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-4 bg-accent-500 rounded-r-full" />}
      <span className="relative">
        <Icon className={["w-[18px] h-[18px] shrink-0", active ? "text-gray-900" : "text-gray-500"].join(" ")} />
        {compact && <Badge badge={badge} dot />}
      </span>
      {!compact && (
        <>
          <span className="flex-1 truncate">{section.label}</span>
          <Badge badge={badge} />
        </>
      )}
    </Link>
  );
}

/** The active section's pages, under it in the phone drawer. */
function SubPages({ section, pathname }: { section: NavSection; pathname: string }) {
  // Read after mount: the server has no query string to match against, and
  // reading it during render would differ between server and browser.
  const [search, setSearch] = useState<URLSearchParams | null>(null);
  useEffect(() => setSearch(new URLSearchParams(window.location.search)), [pathname]);
  const current = activePageHref(section.pages, pathname, search);
  return (
    <ul className="ml-[22px] mt-0.5 mb-1.5 pl-4 border-l border-gray-200 space-y-0.5">
      {section.pages.map((p) => (
        <li key={p.href}>
          <Link
            href={p.href}
            aria-current={p.href === current ? "page" : undefined}
            className={[
              "flex items-center h-10 px-3 rounded-lg text-[14px] transition-colors",
              p.href === current ? "text-gray-900 bg-gray-200/60" : "text-gray-500 hover:text-gray-900",
            ].join(" ")}
          >
            {p.label}
          </Link>
        </li>
      ))}
    </ul>
  );
}

function AccountFooter({
  email,
  arbitration,
  onSettings,
  signingOut,
  onSignOut,
  compact = false,
}: {
  email: string | null;
  arbitration: ArbitrationIdentity;
  onSettings: boolean;
  signingOut: boolean;
  onSignOut: () => void;
  compact?: boolean;
}) {
  const initial = email ? email[0].toUpperCase() : "?";
  const role = arbitration.connected && arbitration.role ? ROLE_LABELS[arbitration.role] : null;
  const avatar = (
    <span className="w-8 h-8 rounded-full bg-gray-200 ring-1 ring-gray-300/60 flex items-center justify-center text-[12px] font-semibold text-gray-800 shrink-0 select-none">
      {initial}
    </span>
  );

  if (compact) {
    return (
      <div className="shrink-0 border-t border-gray-200 py-2 flex flex-col items-center gap-1">
        <Link
          href={SETTINGS_HREF}
          aria-current={onSettings ? "page" : undefined}
          aria-label={`Settings, ${email ?? "your account"}`}
          title={`Settings (${email ?? "your account"})`}
          className={["p-1 rounded-full", onSettings ? "ring-2 ring-brand-400" : "hover:ring-2 hover:ring-gray-300"].join(" ")}
        >
          {avatar}
        </Link>
        <button
          onClick={onSignOut}
          disabled={signingOut}
          aria-label="Sign out"
          title="Sign out"
          className="w-9 h-9 flex items-center justify-center rounded-lg text-gray-400 hover:text-gray-900 hover:bg-gray-200/50 disabled:opacity-40"
        >
          <LogOutIcon className="w-4 h-4" />
        </button>
      </div>
    );
  }

  return (
    <div className="shrink-0 border-t border-gray-200 p-3 space-y-0.5">
      <Link
        href={SETTINGS_HREF}
        aria-current={onSettings ? "page" : undefined}
        title="Settings"
        className={[
          "flex items-center gap-3 px-2 py-2 rounded-lg transition-colors",
          onSettings ? "bg-gray-200/70" : "hover:bg-gray-200/50",
        ].join(" ")}
      >
        {avatar}
        <span className="min-w-0 flex-1">
          <span className="block text-[12.5px] text-gray-800 truncate leading-tight">{email ?? " "}</span>
          <span className={["block text-[11px] leading-tight mt-0.5", role ? "text-gray-500" : "text-accent-600"].join(" ")}>
            {role ?? "No admin access"}
          </span>
        </span>
        <CogIcon className="w-4 h-4 text-gray-500 shrink-0" />
      </Link>
      <button
        onClick={onSignOut}
        disabled={signingOut}
        className="w-full flex items-center gap-3 px-3 h-9 rounded-lg text-[12.5px] font-medium text-gray-500 hover:text-gray-900 hover:bg-gray-200/50 transition-colors disabled:opacity-40"
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
/* Inbox: the tray mail lands in. */
const InboxIcon = svg("M2.25 13.5h3.86a2.25 2.25 0 012.012 1.244l.256.512a2.25 2.25 0 002.013 1.244h3.218a2.25 2.25 0 002.013-1.244l.256-.512a2.25 2.25 0 012.013-1.244h3.859m-19.5.338V18a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18v-4.162c0-.224-.034-.447-.1-.661L19.24 5.338a2.25 2.25 0 00-2.15-1.588H6.911a2.25 2.25 0 00-2.15 1.588L2.35 13.177a2.25 2.25 0 00-.1.661z");
const ChartIcon = svg("M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z");
const XIcon = svg("M6 18L18 6M6 6l12 12");
/* A panel with its edge: collapse and expand the rail. */
const PanelIcon = svg(["M3.75 5.25h16.5v13.5H3.75z", "M9 5.25v13.5", "M15.75 10.5L13.5 12l2.25 1.5"]);
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
  inbox: InboxIcon,
  disputes: ScaleIcon,
  "trust-safety": ShieldIcon,
  partners: UserPlusIcon,
  promotion: MegaphoneIcon,
  insights: ChartIcon,
};
