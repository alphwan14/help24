import type { EvidenceItem, LedgerEntry, ReportInvestigation } from "@/lib/moderation-api";
import { fmtDate, fmtDateTime, fmtKES, humanise } from "@/lib/moderation-labels";
import ContentActionButton from "./ContentActionButton";

type Json = Record<string, unknown>;
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v : null);

/**
 * The reported thing, AS IT WAS when the report was filed (the snapshot the
 * database took), and — when it has changed since — as it is now. An edit
 * after a report is itself worth knowing.
 */
export default function TargetView({
  target,
  reportId,
  reportedUserId,
  decisions,
}: {
  target: ReportInvestigation["target"];
  reportId: string;
  reportedUserId: string;
  decisions: LedgerEntry[];
}) {
  const snap = (target.snapshot ?? {}) as Json;
  const live = target.live as Json | null;

  return (
    <div className="space-y-3">
      {target.changed_since_report && (
        <p className="text-[12px] font-semibold text-caution-700 bg-caution-50 border border-caution-200 rounded-md px-2.5 py-1.5">
          Changed since the report — the version below is what the reporter saw.
        </p>
      )}
      {!live && <p className="text-[12px] text-gray-500">The original no longer exists. The snapshot below is the record.</p>}

      {target.type === "user" && (
        <dl className="space-y-2 text-[13px]">
          <Row label="Name">{str(snap.name) ?? "—"}</Row>
          <Row label="Profession">{str(snap.profession) ?? "—"}</Row>
          <Row label="Bio">{str(snap.bio) ? <span className="whitespace-pre-line">{String(snap.bio)}</span> : "—"}</Row>
          {live && target.changed_since_report && (
            <Row label="Now">
              {str(live.name) ?? "—"}
              {str(live.bio) && <span className="block text-gray-500 whitespace-pre-line mt-0.5">{String(live.bio)}</span>}
            </Row>
          )}
        </dl>
      )}

      {target.type === "post" && (
        <>
          <dl className="space-y-2 text-[13px]">
            <Row label={humanise(str(snap.type) ?? "listing")}>
              <span className="font-semibold text-gray-900">{str(snap.title) ?? "Untitled"}</span>
            </Row>
            <Row label="Description">{str(snap.description) ? <span className="whitespace-pre-line">{String(snap.description)}</span> : "—"}</Row>
            <Row label="Details">
              {[str(snap.category), str(snap.location), snap.price != null ? fmtKES(Number(snap.price)) : null, `posted ${fmtDate(str(snap.created_at))}`]
                .filter(Boolean)
                .join(" · ")}
            </Row>
            {live && (
              <Row label="Now">
                {postState(live)}
                {target.changed_since_report && str(live.title) !== str(snap.title) && (
                  <span className="block text-gray-500 mt-0.5">Title now: {str(live.title)}</span>
                )}
              </Row>
            )}
          </dl>
          {Array.isArray(live?.images) && (live!.images as string[]).length > 0 && (
            <div className="flex gap-2 flex-wrap">
              {(live!.images as string[]).slice(0, 6).map((src) => (
                <a key={src} href={src} target="_blank" rel="noopener noreferrer" className="block">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={src} alt="Listing photo" className="w-20 h-20 object-cover rounded-md border border-gray-100 bg-gray-50" />
                </a>
              ))}
            </div>
          )}
          {live && <PostAction live={live} reportId={reportId} ownerId={reportedUserId} />}
        </>
      )}

      {target.type === "application" && (
        <dl className="space-y-2 text-[13px]">
          <Row label="On listing">
            {str(snap.post_title) ?? "—"} <span className="text-gray-400">({humanise(str(snap.post_type) ?? "")})</span>
          </Row>
          <Row label="Their message">{str(snap.message) ? <span className="whitespace-pre-line">{String(snap.message)}</span> : "—"}</Row>
          <Row label="Proposed">{snap.proposed_price != null ? fmtKES(Number(snap.proposed_price)) : "—"}</Row>
          <Row label="Applied">{fmtDateTime(str(snap.applied_at))}</Row>
          {live && target.changed_since_report && <Row label="Now">{str(live.message) ?? "—"}</Row>}
        </dl>
      )}

      {target.type === "message" && (
        <>
          <blockquote className="rounded-lg bg-gray-50 border border-gray-100 px-3 py-2.5 text-[13.5px] text-gray-900 whitespace-pre-line break-words">
            {str(snap.content) ?? <span className="text-gray-400">(no text)</span>}
            {str(snap.attachment_url) && (
              <a href={String(snap.attachment_url)} target="_blank" rel="noopener noreferrer" className="block mt-1.5 text-[12px] text-info-700 hover:underline">
                Attachment ({humanise(str(snap.type) ?? "file")})
              </a>
            )}
          </blockquote>
          <p className="text-[12px] text-gray-500">Sent {fmtDateTime(str(snap.sent_at))}</p>
          {live && <MessageAction live={live} messageId={target.id} reportId={reportId} ownerId={reportedUserId} decisions={decisions} />}
        </>
      )}
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[96px_minmax(0,1fr)] gap-3">
      <dt className="text-[11.5px] font-semibold text-gray-400 pt-px">{label}</dt>
      <dd className="text-gray-800 break-words">{children}</dd>
    </div>
  );
}

function postState(live: Json): string {
  if (live.archived_by === "moderation") return "Hidden by moderation";
  if (live.archived_at) return "Removed by its owner";
  return `Live — ${humanise(str(live.status) ?? "")}`;
}

function PostAction({ live, reportId, ownerId }: { live: Json; reportId: string; ownerId: string }) {
  if (live.archived_by === "moderation") {
    return <ContentActionButton type="post" id={String(live.id)} action="restore" reportId={reportId} ownerUserId={ownerId} />;
  }
  if (live.archived_at) return null;
  if (live.status !== "open") {
    return (
      <p className="text-[12px] text-gray-500">
        This listing has a job {live.status === "completed" ? "on record" : "in progress"} ({humanise(String(live.status))}), so it
        can&apos;t be hidden without stranding that job. Use Disputes for the job, or act on the account.
      </p>
    );
  }
  return <ContentActionButton type="post" id={String(live.id)} action="remove" reportId={reportId} ownerUserId={ownerId} />;
}

function MessageAction({
  live,
  messageId,
  reportId,
  ownerId,
  decisions,
}: {
  live: Json;
  messageId: string;
  reportId: string;
  ownerId: string;
  decisions: LedgerEntry[];
}) {
  if (live.deleted_for_everyone) {
    // decisions are newest first: the latest content action on this message says who hid it.
    const last = decisions.find((d) => d.content_type === "message" && d.content_id === messageId);
    if (last?.action_type === "content_removed") {
      return (
        <div className="flex items-center gap-3">
          <span className="text-[12px] text-gray-500">Hidden by moderation — both people see it as removed.</span>
          <ContentActionButton type="message" id={messageId} action="restore" reportId={reportId} ownerUserId={ownerId} compact />
        </div>
      );
    }
    return <p className="text-[12px] text-gray-500">Deleted by its sender after the report. The text above is the preserved record.</p>;
  }
  return <ContentActionButton type="message" id={messageId} action="remove" reportId={reportId} ownerUserId={ownerId} />;
}

/** Attachments the reporter added. Signed links, valid for ten minutes. */
export function EvidenceGallery({ items }: { items: EvidenceItem[] }) {
  if (items.length === 0) return <p className="text-[12.5px] text-gray-400">No attachments.</p>;
  return (
    <div className="space-y-1.5">
      <div className="flex gap-2 flex-wrap">
        {items.map((e) =>
          e.signed_url ? (
            <a key={e.path} href={e.signed_url} target="_blank" rel="noopener noreferrer" className="block">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={e.signed_url} alt="Evidence attached by the reporter" className="w-28 h-28 object-cover rounded-md border border-gray-100 bg-gray-50" />
            </a>
          ) : (
            <span key={e.path} className="w-28 h-28 rounded-md border border-dashed border-gray-200 text-[11px] text-gray-400 flex items-center justify-center text-center px-2">
              Upload missing
            </span>
          ),
        )}
      </div>
      <p className="text-[11px] text-gray-400">Links expire after 10 minutes — reload the page for fresh ones.</p>
    </div>
  );
}
