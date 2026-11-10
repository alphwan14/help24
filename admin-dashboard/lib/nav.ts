import type { AdminAlert } from "./alerts";

/**
 * The console's map: every section, and the pages inside it.
 *
 * ONE source for three surfaces. The rail and the drawer list the sections;
 * each section's layout renders its pages as tabs (SectionNav); the search
 * palette offers every page by name. Before this, the sidebar held one copy
 * and three layouts held their own, and they had drifted (Restricted was a
 * tab but not in the menu; Failed payments and Completed jobs were in neither).
 */

export type NavPage = { label: string; href: string; keywords?: string };
export type NavSectionId =
  | "overview"
  | "operations"
  | "inbox"
  | "users"
  | "marketplace"
  | "payments"
  | "disputes"
  | "trust-safety"
  | "partners"
  | "promotion"
  | "insights";

/**
 * Sections are grouped by how often an admin goes there, not by data model.
 * "home" is unlabelled and always first. "queues" is where work waits on us
 * (the counts live there). The rest is marketplace management and platform
 * tools, visited on purpose rather than every hour.
 */
export type NavGroupId = "home" | "queues" | "marketplace" | "platform";

export const NAV_GROUPS: Array<{ id: NavGroupId; label: string | null }> = [
  { id: "home", label: null },
  { id: "queues", label: "Queues" },
  { id: "marketplace", label: "Marketplace" },
  { id: "platform", label: "Platform" },
];

export type NavSection = {
  id: NavSectionId;
  group: NavGroupId;
  label: string;
  /** Where the section opens. Its first page unless that page redirects. */
  href: string;
  /** Path prefix that belongs to this section. */
  base: string;
  pages: NavPage[];
};

export const NAV: NavSection[] = [
  {
    id: "overview",
    group: "home",
    label: "Overview",
    href: "/dashboard/overview",
    base: "/dashboard/overview",
    pages: [
      { label: "General", href: "/dashboard/overview", keywords: "home dashboard kpi" },
      { label: "Growth", href: "/dashboard/overview/growth", keywords: "signups" },
      { label: "Geography", href: "/dashboard/overview/geography", keywords: "cities map" },
      { label: "Revenue", href: "/dashboard/overview/revenue", keywords: "fees money" },
    ],
  },
  {
    id: "inbox",
    group: "queues",
    label: "Inbox",
    href: "/dashboard/inbox",
    base: "/dashboard/inbox",
    pages: [
      { label: "Conversations", href: "/dashboard/inbox", keywords: "support messages email info help" },
      { label: "New message", href: "/dashboard/inbox/new", keywords: "email member write compose" },
    ],
  },
  {
    id: "disputes",
    group: "queues",
    label: "Disputes",
    href: "/dashboard/disputes",
    base: "/dashboard/disputes",
    pages: [
      { label: "Open", href: "/dashboard/disputes", keywords: "cases" },
      { label: "Resolved", href: "/dashboard/disputes/resolved" },
      { label: "Refunds", href: "/dashboard/disputes/refunds" },
    ],
  },
  {
    id: "trust-safety",
    group: "queues",
    label: "Trust and safety",
    href: "/dashboard/trust-safety/reports",
    base: "/dashboard/trust-safety",
    pages: [
      { label: "Reports", href: "/dashboard/trust-safety/reports" },
      { label: "Moderation queue", href: "/dashboard/trust-safety/queue", keywords: "triage" },
      { label: "Verifications", href: "/dashboard/trust-safety/verifications", keywords: "identity kyc" },
      { label: "Suspended", href: "/dashboard/trust-safety/suspended" },
      { label: "Banned", href: "/dashboard/trust-safety/banned" },
      { label: "Restricted", href: "/dashboard/trust-safety/restricted" },
      { label: "Audit log", href: "/dashboard/trust-safety/audit", keywords: "history actions" },
    ],
  },
  {
    id: "payments",
    group: "queues",
    label: "Payments",
    href: "/dashboard/payments",
    base: "/dashboard/payments",
    pages: [
      { label: "Transactions", href: "/dashboard/payments", keywords: "mpesa" },
      { label: "Escrow", href: "/dashboard/payments/escrow", keywords: "payouts held" },
      { label: "Pending", href: "/dashboard/payments/pending" },
      { label: "Failed", href: "/dashboard/payments/failed", keywords: "errors" },
      { label: "Completed", href: "/dashboard/payments/completed", keywords: "paid" },
    ],
  },
  {
    id: "marketplace",
    group: "marketplace",
    label: "Marketplace",
    href: "/dashboard/marketplace",
    base: "/dashboard/marketplace",
    pages: [
      { label: "All activity", href: "/dashboard/marketplace" },
      { label: "Requests", href: "/dashboard/marketplace/requests", keywords: "posts" },
      { label: "Offers", href: "/dashboard/marketplace/offers", keywords: "posts" },
      { label: "Hiring", href: "/dashboard/marketplace/jobs", keywords: "jobs" },
      { label: "Job matches", href: "/dashboard/marketplace/active-jobs", keywords: "active jobs" },
      { label: "Completed", href: "/dashboard/marketplace/completed", keywords: "finished jobs" },
    ],
  },
  {
    id: "users",
    group: "marketplace",
    label: "Users",
    href: "/dashboard/users",
    base: "/dashboard/users",
    pages: [
      { label: "All users", href: "/dashboard/users", keywords: "people accounts" },
      { label: "Active", href: "/dashboard/users/active" },
      { label: "Admin roles", href: "/dashboard/users/admins", keywords: "staff invites logins" },
    ],
  },
  {
    id: "partners",
    group: "marketplace",
    label: "Partners",
    href: "/dashboard/partners",
    base: "/dashboard/partners",
    pages: [
      { label: "Agents", href: "/dashboard/partners", keywords: "codes referrals" },
      { label: "Provider cards", href: "/dashboard/partners/cards", keywords: "qr" },
    ],
  },
  {
    id: "promotion",
    group: "marketplace",
    label: "Promotion",
    href: "/dashboard/promotion",
    base: "/dashboard/promotion",
    pages: [
      { label: "Campaigns", href: "/dashboard/promotion", keywords: "promote business ads" },
      { label: "Pending review", href: "/dashboard/promotion?status=pending_review" },
      { label: "Packages", href: "/dashboard/promotion/packages", keywords: "pricing" },
      { label: "Revenue", href: "/dashboard/promotion/revenue" },
    ],
  },
  {
    id: "operations",
    group: "platform",
    label: "Operations",
    href: "/dashboard/operations/live",
    base: "/dashboard/operations",
    pages: [
      { label: "Live", href: "/dashboard/operations/live", keywords: "now realtime" },
      { label: "App controls", href: "/dashboard/operations/controls", keywords: "switches flags maintenance" },
    ],
  },
  {
    id: "insights",
    group: "platform",
    label: "Insights",
    href: "/dashboard/insights/trends",
    base: "/dashboard/insights",
    pages: [
      { label: "Trends", href: "/dashboard/insights/trends" },
      { label: "Analytics", href: "/dashboard/insights/analytics" },
      { label: "Heatmaps", href: "/dashboard/insights/heatmap" },
    ],
  },
];

export const SETTINGS_HREF = "/dashboard/settings";

function underBase(pathname: string, base: string): boolean {
  return pathname === base || pathname.startsWith(base + "/");
}

/** The section a path belongs to, or null (Settings, unknown). */
export function sectionFor(pathname: string): NavSection | null {
  return NAV.find((s) => underBase(pathname, s.base)) ?? null;
}

/** The sections of each group, in nav order; groups with none are left out. */
export function groupedNav(): Array<{ id: NavGroupId; label: string | null; sections: NavSection[] }> {
  return NAV_GROUPS.map((g) => ({ ...g, sections: NAV.filter((s) => s.group === g.id) })).filter((g) => g.sections.length > 0);
}

export function sectionById(id: NavSectionId): NavSection {
  const s = NAV.find((x) => x.id === id);
  if (!s) throw new Error(`Unknown nav section ${id}`);
  return s;
}

/**
 * The page a location is on. Longest match wins; a page whose href carries a
 * query string only matches when every one of its params is present, so
 * "Pending review" (?status=pending_review) wins over "Campaigns" there and
 * loses everywhere else.
 */
export function activePageHref(pages: NavPage[], pathname: string, search: URLSearchParams | null): string | null {
  let best: { href: string; score: number } | null = null;
  for (const p of pages) {
    const [path, query] = p.href.split("?");
    if (!underBase(pathname, path)) continue;
    let score = path.length * 10;
    if (query) {
      const want = new URLSearchParams(query);
      let all = true;
      want.forEach((v, k) => {
        if (search?.get(k) !== v) all = false;
      });
      if (!all) continue;
      score += 5;
    }
    if (!best || score > best.score) best = { href: p.href, score };
  }
  return best?.href ?? null;
}

/**
 * Open (unreviewed) high and medium alerts per section, by where each alert
 * links. Low alerts are marketplace health, not work, so they never put a
 * number in the nav: a count that is always lit teaches people to ignore it.
 */
export function attentionBySection(alerts: AdminAlert[]): Partial<Record<NavSectionId, { count: number; high: boolean }>> {
  const out: Partial<Record<NavSectionId, { count: number; high: boolean }>> = {};
  for (const a of alerts) {
    if (a.review || a.priority === "low" || !a.count) continue;
    const path = (a.href ?? "").split(/[?#]/)[0];
    const section = sectionFor(path);
    if (!section) continue;
    const cur = out[section.id] ?? { count: 0, high: false };
    cur.count += a.count;
    cur.high = cur.high || a.priority === "high";
    out[section.id] = cur;
  }
  return out;
}

/** "99+" past 99, so a badge never grows wider than the rail allows. */
export function badgeText(n: number): string {
  return n > 99 ? "99+" : String(n);
}
