import QRCode from "qrcode";
import CopyButton from "./CopyButton";
import {
  ACTIVE_DAYS_NEEDED,
  METHOD_LABELS,
  STATUS_LABELS,
  STATUS_STYLES,
  contributed,
  inGoodStanding,
  maskName,
  maskPhone,
  memberStatus,
  nextStep,
  type ProgressRow,
  type Summary,
} from "@/lib/partners/rules";
import type { MemberDetail } from "@/lib/partners/data";

/**
 * The partner views, rendered the same way on the partner portal and inside
 * the admin dashboard ("as the agent sees it"). Server components; the only
 * client piece is the copy button.
 */

export function agentLink(code: string, qr = false): string {
  return `https://help24.co.ke/a/${code}${qr ? "?src=qr" : ""}`;
}

export async function qrSvg(code: string): Promise<string> {
  return QRCode.toString(agentLink(code, true), { type: "svg", margin: 1, errorCorrectionLevel: "M" });
}

export async function CodeCard({ code, qrHref }: { code: string; qrHref?: string }) {
  const svg = await qrSvg(code);
  const link = agentLink(code);
  return (
    <section className="card p-5 grid gap-5 sm:grid-cols-[1fr_auto] items-center" aria-label="Your agent code">
      <div className="min-w-0">
        <p className="text-[12px] font-semibold text-gray-500">Agent code</p>
        <p className="font-mono text-3xl font-bold tracking-wider text-gray-900 mt-1" data-testid="partner-code">{code}</p>
        <p className="text-[13px] text-gray-500 mt-3">Share your link — it opens Help24 with your code filled in:</p>
        <p className="font-mono text-[13px] text-gray-800 mt-1 break-all">{link}</p>
        <div className="flex flex-wrap gap-2 mt-3">
          <CopyButton value={code} label="Copy code" />
          <CopyButton value={link} label="Copy link" />
          <a className="btn-ghost border border-gray-200" href={`https://wa.me/?text=${encodeURIComponent(`Join me on Help24 — find trusted local help or offer your services: ${link}`)}`} target="_blank" rel="noopener noreferrer">
            Share on WhatsApp
          </a>
        </div>
      </div>
      <div className="flex flex-col items-center gap-2">
        {/* Generated on the server from our own code; no user input reaches it. */}
        <div className="h-36 w-36 rounded-lg bg-white p-1.5" aria-label={`QR code for ${code}`} dangerouslySetInnerHTML={{ __html: svg }} />
        {qrHref && (
          <a className="text-[12px] font-semibold text-gray-600 hover:underline" href={qrHref}>
            Download QR code
          </a>
        )}
      </div>
    </section>
  );
}

export function SummaryTiles({ summary, failed }: { summary: Summary; failed: boolean }) {
  const tiles = [
    { label: "Members credited", value: summary.credited, hint: `${summary.thisWeek} in the last 7 days` },
    { label: "Qualified", value: summary.qualified, hint: "count toward payment" },
    { label: "In progress", value: summary.inProgress, hint: "still inside their 14 days" },
    { label: "Did not qualify", value: summary.notQualified, hint: "14 days passed" },
  ];
  return (
    <div className="grid gap-3 grid-cols-2 lg:grid-cols-4">
      {tiles.map((t) => (
        <div key={t.label} className="card px-4 py-3">
          <p className="text-[11.5px] font-medium text-gray-500">{t.label}</p>
          <p className="text-2xl font-semibold text-gray-900 font-tabular mt-0.5">{failed ? "—" : t.value}</p>
          <p className="text-[11px] text-gray-400 mt-0.5">{failed ? "Could not be read just now" : t.hint}</p>
        </div>
      ))}
    </div>
  );
}

export function WeeklyBars({ weeks }: { weeks: { week: string; count: number }[] }) {
  const max = Math.max(1, ...weeks.map((w) => w.count));
  return (
    <section className="card p-5" aria-label="Sign-ups by week">
      <h2 className="text-[14px] font-semibold text-gray-900">Members credited, by week</h2>
      <div className="mt-4 flex items-end gap-2 h-32">
        {weeks.map((w) => (
          <div key={w.week} className="flex-1 flex flex-col items-center justify-end h-full gap-1">
            <span className="text-[11px] text-gray-500 font-tabular">{w.count || ""}</span>
            <div className="w-full rounded-t bg-brand-600/80" style={{ height: `${(w.count / max) * 100}%`, minHeight: w.count ? 4 : 1 }} />
            {/* Week starting d/m — short enough for eight columns on a phone. */}
            <span className="text-[10.5px] text-gray-400 font-tabular whitespace-nowrap">
              {new Date(w.week).toLocaleDateString("en-KE", { day: "numeric", month: "numeric", timeZone: "UTC" })}
            </span>
          </div>
        ))}
      </div>
    </section>
  );
}

export function MethodSplit({ summary }: { summary: Summary }) {
  const total = Math.max(1, summary.credited);
  return (
    <section className="card p-5" aria-label="How members arrived">
      <h2 className="text-[14px] font-semibold text-gray-900">How members arrived</h2>
      <ul className="mt-3 space-y-2 text-[13px]">
        {(Object.keys(METHOD_LABELS) as ProgressRow["method"][]).map((m) => (
          <li key={m}>
            <div className="flex justify-between">
              <span className="text-gray-700">{METHOD_LABELS[m]}</span>
              <span className="font-tabular text-gray-900">{summary.byMethod[m]}</span>
            </div>
            <div className="mt-1 h-1.5 rounded bg-gray-100">
              <div className="h-1.5 rounded bg-brand-600/70" style={{ width: `${(summary.byMethod[m] / total) * 100}%` }} />
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function Check({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1 ${ok ? "text-positive-700" : "text-gray-400"}`}>
      <span aria-hidden>{ok ? "✓" : "○"}</span>
      {children}
    </span>
  );
}

/**
 * Members and their progress. `masked` is the partner's view (first name,
 * last 3 digits); admins see names and numbers whole and get a link to each
 * member's page.
 */
export function ProgressList({
  rows,
  details,
  masked,
  failed,
  now = Date.now(),
  memberHref,
}: {
  rows: ProgressRow[];
  details: Map<string, MemberDetail>;
  masked: boolean;
  failed: boolean;
  now?: number;
  memberHref?: (id: string) => string;
}) {
  if (failed) return <p className="card p-4 text-sm text-gray-500">Members could not be read just now — reload to try again.</p>;
  if (rows.length === 0) {
    return (
      <p className="card p-4 text-sm text-gray-500">
        No members yet. When someone enters this code — or joins through the link or QR code — they appear here.
      </p>
    );
  }
  return (
    <ul className="card divide-y divide-gray-100" data-testid="partner-members">
      {rows.map((r) => {
        const d = details.get(r.member_id);
        const status = memberStatus(r, now);
        const step = nextStep(r, now);
        const name = masked ? maskName(d?.name) : d?.name?.trim() || "Unnamed member";
        const phone = masked ? maskPhone(d?.phone) : d?.phone ?? "—";
        return (
          <li key={r.member_id} className="px-4 py-3 text-[13px]">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="min-w-0">
                {memberHref ? (
                  <a href={memberHref(r.member_id)} className="font-medium text-gray-900 hover:underline">{name}</a>
                ) : (
                  <span className="font-medium text-gray-900">{name}</span>
                )}
                <span className="ml-2 text-gray-400 font-tabular">{phone}</span>
              </div>
              <span className={`badge ${STATUS_STYLES[status]}`}>{STATUS_LABELS[status]}</span>
            </div>
            <p className="mt-1 text-[11.5px] text-gray-400">
              Joined {new Date(r.joined_at).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric", timeZone: "Africa/Nairobi" })} ·{" "}
              {METHOD_LABELS[r.method]}
            </p>
            <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-[12px]">
              <Check ok={r.active_days >= ACTIVE_DAYS_NEEDED}>
                Used Help24 on {r.active_days} {r.active_days === 1 ? "day" : "days"} (needs {ACTIVE_DAYS_NEEDED})
              </Check>
              <Check ok={contributed(r)}>Posted or sent an offer</Check>
              <Check ok={inGoodStanding(r)}>Account in good standing</Check>
            </div>
            {step && <p className="mt-1 text-[12px] text-caution-700">{step}</p>}
          </li>
        );
      })}
    </ul>
  );
}
