import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { Avatar } from "@/components/moderation/Badges";
import { ErrorState } from "@/components/moderation/States";
import ReviewPanel from "@/components/verifications/ReviewPanel";
import { getCurrentAdmin } from "@/lib/api";
import { settle } from "@/lib/moderation-api";
import { age, fmtDate, fmtDateTime } from "@/lib/moderation-labels";
import {
  KIND_LABELS,
  STATUS_LABELS,
  getVerification,
  getVerificationMeta,
  type VerificationDetail,
} from "@/lib/verifications-api";

export const dynamic = "force-dynamic";

const BASE = "/dashboard/trust-safety/verifications";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type PageProps = { params: Promise<{ id: string }> };

export default async function VerificationPage({ params }: PageProps) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const detailRequest = settle(getVerification(id));
  const metaRequest = settle(getVerificationMeta());

  const admin = await getCurrentAdmin();
  if (!admin) redirect(BASE);

  const [detail, meta] = await Promise.all([detailRequest, metaRequest]);
  if (!detail.ok) {
    if (detail.status === 404 || detail.status === 400) notFound();
    return <ErrorState message={detail.error} />;
  }

  const v = detail.data;
  const name = v.person?.name?.trim() || "Unnamed member";
  const idPending = v.history.some((h) => h.kind === "id" && h.status === "pending");
  const approveBlockedReason =
    v.kind === "care" && !v.state?.id_verified
      ? idPending
        ? "Review this provider's ID first. It is waiting in the queue."
        : "This provider has no approved ID, so the Care check cannot be approved yet."
      : null;

  return (
    <div className="space-y-5">
      <div>
        <Link href={BASE} className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800">
          ← Verifications
        </Link>
        <div className="flex flex-wrap items-center gap-2 mt-2">
          <h2 className="text-[19px] font-bold text-gray-900 tracking-tight">
            {KIND_LABELS[v.kind]} · {v.document_label}
          </h2>
          <StatusPill status={v.status} />
        </div>
        <p className="text-[13px] text-gray-500 mt-1.5">
          Sent {fmtDateTime(v.submitted_at)} ({age(v.submitted_at)} ago)
          {v.reviewed_at && <> · decided {fmtDateTime(v.reviewed_at)}</>}
          {v.expires_at && <> · receipt accepted until {fmtDate(v.expires_at)}</>}
        </p>
      </div>

      <div className="grid gap-5 items-start lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="space-y-5 min-w-0">
          <section className="card p-4">
            <h3 className="text-[13px] font-semibold text-gray-900">Documents</h3>
            <p className="text-[12px] text-gray-500 mt-0.5">
              Links expire after 5 minutes. Reload to see them again. Documents are deleted 30 days after the decision.
            </p>
            {v.files_deleted_at ? (
              <p className="text-[13px] text-gray-600 mt-3">Deleted on {fmtDate(v.files_deleted_at)}.</p>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3 mt-3">
                {v.files.map((f, i) => (
                  <figure key={i} className="rounded-lg border border-gray-200 overflow-hidden bg-gray-50">
                    {f.url && !f.is_pdf ? (
                      <a href={f.url} target="_blank" rel="noreferrer noopener">
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img src={f.url} alt={f.role} className="w-full h-56 object-contain bg-gray-900/5" />
                      </a>
                    ) : f.url ? (
                      <a
                        href={f.url}
                        target="_blank"
                        rel="noreferrer noopener"
                        className="flex h-56 items-center justify-center text-[13px] font-semibold text-info-700 hover:underline"
                      >
                        Open PDF ↗
                      </a>
                    ) : (
                      <div className="flex h-56 items-center justify-center text-[12.5px] text-critical-700">{f.error}</div>
                    )}
                    <figcaption className="px-3 py-2 text-[12px] font-semibold text-gray-700">{f.role}</figcaption>
                  </figure>
                ))}
              </div>
            )}
          </section>

          {v.listings.length > 0 && (
            <section className="card p-4">
              <h3 className="text-[13px] font-semibold text-gray-900">Their listings that need a check</h3>
              <ul className="mt-2 divide-y divide-gray-100">
                {v.listings.map((l) => (
                  <li key={l.id} className="py-2 flex items-center gap-2 text-[13px]">
                    <Link href={`/dashboard/marketplace/requests/${l.id}`} className="font-medium text-gray-900 hover:underline truncate">
                      {l.title}
                    </Link>
                    <span className="text-gray-500">· {l.category}</span>
                    <ListingState listing={l} />
                  </li>
                ))}
              </ul>
            </section>
          )}

          {v.history.length > 0 && (
            <section className="card p-4">
              <h3 className="text-[13px] font-semibold text-gray-900">Earlier submissions</h3>
              <ul className="mt-2 divide-y divide-gray-100">
                {v.history.map((h) => (
                  <li key={h.id} className="py-2 text-[12.5px] text-gray-600">
                    <Link href={`${BASE}/${h.id}`} className="font-medium text-gray-900 hover:underline">
                      {KIND_LABELS[h.kind]} · {h.document_label}
                    </Link>
                    {" · "}{STATUS_LABELS[h.status].toLowerCase()} {h.reviewed_at ? fmtDate(h.reviewed_at) : `(sent ${fmtDate(h.submitted_at)})`}
                    {h.rejection_reason && <span className="text-gray-500"> · “{h.rejection_reason}”</span>}
                  </li>
                ))}
              </ul>
            </section>
          )}
        </div>

        <aside className="space-y-5">
          <PersonCard v={v} name={name} />
          {v.status === "pending" ? (
            <ReviewPanel
              id={v.id}
              kind={v.kind}
              documentType={v.document_type}
              approveBlockedReason={approveBlockedReason}
              reasons={meta.ok ? meta.data.rejection_reasons : []}
            />
          ) : (
            <div className="card p-4 text-[12.5px] text-gray-600">
              <p className="font-semibold text-gray-900">{STATUS_LABELS[v.status]}</p>
              {v.rejection_reason && <p className="mt-1">Reason sent: “{v.rejection_reason}”</p>}
              <p className="mt-1 text-gray-500">Decisions are final; a provider who was rejected can send new documents.</p>
            </div>
          )}
        </aside>
      </div>
    </div>
  );
}

function PersonCard({ v, name }: { v: VerificationDetail; name: string }) {
  const state = v.state;
  return (
    <div className="card p-4">
      <div className="flex items-center gap-3">
        <Avatar name={name} src={v.person?.avatar_url ?? v.person?.profile_image ?? null} size={44} />
        <div className="min-w-0">
          <Link
            href={`/dashboard/trust-safety/users/${encodeURIComponent(v.user_id)}`}
            className="text-[14px] font-semibold text-gray-900 hover:underline truncate block"
          >
            {name}
          </Link>
          <p className="text-[12.5px] text-gray-500 truncate">{v.person?.profession || "No profession set"}</p>
        </div>
      </div>
      <dl className="mt-3 space-y-1 text-[12.5px]">
        <Row k="Name on Help24" v={name} />
        {v.person?.phone_number && <Row k="Phone" v={v.person.phone_number} />}
        {v.person?.created_at && <Row k="Member since" v={fmtDate(v.person.created_at)} />}
        <Row k="ID check" v={state?.id_verified ? "Verified" : "Not verified"} />
        <Row
          k="Care check"
          v={
            state?.care_status === "checked"
              ? "Complete"
              : state?.care_status === "pending"
                ? `Certificate pending until ${fmtDate(state.care_expires_at)}`
                : "None"
          }
        />
      </dl>
      <p className="text-[11.5px] text-gray-500 mt-3">Check the name on the document matches the name on Help24.</p>
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-gray-500">{k}</dt>
      <dd className="text-gray-900 font-medium text-right">{v}</dd>
    </div>
  );
}

function StatusPill({ status }: { status: VerificationDetail["status"] }) {
  const cls =
    status === "pending"
      ? "border-caution-200 bg-caution-50 text-caution-800"
      : status === "approved"
        ? "border-positive-200 bg-positive-50 text-positive-700"
        : "border-critical-200 bg-critical-50 text-critical-700";
  return <span className={`text-[11.5px] font-semibold rounded-md border px-2 py-0.5 ${cls}`}>{STATUS_LABELS[status]}</span>;
}

function ListingState({ listing }: { listing: VerificationDetail["listings"][number] }) {
  if (listing.archived_by === "vetting") {
    return <span className="ml-auto text-[11.5px] font-semibold text-critical-700">Hidden until verified</span>;
  }
  if (listing.vetting_label === "certificate_pending") {
    return <span className="ml-auto text-[11.5px] font-semibold text-caution-800">Certificate pending</span>;
  }
  if (listing.vetting_label === "not_verified") {
    return (
      <span className="ml-auto text-[11.5px] font-semibold text-caution-800">
        Not yet verified{listing.vetting_hide_at ? ` · hidden ${fmtDate(listing.vetting_hide_at)}` : ""}
      </span>
    );
  }
  return <span className="ml-auto text-[11.5px] text-gray-500">Live</span>;
}
