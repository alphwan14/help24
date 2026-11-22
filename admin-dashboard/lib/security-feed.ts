import "server-only";
import { createServiceClient } from "@/lib/supabase-server";
import { ACTION_LABELS } from "@/lib/moderation-labels";
import {
  authAction,
  authMethod,
  controlChangeLabel,
  describeDevice,
  describePlace,
  eventCategory,
  eventLabel,
  FINANCE_ACTIONS,
  humanize,
  memberMethod,
  PARTNER_ACTIONS,
  refusalReason,
  typeChangeLabel,
  type Category,
  type Who,
} from "@/lib/security-format";

/**
 * The security log: one timeline built from every place Help24 records who did
 * what. Read at request time, newest first, page by page.
 *
 *   security_events        console opened or refused, failed sign-ins, member sign-ins (146)
 *   security_auth_events() Supabase Auth's log: admin and partner sign-ins, password changes (146)
 *   moderation_actions     warnings, restrictions, bans, content decisions (114)
 *   admin_finance_actions  manual settlements, rulings applied (117)
 *   partner_admin_events   partner agents added, suspended, invited (128)
 *   post_type_changes      listings an admin reclassified (145)
 *   app_settings_history   app control changes (125)
 *   user_auth_identities   a member's sign-in linked, by hand or by backfill (099)
 *
 * A source that cannot be read (its migration not applied, a failed query) is
 * named in `missing` and the rest still show: a partial log said out loud is
 * better than none.
 */

export type FeedItem = {
  id: string;
  at: string;
  who: Who;
  category: Category;
  outcome: "success" | "failure";
  actor: { name: string | null; email: string | null; role: string | null; person: string | null; href: string | null };
  action: string;
  method: string | null;
  target: { label: string; href: string | null } | null;
  reason: string | null;
  ip: string | null;
  device: string | null;
  place: string | null;
  userAgent: string | null;
  source: string;
};

export type FeedQuery = {
  who: "all" | Exclude<Who, "other">;
  category: "all" | Category | "failed";
  person: { kind: "admin" | "member"; id: string } | null;
  before: string | null;
  limit: number;
};

export type FeedPage = { items: FeedItem[]; nextBefore: string | null; missing: string[]; logReady: boolean };

type Admin = { id: string; email: string; name: string | null; role: string };

const ADMIN_HREF = "/dashboard/users/admins";
const memberHref = (id: string) => `/dashboard/users/${encodeURIComponent(id)}`;

export async function loadSecurityFeed(q: FeedQuery): Promise<FeedPage> {
  const db = createServiceClient();
  const before = q.before ?? new Date(Date.now() + 60_000).toISOString();
  const n = q.limit + 1;
  const missing: string[] = [];
  let logReady = true;

  const { data: adminRows } = await db.from("admin_users").select("id, email, name, role");
  const admins = (adminRows ?? []) as Admin[];
  const adminById = new Map(admins.map((a) => [a.id, a]));
  const adminByEmail = new Map(admins.map((a) => [a.email.toLowerCase(), a]));
  const personAdmin = q.person?.kind === "admin" ? (adminById.get(q.person.id) ?? null) : null;
  const personMember = q.person?.kind === "member" ? q.person.id : null;

  const wants = (who: Who, category: Category) =>
    (q.who === "all" || q.who === who) && (q.category === "all" || q.category === category || q.category === "failed");
  const adminActionsWanted = wants("admin", "admin_action") && !personMember && q.category !== "failed";

  const adminActor = (id: string | null, email: string | null, role: string | null) => {
    const a = (id && adminById.get(id)) || (email && adminByEmail.get(email.toLowerCase())) || null;
    return {
      name: a?.name ?? null,
      email: a?.email ?? email,
      role: a?.role ?? role,
      person: a ? `admin:${a.id}` : null,
      href: ADMIN_HREF,
    };
  };

  const items: FeedItem[] = [];
  const memberIds = new Set<string>();
  const jobs: Array<Promise<void>> = [];

  // 1. The log's own events.
  jobs.push(
    (async () => {
      if (!(wants("admin", "sign_in") || wants("member", "sign_in") || wants("partner", "sign_in") || wants("admin", "account"))) return;
      let r = db
        .from("security_events")
        .select("id, occurred_at, actor_kind, admin_id, user_id, actor_email, actor_role, event, outcome, ip, user_agent, country, city, detail")
        .lt("occurred_at", before)
        .order("occurred_at", { ascending: false })
        .limit(n);
      if (q.who !== "all") r = r.eq("actor_kind", q.who);
      if (q.category === "failed") r = r.eq("outcome", "failure");
      if (personAdmin) r = r.or(`admin_id.eq.${personAdmin.id},actor_email.eq."${personAdmin.email.toLowerCase().replace(/"/g, "")}"`);
      if (personMember) r = r.eq("user_id", personMember);
      if (q.person && !personAdmin && !personMember) return;
      const { data, error } = await r;
      if (error) {
        logReady = false;
        missing.push("sign-ins and console access (migration 146)");
        return;
      }
      for (const e of data ?? []) {
        const detail = (e.detail ?? {}) as Record<string, string>;
        const raw = e.actor_kind as "admin" | "member" | "partner" | "system";
        const kind: Who = raw === "system" ? "other" : raw;
        const category = eventCategory(e.event as string);
        if (q.category !== "all" && q.category !== "failed" && q.category !== category) continue;
        if (kind === "member" && e.user_id) memberIds.add(e.user_id as string);
        items.push({
          id: `se:${e.id}`,
          at: e.occurred_at as string,
          who: kind,
          category,
          outcome: e.outcome as "success" | "failure",
          actor:
            kind === "member"
              ? { name: null, email: null, role: null, person: `member:${e.user_id}`, href: memberHref(e.user_id as string) }
              : adminActor(e.admin_id as string | null, e.actor_email as string | null, e.actor_role as string | null),
          action: eventLabel(e.event as string),
          // How they signed in, where it reads naturally ("opened the console with Google").
          method:
            kind === "member"
              ? memberMethod(detail.provider)
              : e.event === "console.refused" || e.event === "google.refused"
                ? null
                : detail.method === "google"
                  ? "with Google"
                  : detail.method === "password"
                    ? "with password"
                    : null,
          target: null,
          reason: refusalReason(detail.reason),
          ip: (e.ip as string | null) ?? null,
          device: describeDevice(e.user_agent as string | null),
          place: describePlace(e.country as string | null, e.city as string | null),
          userAgent: (e.user_agent as string | null) ?? null,
          source: "Security log",
        });
      }
    })(),
  );

  // 2. Supabase Auth: admin and partner logins.
  jobs.push(
    (async () => {
      if (personMember || q.category === "failed" || q.category === "admin_action") return;
      if (!(wants("admin", "sign_in") || wants("admin", "account") || wants("partner", "sign_in") || wants("partner", "account"))) return;
      const { data, error } = await db.rpc("security_auth_events", { p_before: before, p_limit: personAdmin ? 500 : n });
      if (error) {
        missing.push("admin and partner logins (migration 146)");
        return;
      }
      const rows = (data ?? []) as Array<{ id: string; occurred_at: string; auth_id: string | null; email: string | null; action: string; provider: string | null; ip: string | null }>;
      const subjects = rows.map((r) => r.auth_id).filter((x): x is string => Boolean(x));
      const partnerSubjects = new Set<string>();
      if (subjects.length) {
        const { data: logins } = await db.from("partner_logins").select("auth_subject").in("auth_subject", [...new Set(subjects)]);
        for (const l of logins ?? []) partnerSubjects.add(l.auth_subject as string);
      }
      for (const r of rows) {
        const admin = r.email ? adminByEmail.get(r.email) : undefined;
        const who: Who = admin ? "admin" : r.auth_id && partnerSubjects.has(r.auth_id) ? "partner" : "other";
        if (q.who !== "all" && q.who !== who) continue;
        if (personAdmin && admin?.id !== personAdmin.id) continue;
        const { label, category } = authAction(r.action);
        if (q.category !== "all" && q.category !== category) continue;
        items.push({
          id: `au:${r.id}`,
          at: r.occurred_at,
          who,
          category,
          outcome: "success",
          actor: admin
            ? adminActor(admin.id, admin.email, admin.role)
            : { name: null, email: r.email, role: who === "partner" ? "Partner agent" : null, person: null, href: who === "partner" ? "/dashboard/partners" : null },
          action: label,
          method: r.action === "login" ? authMethod(r.provider) : null,
          target: null,
          reason: null,
          ip: r.ip,
          device: null,
          place: null,
          userAgent: null,
          source: "Supabase Auth",
        });
      }
    })(),
  );

  // 3. Moderation decisions (admin acting on a member).
  jobs.push(
    (async () => {
      const asMember = personMember && (q.who === "all" || q.who === "member") && (q.category === "all" || q.category === "account");
      if (!adminActionsWanted && !asMember) return;
      let r = db
        .from("moderation_actions")
        .select("id, created_at, action_type, admin_id, admin_email, admin_role, target_user_id, reason")
        .lt("created_at", before)
        .order("created_at", { ascending: false })
        .limit(n);
      if (personAdmin) r = r.eq("admin_id", personAdmin.id);
      if (personMember) r = r.eq("target_user_id", personMember);
      if (q.person && !personAdmin && !personMember) return;
      const { data, error } = await r;
      if (error) {
        missing.push("moderation decisions");
        return;
      }
      for (const m of data ?? []) {
        const target = m.target_user_id as string;
        memberIds.add(target);
        items.push({
          id: `mo:${m.id}`,
          at: m.created_at as string,
          who: asMember ? "member" : "admin",
          category: asMember ? "account" : "admin_action",
          outcome: "success",
          actor: adminActor(m.admin_id as string | null, m.admin_email as string | null, m.admin_role as string | null),
          action: ACTION_LABELS[m.action_type as string] ?? humanize(m.action_type as string),
          method: null,
          target: { label: target, href: memberHref(target) },
          reason: (m.reason as string | null) ?? null,
          ip: null,
          device: null,
          place: null,
          userAgent: null,
          source: "Trust and safety",
        });
      }
    })(),
  );

  // 4-6. Other admin actions: money, partners, listings, app controls.
  if (adminActionsWanted && !(q.person && !personAdmin)) {
    jobs.push(
      (async () => {
        let r = db
          .from("admin_finance_actions")
          .select("id, created_at, action_type, admin_id, admin_email, admin_role, transaction_id, reason")
          .lt("created_at", before)
          .order("created_at", { ascending: false })
          .limit(n);
        if (personAdmin) r = r.eq("admin_id", personAdmin.id);
        const { data, error } = await r;
        if (error) return void missing.push("payment actions");
        for (const f of data ?? []) {
          items.push({
            id: `fi:${f.id}`,
            at: f.created_at as string,
            who: "admin",
            category: "admin_action",
            outcome: "success",
            actor: adminActor(f.admin_id as string, f.admin_email as string, f.admin_role as string),
            action: FINANCE_ACTIONS[f.action_type as string] ?? humanize(f.action_type as string),
            method: null,
            target: { label: `Payment ${(f.transaction_id as string).slice(0, 8).toUpperCase()}`, href: "/dashboard/payments" },
            reason: (f.reason as string | null) ?? null,
            ip: null,
            device: null,
            place: null,
            userAgent: null,
            source: "Payments",
          });
        }
      })(),
      (async () => {
        let r = db
          .from("partner_admin_events")
          .select("id, created_at, action, admin_id, admin_email, admin_role, agent_id, reason")
          .lt("created_at", before)
          .order("created_at", { ascending: false })
          .limit(n);
        if (personAdmin) r = r.eq("admin_id", personAdmin.id);
        const { data, error } = await r;
        if (error) return void missing.push("partner changes");
        const agentIds = [...new Set((data ?? []).map((p) => p.agent_id as string))];
        const names = new Map<string, string>();
        if (agentIds.length) {
          const { data: agents } = await db.from("partner_agents").select("id, display_name, code").in("id", agentIds);
          for (const a of agents ?? []) names.set(a.id as string, `${a.display_name} (${a.code})`);
        }
        for (const p of data ?? []) {
          items.push({
            id: `pa:${p.id}`,
            at: p.created_at as string,
            who: "admin",
            category: "admin_action",
            outcome: "success",
            actor: adminActor(p.admin_id as string | null, p.admin_email as string | null, p.admin_role as string | null),
            action: PARTNER_ACTIONS[p.action as string] ?? humanize(p.action as string),
            method: null,
            target: { label: names.get(p.agent_id as string) ?? "Partner agent", href: "/dashboard/partners" },
            reason: (p.reason as string | null) ?? null,
            ip: null,
            device: null,
            place: null,
            userAgent: null,
            source: "Partners",
          });
        }
      })(),
      (async () => {
        let r = db
          .from("post_type_changes")
          .select("id, created_at, post_id, from_type, to_type, changed_by, admin_email, reason")
          .eq("changed_by_kind", "admin")
          .lt("created_at", before)
          .order("created_at", { ascending: false })
          .limit(n);
        if (personAdmin) r = r.eq("changed_by", personAdmin.id);
        const { data, error } = await r;
        if (error) return void missing.push("listing type changes");
        for (const t of data ?? []) {
          items.push({
            id: `pt:${t.id}`,
            at: t.created_at as string,
            who: "admin",
            category: "admin_action",
            outcome: "success",
            actor: adminActor(t.changed_by as string | null, t.admin_email as string | null, null),
            action: typeChangeLabel(t.from_type as string, t.to_type as string),
            method: null,
            target: { label: "Listing", href: `/dashboard/marketplace/requests/${t.post_id}` },
            reason: (t.reason as string | null) ?? null,
            ip: null,
            device: null,
            place: null,
            userAgent: null,
            source: "Marketplace",
          });
        }
      })(),
      (async () => {
        let r = db
          .from("app_settings_history")
          .select("id, created_at, key, admin_id, admin_email, admin_role, reason")
          .lt("created_at", before)
          .order("created_at", { ascending: false })
          .limit(n);
        if (personAdmin) r = r.eq("admin_id", personAdmin.id);
        const { data, error } = await r;
        if (error) return void missing.push("app control changes");
        for (const c of data ?? []) {
          items.push({
            id: `ac:${c.id}`,
            at: c.created_at as string,
            who: "admin",
            category: "admin_action",
            outcome: "success",
            actor: adminActor(c.admin_id as string, c.admin_email as string, c.admin_role as string),
            action: controlChangeLabel(c.key as string),
            method: null,
            target: { label: "App controls", href: "/dashboard/operations/controls" },
            reason: (c.reason as string | null) ?? null,
            ip: null,
            device: null,
            place: null,
            userAgent: null,
            source: "Operations",
          });
        }
      })(),
    );
  }

  // 7. A member's sign-in linked to their account.
  jobs.push(
    (async () => {
      if (personAdmin || q.category === "failed" || !wants("member", "account")) return;
      let r = db
        .from("user_auth_identities")
        .select("help24_user_id, provider, subject, linked_at, linked_by")
        .lt("linked_at", before)
        .order("linked_at", { ascending: false })
        .limit(n);
      if (personMember) r = r.eq("help24_user_id", personMember);
      const { data, error } = await r;
      if (error) return void missing.push("linked sign-ins");
      for (const i of data ?? []) {
        const id = i.help24_user_id as string;
        memberIds.add(id);
        items.push({
          id: `li:${i.provider}:${i.subject}`,
          at: i.linked_at as string,
          who: "member",
          category: "account",
          outcome: "success",
          actor: { name: null, email: null, role: null, person: `member:${id}`, href: memberHref(id) },
          action: i.provider === "supabase" ? "Web login linked to their account" : "App sign-in linked to their account",
          method: null,
          target: null,
          reason: i.linked_by ? `Linked by hand: ${i.linked_by}` : null,
          ip: null,
          device: null,
          place: null,
          userAgent: null,
          source: "Accounts",
        });
      }
    })(),
  );

  await Promise.all(jobs);

  items.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  const page = items.slice(0, q.limit);
  const nextBefore = items.length > q.limit ? page[page.length - 1].at : null;

  // Names for the members on this page.
  const ids = [...memberIds].filter((id) => page.some((i) => i.actor.person === `member:${id}` || i.target?.href === memberHref(id)));
  if (ids.length) {
    const { data: users } = await db.from("users").select("id, name, email, phone_number").in("id", ids);
    const byId = new Map((users ?? []).map((u) => [u.id as string, u]));
    for (const i of page) {
      const pid = i.actor.person?.startsWith("member:") ? i.actor.person.slice(7) : null;
      const u = pid ? byId.get(pid) : undefined;
      if (u) {
        i.actor.name = (u.name as string | null) || null;
        i.actor.email = (u.email as string | null) || (u.phone_number as string | null) || null;
      } else if (pid && !i.actor.name) {
        i.actor.name = "Member";
        i.actor.email = pid;
      }
      if (i.target?.href?.startsWith("/dashboard/users/")) {
        const tu = byId.get(i.target.label);
        if (tu) i.target.label = (tu.name as string | null) || (tu.email as string | null) || i.target.label;
      }
    }
  }

  return { items: page, nextBefore, missing, logReady };
}
