import "server-only";
import type { AccountStatus } from "./marketplace-people";
import type { ProviderRep } from "./reputation";
import { createServiceClient } from "./supabase-server";
import { attachPosts, type TxPost } from "./transaction-posts";

/**
 * Everything the dashboard knows about one member, for the member page:
 * who they are, how recently they used the app, what they posted, what they
 * were hired for, what they applied to, the money in and out, and disputes.
 *
 * Each section carries its own `failed` flag. A section that could not be
 * read says so on the page — it is never shown as "none", which would be a
 * statement about the person that the data does not support.
 */

export type Section<T> = { rows: T[]; total: number | null; failed: boolean };

export type MemberUser = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  phone: string | null;
  profile_image: string | null;
  photo_url: string | null;
  avatar_url: string | null;
  profession: string | null;
  bio: string | null;
  created_at: string;
  last_login: string | null;
  last_seen: string | null;
  is_online: boolean | null;
  role: string | null;
  is_verified: boolean | null;
  notifications_enabled: boolean | null;
};

export type MemberPost = {
  id: string;
  title: string | null;
  type: string | null;
  status: string | null;
  archived_at: string | null;
  created_at: string;
  price: number | null;
  selected_provider_id?: string | null;
};

export type MemberApplication = {
  id: string;
  post_id: string;
  created_at: string;
  proposed_price: number | null;
  posts: { title: string | null; type: string | null; status: string | null } | null;
};

export type MemberPayment = {
  id: string;
  post_id: string | null;
  amount: number | null;
  total_paid: number | null;
  status: string;
  created_at: string;
  posts: TxPost;
};

export type MemberEarning = {
  id: string;
  post_id: string | null;
  amount: number | null;
  status: string;
  created_at: string;
  released_at: string | null;
};

export type MemberDispute = {
  id: string;
  post_id: string | null;
  status: string;
  reason: string | null;
  created_at: string;
  raised_by_user_id: string | null;
};

export type MemberProfile = {
  user: MemberUser;
  accountStatus: AccountStatus | null;
  rep: ProviderRep | null;
  openReports: number | null;
  posted: Section<MemberPost>;
  hired: Section<MemberPost>;
  applications: Section<MemberApplication>;
  payments: Section<MemberPayment>;
  earnings: Section<MemberEarning>;
  disputes: Section<MemberDispute>;
  /** Phones the app can push to — a count, never the tokens (fcm_tokens rows, else the legacy column). */
  pushDevices: number;
};

const OPEN_REPORT = ["new", "under_review", "action_required"];
const LIMIT = 10;
const POST_COLUMNS = "id, title, type, status, archived_at, created_at, price";

type Res<T> = { data: T | null; error: { message: string } | null; count?: number | null };

function section<T>(res: Res<T[]>, what: string): Section<T> {
  if (res.error) {
    console.error(`[member] ${what} unavailable:`, res.error.message);
    return { rows: [], total: null, failed: true };
  }
  return { rows: res.data ?? [], total: res.count ?? res.data?.length ?? 0, failed: false };
}

/** null when there is no such member; throws only if the person row itself cannot be read. */
export async function loadMember(id: string): Promise<MemberProfile | null> {
  const db = createServiceClient();

  const [user, devices, state, rep, reports, posted, hired, applications, payments, earnings] = await Promise.all([
    db
      .from("users")
      .select(
        "id, name, email, phone_number, phone, profile_image, photo_url, avatar_url, profession, bio, created_at, last_login, last_seen, is_online, role, is_verified, notifications_enabled, fcm_tokens",
      )
      .eq("id", id)
      .maybeSingle(),
    // Where the backend's push sender looks first (migration 121); the legacy
    // users.fcm_tokens column is its fallback, and ours. Counted, never read.
    db.from("fcm_tokens").select("id", { count: "exact", head: true }).eq("user_id", id),
    db.from("moderation_account_state").select("account_status").eq("user_id", id).maybeSingle(),
    db
      .from("provider_reputation")
      .select("provider_id, completed_jobs, avg_rating, total_reviews, completion_rate, dispute_rate, open_disputes, tier")
      .eq("provider_id", id)
      .maybeSingle(),
    db.from("user_reports").select("id", { count: "exact", head: true }).eq("reported_user_id", id).in("status", OPEN_REPORT),
    db.from("posts").select(POST_COLUMNS, { count: "exact" }).eq("author_user_id", id).order("created_at", { ascending: false }).limit(LIMIT),
    db.from("posts").select(POST_COLUMNS, { count: "exact" }).eq("selected_provider_id", id).order("created_at", { ascending: false }).limit(LIMIT),
    db
      .from("applications")
      .select("id, post_id, created_at, proposed_price, posts(title, type, status)", { count: "exact" })
      .eq("applicant_user_id", id)
      .order("created_at", { ascending: false })
      .limit(LIMIT),
    db
      .from("transactions")
      .select("id, post_id, amount, total_paid, status, created_at", { count: "exact" })
      .eq("buyer_user_id", id)
      .order("created_at", { ascending: false })
      .limit(LIMIT),
    db
      .from("escrow")
      .select("id, post_id, amount, status, created_at, released_at", { count: "exact" })
      .eq("provider_id", id)
      .order("created_at", { ascending: false })
      .limit(LIMIT),
  ]);

  if (user.error) throw new Error(`member: ${user.error.message}`);
  if (!user.data) return null;
  // The push tokens are read only to be counted; they never leave this function.
  const { fcm_tokens: tokens, ...u } = user.data as MemberUser & { fcm_tokens: unknown };

  const postedSection = section(posted as Res<MemberPost[]>, "posts");
  const hiredSection = section(hired as Res<MemberPost[]>, "hired");

  // Disputes they raised, or on a listing they posted or were hired for.
  const relatedPosts = [...postedSection.rows, ...hiredSection.rows].map((p) => p.id);
  const disputeFilter = [`raised_by_user_id.eq."${id.replace(/"/g, "")}"`];
  if (relatedPosts.length) disputeFilter.push(`post_id.in.(${relatedPosts.map((p) => `"${p}"`).join(",")})`);
  const disputes = await db
    .from("disputes")
    .select("id, post_id, status, reason, created_at, raised_by_user_id", { count: "exact" })
    .or(disputeFilter.join(","))
    .order("created_at", { ascending: false })
    .limit(LIMIT);

  const paymentsSection = section(payments as Res<Omit<MemberPayment, "posts">[]>, "payments");
  const paymentRows = paymentsSection.failed ? [] : await attachPosts(db, paymentsSection.rows);

  return {
    user: u,
    accountStatus: state.error ? null : ((state.data?.account_status as AccountStatus | undefined) ?? "active"),
    rep: rep.error ? null : ((rep.data as ProviderRep | null) ?? null),
    openReports: reports.error ? null : (reports.count ?? 0),
    posted: postedSection,
    hired: hiredSection,
    applications: section(applications as unknown as Res<MemberApplication[]>, "applications"),
    payments: { ...paymentsSection, rows: paymentRows },
    earnings: section(earnings as Res<MemberEarning[]>, "earnings"),
    disputes: section(disputes as Res<MemberDispute[]>, "disputes"),
    pushDevices: (devices.error ? 0 : (devices.count ?? 0)) || (Array.isArray(tokens) ? tokens.length : 0),
  };
}
