import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ApiError, getCurrentAdmin, startEarly } from "@/lib/api";
import { getTransaction, type TransactionDetail, type TimelineEntry } from "@/lib/transactions";
import { loadPeople } from "@/lib/marketplace-people";
import { PersonCard } from "@/components/marketplace/People";
import { ErrorState } from "@/components/moderation/States";
import { age, fmtDate, fmtDateTime, fmtKES, humanise } from "@/lib/moderation-labels";
import PaymentActions from "./PaymentActions";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type PageProps = { params: Promise<{ id: string }> };

const STATE_STYLES: Record<string, string> = {
  awaiting_payment: "bg-caution-100 text-caution-700",
  in_escrow: "bg-info-100 text-info-700",
  payout_processing: "bg-info-100 text-info-700",
  settlement_failed: "bg-critical-100 text-critical-700",
  disputed: "bg-caution-100 text-caution-700",
  released: "bg-positive-100 text-positive-700",
  refunded: "bg-gray-100 text-gray-600",
  split_settled: "bg-caution-100 text-caution-700",
  inconsistent: "bg-critical-100 text-critical-700",
  no_payment: "bg-gray-100 text-gray-600",
};

const DOT: Record<TimelineEntry["tone"], string> = {
  neutral: "bg-gray-300",
  good: "bg-positive-500",
  attention: "bg-caution-500",
  bad: "bg-critical-500",
};

const COMPLETION_LABELS: Record<string, string> = {
  pending_approval: "Waiting for the client to approve",
  approved: "Approved",
  disputed: "Disputed by the client",
};

const DISPUTE_OPEN = (s: string) => !["resolved", "resolved_release", "resolved_refund", "resolved_partial", "merged"].includes(s);

/**
 * One payment, start to finish, for an admin who has to act on it: what state
 * the money is in, in words; the job and both people with their numbers;
 * everything that happened, in order; and the actions that fit it now.
 */
export default async function PaymentPage({ params }: PageProps) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const request = startEarly(getTransaction(id));
  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/payments");

  let detail: TransactionDetail;
  try {
    detail = await request;
  } catch (err) {
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) notFound();
    return (
      <div className="space-y-4">
        <BackLink />
        <ErrorState message={err instanceof ApiError ? err.message : "This payment could not be loaded."} />
      </div>
    );
  }

  const { transaction: tx, settlement, post, completion, escrow } = detail;
  const people = await loadPeople([post?.author_user_id, post?.selected_provider_id]).catch(() => new Map());
  const a = settlement.amounts;
  const openDispute = detail.disputes.find((d) => DISPUTE_OPEN(d.status)) ?? null;
  const earlier = detail.attempts.filter((x) => x.id !== tx.id);

  return (
    <div className="space-y-6 max-w-6xl">
      <BackLink />

      {/* What this is, and the state of the money in words */}
      <header className="space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <span className={`badge ${STATE_STYLES[settlement.state] ?? "bg-gray-100 text-gray-600"}`}>{settlement.label}</span>
          {post?.archived_at && <span className="badge bg-gray-100 text-gray-500">Listing archived</span>}
        </div>
        <h2 className="text-xl font-semibold text-gray-900">
          {post ? (
            <Link href={`/dashboard/marketplace/requests/${encodeURIComponent(post.id)}`} className="hover:underline">
              {post.title || "Untitled job"}
            </Link>
          ) : (
            "Job not found"
          )}
        </h2>
        <p className="text-[14px] text-gray-600 max-w-2xl">{settlement.explanation}</p>
        {tx.failure_reason && tx.status !== "released" && (
          <p className="text-[13px] text-critical-700">Last problem: {tx.failure_reason}</p>
        )}
        <p className="text-[12.5px] text-gray-400 flex flex-wrap gap-x-3 gap-y-1">
          <span>{fmtDateTime(tx.created_at)}</span>
          {tx.receipt_number && <span className="font-mono text-brand-600">{tx.receipt_number}</span>}
          {tx.mpesa_receipt && <span>M-Pesa {tx.mpesa_receipt}</span>}
          <span className="font-mono">{tx.id}</span>
        </p>
      </header>

      <PaymentActions transactionId={tx.id} actions={detail.actions} hasProvider={!!post?.selected_provider_id} />

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_340px]">
        {/* Everything that happened */}
        <section className="card p-5">
          <h3 className="text-[13px] font-semibold text-gray-900 mb-4">What happened</h3>
          {detail.timeline.length === 0 ? (
            <p className="text-[13px] text-gray-400">Nothing recorded yet.</p>
          ) : (
            <ol className="relative border-l border-gray-200 ml-1 space-y-4">
              {detail.timeline.map((e, i) => (
                <li key={`${e.at}-${i}`} className="pl-4 relative">
                  <span className={`absolute -left-[5px] top-1.5 w-[9px] h-[9px] rounded-full ring-2 ring-surface ${DOT[e.tone]}`} />
                  <time dateTime={e.at} className="text-[11.5px] text-gray-400 tabular-nums">{fmtDateTime(e.at)}</time>
                  <p className="text-[13.5px] text-gray-800 mt-0.5">{e.title}</p>
                  {e.detail && <p className="text-[12.5px] text-gray-500 mt-0.5 whitespace-pre-line break-words">{e.detail}</p>}
                  {e.by && <p className="text-[11.5px] text-gray-400 mt-0.5">By {e.by}</p>}
                </li>
              ))}
            </ol>
          )}
        </section>

        <div className="space-y-4">
          {/* The money */}
          <section className="card p-4 space-y-2">
            <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">Money</p>
            <dl className="space-y-1.5 text-[13px]">
              <Row label="Client paid" value={fmtKES(a.total_paid ?? tx.total_paid)} strong />
              <Row label="Help24 fee" value={fmtKES(a.fee ?? tx.fee)} />
              <Row label="For the provider" value={fmtKES(a.amount ?? tx.amount)} />
              {a.advance_paid ? <Row label="Materials Advance paid" value={fmtKES(a.advance_paid)} /> : null}
              {a.held != null && <Row label="Help24 holds now" value={fmtKES(a.held)} strong />}
              {a.provider_amount != null && <Row label="Ruling: to the provider" value={fmtKES(a.provider_amount)} />}
              {a.client_refund != null && <Row label="Ruling: back to the client" value={fmtKES(a.client_refund)} />}
              {a.provider_owed ? <Row label="Still owed to the provider" value={fmtKES(a.provider_owed)} strong /> : null}
            </dl>
            {tx.phone && <p className="text-[11.5px] text-gray-400">Paid from {tx.phone}</p>}
          </section>

          <PersonCard label="Client" userId={post?.author_user_id ?? null} person={post?.author_user_id ? people.get(post.author_user_id) : undefined} />
          <PersonCard label="Provider" userId={post?.selected_provider_id ?? null} person={post?.selected_provider_id ? people.get(post.selected_provider_id) : undefined} showRecord />

          {/* The job */}
          <section className="card p-4 space-y-2">
            <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">Job</p>
            <dl className="space-y-1.5 text-[13px]">
              <Row label="Listing" value={post?.status ? humanise(post.status) : "Unknown"} />
              {post?.category && <Row label="Category" value={humanise(post.category)} />}
              {post?.location && <Row label="Where" value={post.location} />}
              {post?.created_at && <Row label="Posted" value={fmtDate(post.created_at)} />}
              <Row label="Held by Help24" value={escrow ? humanise(escrow.status) : "Nothing held"} />
              <Row label="Work" value={completion ? COMPLETION_LABELS[completion.status] ?? humanise(completion.status) : "Not marked done yet"} />
            </dl>
            {completion?.status === "pending_approval" && completion.auto_approve_at && (
              <p className="text-[12px] text-gray-500">
                Approves itself {fmtDateTime(completion.auto_approve_at)} if the client does nothing
                {Date.parse(completion.auto_approve_at) > Date.now() ? ` (in ${age(new Date().toISOString(), Date.parse(completion.auto_approve_at))})` : ""}.
              </p>
            )}
            {openDispute && (
              <Link href={`/dashboard/disputes/${encodeURIComponent(openDispute.id)}`} className="inline-block text-[13px] font-semibold text-info-700 hover:underline">
                Open the dispute ({humanise(openDispute.status)})
              </Link>
            )}
            {!openDispute && detail.disputes.length > 0 && (
              <Link href={`/dashboard/disputes/${encodeURIComponent(detail.disputes.at(-1)!.id)}`} className="inline-block text-[13px] text-info-700 hover:underline">
                See the closed dispute
              </Link>
            )}
          </section>

          {earlier.length > 0 && (
            <section className="card p-4 space-y-2">
              <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">Other payments on this job</p>
              <ul className="space-y-1.5">
                {earlier.map((x) => (
                  <li key={x.id} className="text-[13px] flex items-baseline justify-between gap-3">
                    <Link href={`/dashboard/payments/${x.id}`} className="text-gray-700 hover:underline">
                      {humanise(x.status)} {x.total_paid != null ? fmtKES(x.total_paid) : ""}
                    </Link>
                    <span className="text-[11.5px] text-gray-400 tabular-nums">{fmtDate(x.created_at)}</span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </div>
      </div>
    </div>
  );
}

function BackLink() {
  return (
    <Link href="/dashboard/payments" className="text-[13px] text-gray-500 hover:text-gray-800">
      ← All payments
    </Link>
  );
}

function Row({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-gray-500">{label}</dt>
      <dd className={`text-right tabular-nums ${strong ? "font-semibold text-gray-900" : "text-gray-700"}`}>{value}</dd>
    </div>
  );
}
