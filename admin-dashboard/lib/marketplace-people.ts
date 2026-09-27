import "server-only";
import { createServiceClient } from "@/lib/supabase-server";
import { buildRegistry, type OfferLike, type ProviderSeed, type Registry } from "@/lib/provider-matching";
import type { ProviderRep } from "@/lib/reputation";

// Every read here THROWS on failure. A page that cannot check who could take a
// request must say so — an empty list would read as "nobody offers this".

export type AccountStatus = "active" | "restricted" | "suspended" | "banned";

/** Suspended and banned accounts cannot take work, so they are never suggested. */
export const CANNOT_TAKE_WORK: ReadonlySet<AccountStatus> = new Set(["suspended", "banned"]);

const OPEN_REPORT = ["new", "under_review", "action_required"];

export interface MatchingData {
  registry: Registry;
  seeds: ProviderSeed[];
  /** Account status of every seed that is not active. */
  status: Map<string, AccountStatus>;
}

function must<T>(res: { data: T | null; error: { message: string } | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`);
  return (res.data ?? ([] as unknown)) as T;
}

/** The registry, every open offer and every profile trade — enough to match any request in memory. */
export async function loadMatchingData(): Promise<MatchingData> {
  const db = createServiceClient();
  const [professions, categories, offers, profiled, skills] = await Promise.all([
    db.from("professions").select("id, name, group_id, category_id, aliases").limit(5000),
    db.from("categories").select("id, name").limit(500),
    db
      .from("posts")
      .select("id, title, category, location, latitude, longitude, author_user_id, created_at")
      .eq("type", "offer")
      .eq("status", "open")
      .is("archived_at", null)
      .order("created_at", { ascending: false })
      .limit(2000),
    db.from("users").select("id, profession").not("profession", "is", null).neq("profession", "").limit(5000),
    db.from("user_skills").select("user_id, profession_id").limit(5000),
  ]);

  const registry = buildRegistry(must(professions, "professions"), must(categories, "categories"));

  const seeds = new Map<string, ProviderSeed>();
  const seed = (userId: string) => {
    let s = seeds.get(userId);
    if (!s) seeds.set(userId, (s = { userId, professionIds: [], offers: [] }));
    return s;
  };
  for (const o of must<OfferLike[]>(offers, "offers")) if (o.author_user_id) seed(o.author_user_id).offers.push(o);
  for (const u of must<Array<{ id: string; profession: string }>>(profiled, "professions on profiles")) {
    seed(u.id).professionIds.push(u.profession);
  }
  for (const k of must<Array<{ user_id: string; profession_id: string }>>(skills, "skills")) {
    const s = seed(k.user_id);
    if (!s.professionIds.includes(k.profession_id)) s.professionIds.push(k.profession_id);
  }

  const ids = [...seeds.keys()];
  const status = new Map<string, AccountStatus>();
  if (ids.length) {
    const states = await db.from("moderation_account_state").select("user_id, account_status").in("user_id", ids);
    for (const r of must<Array<{ user_id: string; account_status: AccountStatus }>>(states, "account states")) {
      if (r.account_status !== "active") status.set(r.user_id, r.account_status);
    }
  }
  return { registry, seeds: [...seeds.values()], status };
}

export interface Person {
  id: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  /** The later of last sign-in and last seen. */
  lastActive: string | null;
  accountStatus: AccountStatus;
  openReports: number;
  rep: ProviderRep | null;
}

/** Contact details, standing and track record for the people on a page. */
export async function loadPeople(userIds: Array<string | null | undefined>): Promise<Map<string, Person>> {
  const ids = [...new Set(userIds.filter((x): x is string => !!x))];
  if (ids.length === 0) return new Map();
  const db = createServiceClient();
  const [users, states, reports, reps] = await Promise.all([
    db.from("users").select("id, name, email, phone_number, phone, last_login, last_seen").in("id", ids),
    db.from("moderation_account_state").select("user_id, account_status").in("user_id", ids),
    db.from("user_reports").select("reported_user_id").in("reported_user_id", ids).in("status", OPEN_REPORT).limit(5000),
    db
      .from("provider_reputation")
      .select("provider_id, completed_jobs, avg_rating, total_reviews, completion_rate, dispute_rate, open_disputes, tier")
      .in("provider_id", ids),
  ]);

  const statusOf = new Map(
    must<Array<{ user_id: string; account_status: AccountStatus }>>(states, "account states").map((r) => [r.user_id, r.account_status]),
  );
  const reportsOf = new Map<string, number>();
  for (const r of must<Array<{ reported_user_id: string }>>(reports, "reports")) {
    reportsOf.set(r.reported_user_id, (reportsOf.get(r.reported_user_id) ?? 0) + 1);
  }
  const repOf = new Map(must<ProviderRep[]>(reps, "reputation").map((r) => [r.provider_id, r]));

  type UserRow = { id: string; name: string | null; email: string | null; phone_number: string | null; phone: string | null; last_login: string | null; last_seen: string | null };
  const people = new Map<string, Person>();
  for (const u of must<UserRow[]>(users, "users")) {
    const seen = [u.last_login, u.last_seen].filter((x): x is string => !!x).sort();
    people.set(u.id, {
      id: u.id,
      name: u.name?.trim() || null,
      email: u.email,
      phone: u.phone_number?.trim() || u.phone?.trim() || null,
      lastActive: seen.length ? seen[seen.length - 1] : null,
      accountStatus: statusOf.get(u.id) ?? "active",
      openReports: reportsOf.get(u.id) ?? 0,
      rep: repOf.get(u.id) ?? null,
    });
  }
  return people;
}
