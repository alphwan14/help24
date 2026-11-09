import "server-only";
import { cookies } from "next/headers";
import { createServiceClient } from "@/lib/supabase-server";
import { DEFAULT_PERIOD, isPeriodKey, resolvePeriod, type Period } from "@/lib/periods";
import type { ActiveRow, AppRow, PlaceRow, PostRow, PromoRow, TxRow, UserRow } from "@/lib/analytics";

const PERIOD_COOKIE = "h24_period"; // mirrors components/analytics/PeriodSelect

/** The period a request asks for: ?period=, else the admin's last choice, else 30 days. */
export async function periodFor(searchParams: Promise<{ period?: string }>): Promise<Period> {
  const { period } = await searchParams;
  if (isPeriodKey(period)) return resolvePeriod(period);
  const saved = (await cookies()).get(PERIOD_COOKIE)?.value;
  return resolvePeriod(isPeriodKey(saved) ? saved : DEFAULT_PERIOD);
}

type Page<T> = (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>;

/** Every row of a query, page by page (PostgREST returns at most 1,000 at a time). */
export async function readAll<T>(page: Page<T>, cap = 100_000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; from < cap; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  return out;
}

/** The window both halves of the comparison need. */
const windowOf = (p: Period) => ({ since: new Date(p.prevStart).toISOString(), until: new Date(p.end).toISOString() });

export async function readTransactions(p: Period): Promise<TxRow[]> {
  const db = createServiceClient();
  const { since, until } = windowOf(p);
  return readAll<TxRow>((a, b) =>
    db
      .from("transactions")
      .select("created_at, fee, total_paid, amount, status, post_id")
      .gte("created_at", since)
      .lt("created_at", until)
      .order("created_at")
      .range(a, b),
  );
}

export async function readPromotionSales(p: Period): Promise<PromoRow[]> {
  const db = createServiceClient();
  // created_at a day early: paid_at decides the period, and is a little later.
  const since = new Date(p.prevStart - 86_400_000).toISOString();
  return readAll<PromoRow>((a, b) =>
    db
      .from("promotion_payments")
      .select("paid_at, created_at, amount_kes")
      .eq("status", "paid")
      .gte("created_at", since)
      .order("created_at")
      .range(a, b),
  );
}

export async function readPosts(p: Period, select: string): Promise<PostRow[]> {
  const db = createServiceClient();
  const { since, until } = windowOf(p);
  return readAll<PostRow>((a, b) =>
    db.from("posts").select(select).gte("created_at", since).lt("created_at", until).order("created_at").range(a, b) as unknown as PromiseLike<{
      data: PostRow[] | null;
      error: { message: string } | null;
    }>,
  );
}

export async function readApplications(p: Period): Promise<AppRow[]> {
  const db = createServiceClient();
  const { since } = windowOf(p);
  return readAll<AppRow>((a, b) =>
    db.from("applications").select("post_id, created_at").gte("created_at", since).order("created_at").range(a, b),
  );
}

export async function readNewMembers(p: Period): Promise<UserRow[]> {
  const db = createServiceClient();
  const { since, until } = windowOf(p);
  return readAll<UserRow>((a, b) =>
    db.from("users").select("id, created_at, profession").gte("created_at", since).lt("created_at", until).order("created_at").range(a, b),
  );
}

export async function readActiveDays(p: Period): Promise<ActiveRow[]> {
  const db = createServiceClient();
  const day = (ms: number) => new Date(ms + 3 * 3600_000).toISOString().slice(0, 10);
  return readAll<ActiveRow>((a, b) =>
    db.from("member_active_days").select("member_id, day").gte("day", day(p.prevStart)).lte("day", day(p.end)).order("day").range(a, b),
  );
}

export async function readPlaces(): Promise<PlaceRow[]> {
  const db = createServiceClient();
  return readAll<PlaceRow>((a, b) =>
    db.from("locations").select("id, name, kind, parent_id, county, latitude, longitude, aliases, active").order("id").range(a, b),
  );
}

/** Categories of the given posts, in chunks (a URL can only carry so many ids). */
export async function readCategories(postIds: string[]): Promise<Map<string, string>> {
  const db = createServiceClient();
  const ids = [...new Set(postIds)].filter(Boolean);
  const out = new Map<string, string>();
  for (let i = 0; i < ids.length; i += 150) {
    const { data, error } = await db.from("posts").select("id, category").in("id", ids.slice(i, i + 150));
    if (error) throw new Error(error.message);
    for (const r of data ?? []) out.set(r.id as string, (r.category as string) || "Other");
  }
  return out;
}

/** Run the reads; on any failure, the error message instead of partial data. */
export async function settle<T>(work: () => Promise<T>): Promise<{ ok: true; data: T } | { ok: false; error: string }> {
  try {
    return { ok: true, data: await work() };
  } catch (e) {
    const error = e instanceof Error ? e.message : String(e);
    console.warn("[overview] read failed:", error);
    return { ok: false, error };
  }
}
