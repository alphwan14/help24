import Link from "next/link";
import { notFound } from "next/navigation";
import { createServiceClient } from "@/lib/supabase-server";
import { PostStatusBadge } from "@/components/PostStatusBadge";
import { CandidateRow, PersonCard, PhoneLink, StandingBadges, accountHref } from "@/components/marketplace/People";
import { CANNOT_TAKE_WORK, loadMatchingData, loadPeople, type Person } from "@/lib/marketplace-people";
import { candidatesFor, countByTier, type Candidate } from "@/lib/provider-matching";
import { requestBudgetLabel, schemasByName, smartAnswerLines, type Json } from "@/lib/post-display";
import { age, fmtDate, fmtKES, humanise } from "@/lib/moderation-labels";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type PostRow = {
  id: string;
  title: string;
  description: string | null;
  category: string | null;
  location: string | null;
  latitude: number | null;
  longitude: number | null;
  urgency: string | null;
  is_urgent: boolean | null;
  price: number | null;
  type: string;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  author_name: string | null;
  selected_provider_id: string | null;
  created_at: string;
  attributes: Json | null;
};

type ApplicationRow = {
  id: string;
  applicant_user_id: string | null;
  applicant_name: string | null;
  message: string | null;
  proposed_price: number | null;
  created_at: string;
};

type JobState = {
  payment: { status: string; total_paid: number | null; amount: number | null; failure_reason: string | null; created_at: string; escrow: { status: string } | Array<{ status: string }> | null } | null;
  completion: { status: string; created_at: string; reviewed_at: string | null } | null;
  dispute: { id: string; status: string; created_at: string } | null;
};

type PageProps = { params: Promise<{ id: string }> };

/**
 * One listing, for an admin who has to phone someone: the people on it with
 * their numbers and, while a request is unanswered, who on Help24 could take
 * it — or plainly that nobody offers that work yet.
 */
export default async function MarketplaceRequestPage({ params }: PageProps) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const db = createServiceClient();
  const [postRes, appsRes, schemaRes] = await Promise.all([
    db
      .from("posts")
      .select("id, title, description, category, location, latitude, longitude, urgency, is_urgent, price, type, status, archived_at, author_user_id, author_name, selected_provider_id, created_at, attributes")
      .eq("id", id)
      .maybeSingle(),
    db
      .from("applications")
      .select("id, applicant_user_id, applicant_name, message, proposed_price, created_at")
      .eq("post_id", id)
      .order("created_at", { ascending: false })
      .limit(200),
    db.from("categories").select("name, question_schema"),
  ]);
  if (postRes.error) throw new Error(`Could not load the listing: ${postRes.error.message}`);
  const post = postRes.data as PostRow | null;
  if (!post) notFound();
  // A failed read is said out loud, never shown as "nobody has applied".
  const appsError = appsRes.error?.message ?? null;
  const applications = (appsRes.data ?? []) as ApplicationRow[];
  const answers = smartAnswerLines(
    schemasByName(schemaRes.data ?? []).get(post.category?.toLowerCase() ?? "") ?? null,
    post.type,
    post.attributes,
  );

  const assigned = !!post.selected_provider_id;
  // Only an open, unanswered-by-choice request needs someone found for it.
  const needsProvider = post.type === "request" && !assigned && post.status === "open" && !post.archived_at;

  let candidates: Candidate[] = [];
  let hiddenUnavailable = 0;
  let matchError: string | null = null;
  if (needsProvider) {
    try {
      const data = await loadMatchingData();
      const all = candidatesFor(post, data.seeds, data.registry);
      candidates = all.filter((c) => !CANNOT_TAKE_WORK.has(data.status.get(c.userId) ?? "active"));
      hiddenUnavailable = all.length - candidates.length;
    } catch (e) {
      matchError = e instanceof Error ? e.message : String(e);
    }
  }

  let job: JobState | null = null;
  let jobError: string | null = null;
  if (assigned) {
    try {
      job = await loadJobState(post.id);
    } catch (e) {
      jobError = e instanceof Error ? e.message : String(e);
    }
  }

  let people = new Map<string, Person>();
  let peopleError: string | null = null;
  try {
    people = await loadPeople([
      post.author_user_id,
      post.selected_provider_id,
      ...applications.map((a) => a.applicant_user_id),
      ...candidates.map((c) => c.userId),
    ]);
  } catch (e) {
    peopleError = e instanceof Error ? e.message : String(e);
  }

  const applied = new Set(applications.map((a) => a.applicant_user_id).filter(Boolean));
  const urgent = post.urgency === "urgent" || post.is_urgent === true;
  const authorLabel = post.type === "request" ? "Client" : post.type === "offer" ? "Provider (their offer)" : "Posted by";

  return (
    <div className="space-y-5">
      <Link
        href={assigned ? "/dashboard/marketplace/active-jobs" : "/dashboard/marketplace/requests?status=open"}
        className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800"
      >
        ← {assigned ? "Active jobs" : "Requests"}
      </Link>

      {peopleError && (
        <p className="card p-3 text-[12.5px] text-critical-700 bg-critical-100">
          Contact details could not be loaded ({peopleError}). Numbers missing below are missing because of that — reload to try again.
        </p>
      )}

      <section className="card p-4 sm:p-5 space-y-3">
        <div className="flex flex-wrap items-center gap-1.5">
          {post.type !== "request" && <span className="badge bg-gray-100 text-gray-600">{humanise(post.type)}</span>}
          {urgent && <span className="badge bg-critical-100 text-critical-700">Urgent</span>}
          <PostStatusBadge status={post.status} archivedAt={post.archived_at} />
        </div>
        <h2 className="text-[17px] font-semibold text-gray-900">{post.title}</h2>
        <p className="text-[12.5px] text-gray-500">
          {[post.category, post.location].filter(Boolean).join(" · ") || "No category or location"}
          {" · "}posted {fmtDate(post.created_at)} ({age(post.created_at)} ago)
          {post.type === "request" && post.price != null ? ` · Budget ${requestBudgetLabel(post.price)}` : ""}
        </p>
        {post.description && <p className="text-[13px] text-gray-700 whitespace-pre-line line-clamp-6">{post.description}</p>}
        {answers.length > 0 && <p className="text-[12px] text-indigo-500">{answers.join(" · ")}</p>}
      </section>

      <div className="grid gap-5 items-start lg:grid-cols-[minmax(0,1fr)_320px]">
        <div className="space-y-5 min-w-0">
          {needsProvider && (
            <section className="card p-4 sm:p-5">
              <h3 className="text-[14px] font-semibold text-gray-900">Who could take this</h3>
              {matchError ? (
                <p className="mt-2 text-[13px] text-critical-700">
                  Couldn&apos;t check who could take this ({matchError}). That says nothing about whether anyone can — reload to try again.
                </p>
              ) : candidates.length === 0 ? (
                <SupplyGap category={post.category} location={post.location} />
              ) : (
                <>
                  <p className="mt-1 text-[12.5px] text-gray-500">{summary(candidates)} Call them — the dashboard can&apos;t message users.</p>
                  <ul className="mt-2 divide-y divide-gray-100">
                    {candidates.slice(0, 25).map((c) => (
                      <CandidateRow key={c.userId} candidate={c} person={people.get(c.userId)} applied={applied.has(c.userId)} />
                    ))}
                  </ul>
                  {candidates.length > 25 && <p className="mt-2 text-[11.5px] text-gray-400">Showing the best 25 of {candidates.length}.</p>}
                </>
              )}
              {!matchError && (
                <p className="mt-3 text-[11.5px] text-gray-400">
                  Matched on trade and category through the registry the app&apos;s feed uses; distances only where both have map
                  coordinates.
                  {hiddenUnavailable > 0 &&
                    ` ${hiddenUnavailable} suspended or banned account${hiddenUnavailable === 1 ? " is" : "s are"} left out.`}
                </p>
              )}
            </section>
          )}

          {job && <JobStateCard job={job} />}
          {jobError && (
            <section className="card p-4 sm:p-5">
              <h3 className="text-[14px] font-semibold text-gray-900 mb-2">Where the job stands</h3>
              <p className="text-[13px] text-critical-700">{jobError}. Reload to try again.</p>
            </section>
          )}

          <section className="card p-4 sm:p-5">
            <h3 className="text-[14px] font-semibold text-gray-900 mb-2">
              Applications{applications.length ? ` (${applications.length})` : ""}
            </h3>
            {appsError ? (
              <p className="text-[13px] text-critical-700">Couldn&apos;t load the applications ({appsError}). Reload to try again.</p>
            ) : applications.length === 0 ? (
              <p className="text-[13px] text-gray-400">Nobody has applied yet.</p>
            ) : (
              <ul className="divide-y divide-gray-100">
                {applications.map((a) => (
                  <ApplicationRowView
                    key={a.id}
                    a={a}
                    person={a.applicant_user_id ? people.get(a.applicant_user_id) : undefined}
                    chosen={!!a.applicant_user_id && a.applicant_user_id === post.selected_provider_id}
                  />
                ))}
              </ul>
            )}
          </section>
        </div>

        <aside className="space-y-5 min-w-0">
          <PersonCard
            label={authorLabel}
            userId={post.author_user_id}
            person={post.author_user_id ? people.get(post.author_user_id) : undefined}
            showRecord={post.type === "offer"}
          />
          {assigned && (
            <PersonCard
              label="Provider"
              userId={post.selected_provider_id}
              person={people.get(post.selected_provider_id!)}
              showRecord
            />
          )}
        </aside>
      </div>
    </div>
  );
}

async function loadJobState(postId: string): Promise<JobState> {
  const db = createServiceClient();
  const [tx, completion, dispute] = await Promise.all([
    db
      .from("transactions")
      .select("status, total_paid, amount, failure_reason, created_at, escrow(status)")
      .eq("post_id", postId)
      .order("created_at", { ascending: false })
      .limit(1),
    db.from("job_completions").select("status, created_at, reviewed_at").eq("post_id", postId).order("created_at", { ascending: false }).limit(1),
    db.from("disputes").select("id, status, created_at").eq("post_id", postId).order("created_at", { ascending: false }).limit(1),
  ]);
  for (const r of [tx, completion, dispute]) if (r.error) throw new Error(`Couldn't load where the job stands (${r.error.message})`);
  return {
    payment: (tx.data?.[0] as JobState["payment"]) ?? null,
    completion: (completion.data?.[0] as JobState["completion"]) ?? null,
    dispute: (dispute.data?.[0] as JobState["dispute"]) ?? null,
  };
}

function summary(candidates: Candidate[]): string {
  const n = countByTier(candidates);
  const parts = [
    n.same ? `${n.same} doing this work` : null,
    n.related ? `${n.related} in a related trade` : null,
    n.mentions ? `${n.mentions} whose trade is only mentioned` : null,
  ].filter(Boolean);
  return `${candidates.length} ${candidates.length === 1 ? "person" : "people"}: ${parts.join(", ")}.`;
}

function SupplyGap({ category, location }: { category: string | null; location: string | null }) {
  const cat = category?.trim();
  if (!cat || cat.toLowerCase() === "other") {
    return (
      <p className="mt-2 text-[13px] text-gray-700">
        Nobody&apos;s trade or open offer matches this request&apos;s words. It is filed under &ldquo;Other&rdquo;, so only its text can
        match.
      </p>
    );
  }
  return (
    <div className="mt-2 space-y-1">
      <p className="text-[13px] font-medium text-critical-700">Nobody on Help24 has a trade or an open offer that fits {cat}.</p>
      <p className="text-[12.5px] text-gray-600">
        This is a supply gap. The fix is recruiting a {cat} provider{location ? ` for ${location}` : ""}, which happens outside the
        dashboard. Meanwhile you can call the client and say so.
      </p>
    </div>
  );
}

function JobStateCard({ job }: { job: JobState }) {
  const escrow = Array.isArray(job.payment?.escrow) ? job.payment?.escrow[0] : job.payment?.escrow;
  return (
    <section className="card p-4 sm:p-5">
      <h3 className="text-[14px] font-semibold text-gray-900 mb-2">Where the job stands</h3>
      <dl className="grid grid-cols-[110px_minmax(0,1fr)] gap-x-3 gap-y-2 text-[13px]">
        <dt className="text-gray-400">Payment</dt>
        <dd className="text-gray-800">
          {job.payment ? (
            <>
              {humanise(job.payment.status)} · {fmtKES(job.payment.total_paid ?? job.payment.amount)} · {fmtDate(job.payment.created_at)}
              {escrow?.status && <span className="text-gray-500"> · escrow {humanise(escrow.status).toLowerCase()}</span>}
              {job.payment.failure_reason && (
                <span className="block text-[12px] text-caution-700">M-Pesa said: {job.payment.failure_reason}</span>
              )}
            </>
          ) : (
            "No payment yet"
          )}
        </dd>
        <dt className="text-gray-400">Work</dt>
        <dd className="text-gray-800">
          {!job.completion
            ? "The provider has not marked it done"
            : job.completion.status === "pending_approval"
              ? `Marked done ${age(job.completion.created_at)} ago — waiting for the client to approve`
              : job.completion.status === "approved"
                ? `Approved by the client ${fmtDate(job.completion.reviewed_at)}`
                : `${humanise(job.completion.status)} · ${fmtDate(job.completion.created_at)}`}
        </dd>
        {job.dispute && (
          <>
            <dt className="text-gray-400">Dispute</dt>
            <dd>
              <Link href={`/dashboard/disputes/${job.dispute.id}`} className="text-info-700 font-medium hover:underline">
                {humanise(job.dispute.status)} — open the case →
              </Link>
            </dd>
          </>
        )}
      </dl>
    </section>
  );
}

function ApplicationRowView({ a, person, chosen }: { a: ApplicationRow; person: Person | undefined; chosen: boolean }) {
  const name = person?.name || person?.email || a.applicant_name || "Unnamed applicant";
  return (
    <li className="py-3 flex flex-wrap items-start justify-between gap-x-4 gap-y-1.5">
      <div className="min-w-0 space-y-1">
        <div className="flex flex-wrap items-center gap-1.5">
          {a.applicant_user_id ? (
            <Link href={accountHref(a.applicant_user_id)} className="text-[13.5px] font-semibold text-gray-900 hover:underline">
              {name}
            </Link>
          ) : (
            <span className="text-[13.5px] font-semibold text-gray-900">{name}</span>
          )}
          {chosen && <span className="badge bg-positive-100 text-positive-700">Chosen</span>}
          {person && <StandingBadges person={person} />}
        </div>
        <p className="text-[12px] text-gray-500">
          Applied {fmtDate(a.created_at)}
          {a.proposed_price != null && a.proposed_price > 0 ? ` · proposed ${fmtKES(a.proposed_price)}` : ""}
        </p>
        {a.message && <p className="text-[12.5px] text-gray-600 whitespace-pre-line line-clamp-3">{a.message}</p>}
      </div>
      <PhoneLink phone={person?.phone} compact />
    </li>
  );
}
