import "server-only";
import { createServiceClient } from "./supabase-server";

/**
 * The live operations board: what is happening on Help24 right now.
 *
 * Every figure is read fresh on each refresh (the page re-renders every 30 s)
 * and each block carries its own `failed` flag — a block that could not be
 * read says so, and is never drawn as zero.
 */

/** The app's heartbeat is 60 s; online means a fresh one (lib/activity.ts). */
const HEARTBEAT_STALE_MS = 150_000;
/** An open request older than this with no applications needs someone found. */
export const WAITING_AFTER_HOURS = 2;
const WAITING_LOOKBACK_DAYS = 14;

export type Block<T> = { data: T; failed: boolean };

export type LivePerson = { id: string; name: string };
export type LiveJob = { id: string; title: string; type: string | null; since: string; providerId: string | null };
export type WaitingRequest = { id: string; title: string; location: string | null; category: string | null; created_at: string };
export type LiveShare = { senderId: string; name: string; since: string; until: string };
export type Money = { heldKes: number; heldCount: number; payingOutKes: number; payingOutCount: number; disputedCount: number };
export type FeedItem = { kind: "posted" | "applied" | "paid" | "payment_failed"; label: string; at: string; href: string | null };

export type LiveBoard = {
  at: string;
  online: Block<LivePerson[]>;
  activeToday: Block<number | null>;
  jobs: Block<{ total: number; latest: LiveJob[] }>;
  waiting: Block<WaitingRequest[]>;
  shares: Block<LiveShare[]>;
  money: Block<Money>;
  feed: Block<FeedItem[]>;
};

type Res<T> = { data: T | null; error: { message: string } | null; count?: number | null };

function fail(what: string, err: { message: string } | null): boolean {
  if (err) console.error(`[live] ${what} unavailable:`, err.message);
  return !!err;
}

const nameOf = (u: { name?: string | null } | undefined) => u?.name?.trim() || "Unnamed member";

export async function loadLiveBoard(now = Date.now()): Promise<LiveBoard> {
  const db = createServiceClient();
  const iso = (ms: number) => new Date(ms).toISOString();
  const day = iso(now - 86400_000);

  const [online, today, jobs, open, shares, escrow, posts, apps, txs] = (await Promise.all([
    db.from("users").select("id, name").eq("is_online", true).gte("last_seen", iso(now - HEARTBEAT_STALE_MS)).limit(100),
    db.from("users").select("id", { count: "exact", head: true }).or(`last_seen.gte."${day}",last_login.gte."${day}"`),
    db
      .from("posts")
      .select("id, title, type, created_at, selected_provider_id", { count: "exact" })
      .eq("status", "assigned")
      .is("archived_at", null)
      .order("created_at", { ascending: false })
      .limit(8),
    db
      .from("posts")
      .select("id, title, location, category, created_at")
      .eq("type", "request")
      .eq("status", "open")
      .is("archived_at", null)
      .is("selected_provider_id", null)
      .lte("created_at", iso(now - WAITING_AFTER_HOURS * 3600_000))
      .gte("created_at", iso(now - WAITING_LOOKBACK_DAYS * 86400_000))
      .order("created_at", { ascending: true })
      .limit(200),
    db.from("chat_messages").select("sender_id, created_at, live_until").gt("live_until", iso(now)).limit(50),
    db.from("escrow").select("status, amount").in("status", ["paid", "locked", "payout_pending", "disputed"]).limit(5000),
    db.from("posts").select("id, title, type, created_at").order("created_at", { ascending: false }).limit(8),
    db.from("applications").select("id, post_id, created_at, posts(title, type)").order("created_at", { ascending: false }).limit(8),
    db.from("transactions").select("id, post_id, status, total_paid, amount, created_at").order("created_at", { ascending: false }).limit(8),
  ])) as Res<Record<string, unknown>[]>[];

  // Requests still waiting: those with no application at all.
  let waiting: WaitingRequest[] = [];
  let waitingFailed = fail("open requests", open.error);
  if (!waitingFailed && open.data?.length) {
    const ids = open.data.map((p) => p.id as string);
    const applied = await db.from("applications").select("post_id").in("post_id", ids);
    waitingFailed = fail("applications for open requests", applied.error);
    const answered = new Set((applied.data ?? []).map((a) => a.post_id as string));
    waiting = (open.data as unknown as WaitingRequest[]).filter((p) => !answered.has(p.id)).slice(0, 12);
  }

  // Names for the people sharing a live location.
  const shareRows = (shares.data ?? []) as Array<{ sender_id: string; created_at: string; live_until: string }>;
  const sharerIds = [...new Set(shareRows.map((s) => s.sender_id))];
  const sharers = sharerIds.length ? await db.from("users").select("id, name").in("id", sharerIds) : { data: [], error: null };
  const sharerName = new Map((sharers.data ?? []).map((u) => [u.id as string, nameOf(u as { name: string | null })]));

  const money: Money = { heldKes: 0, heldCount: 0, payingOutKes: 0, payingOutCount: 0, disputedCount: 0 };
  for (const e of (escrow.data ?? []) as Array<{ status: string; amount: number | null }>) {
    const amt = Number(e.amount ?? 0);
    if (e.status === "paid" || e.status === "locked") { money.heldKes += amt; money.heldCount++; }
    else if (e.status === "payout_pending") { money.payingOutKes += amt; money.payingOutCount++; }
    else if (e.status === "disputed") money.disputedCount++;
  }

  const requestHref = (id: string, type: unknown) => (type === "request" ? `/dashboard/marketplace/requests/${id}` : null);
  const feed: FeedItem[] = [
    ...((posts.data ?? []) as Array<{ id: string; title: string | null; type: string | null; created_at: string }>).map((p) => ({
      kind: "posted" as const,
      label: `New ${p.type ?? "listing"}: ${p.title?.trim() || "Untitled"}`,
      at: p.created_at,
      href: requestHref(p.id, p.type),
    })),
    ...((apps.data ?? []) as Array<{ post_id: string; created_at: string; posts: { title: string | null; type: string | null } | null }>).map((a) => ({
      kind: "applied" as const,
      label: `Offer sent on ${a.posts?.title?.trim() || "a listing"}`,
      at: a.created_at,
      href: requestHref(a.post_id, a.posts?.type),
    })),
    ...((txs.data ?? []) as Array<{ status: string; total_paid: number | null; amount: number | null; created_at: string }>).map((t) => ({
      kind: t.status === "failed" ? ("payment_failed" as const) : ("paid" as const),
      label: `${t.status === "failed" ? "Payment failed" : t.status === "pending" ? "Payment started" : "Payment into escrow"} · KES ${Number(t.total_paid ?? t.amount ?? 0).toLocaleString("en-KE")}`,
      at: t.created_at,
      href: "/dashboard/payments",
    })),
  ]
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
    .slice(0, 12);

  return {
    at: iso(now),
    online: {
      data: ((online.data ?? []) as Array<{ id: string; name: string | null }>).map((u) => ({ id: u.id, name: nameOf(u) })),
      failed: fail("online", online.error),
    },
    activeToday: { data: today.error ? null : (today.count ?? 0), failed: fail("active today", today.error) },
    jobs: {
      data: {
        total: jobs.count ?? jobs.data?.length ?? 0,
        latest: ((jobs.data ?? []) as Array<{ id: string; title: string | null; type: string | null; created_at: string; selected_provider_id: string | null }>).map((j) => ({
          id: j.id,
          title: j.title?.trim() || "Untitled",
          type: j.type,
          since: j.created_at,
          providerId: j.selected_provider_id,
        })),
      },
      failed: fail("jobs in progress", jobs.error),
    },
    waiting: { data: waiting, failed: waitingFailed },
    shares: {
      data: shareRows.map((s) => ({ senderId: s.sender_id, name: sharerName.get(s.sender_id) ?? "Unnamed member", since: s.created_at, until: s.live_until })),
      failed: fail("live locations", shares.error),
    },
    money: { data: money, failed: fail("escrow", escrow.error) },
    feed: { data: feed, failed: fail("recent activity", posts.error ?? apps.error ?? txs.error) },
  };
}
