import {
  ACCOUNT_STATUS_LABELS,
  ACCOUNT_STATUS_STYLES,
  ACTION_LABELS,
  ACTION_TONE,
  CATEGORY_LABELS,
  SEVERITY_DOT,
  SEVERITY_LABELS,
  SEVERITY_STYLES,
  STATUS_LABELS,
  STATUS_STYLES,
  TARGET_LABELS,
} from "@/lib/moderation-labels";

export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge ${STATUS_STYLES[status] ?? "bg-gray-100 text-gray-600"}`}>{STATUS_LABELS[status] ?? status}</span>;
}

export function SeverityBadge({ severity }: { severity: string }) {
  return (
    <span className={`badge gap-1.5 ${SEVERITY_STYLES[severity] ?? "bg-gray-100 text-gray-600"}`}>
      {severity !== "critical" && <span className={`w-1.5 h-1.5 rounded-full ${SEVERITY_DOT[severity] ?? "bg-gray-300"}`} />}
      {SEVERITY_LABELS[severity] ?? severity}
    </span>
  );
}

export function AccountStatusBadge({ status }: { status: string | undefined }) {
  const s = status ?? "active";
  return <span className={`badge ${ACCOUNT_STATUS_STYLES[s] ?? "bg-gray-100 text-gray-600"}`}>{ACCOUNT_STATUS_LABELS[s] ?? s}</span>;
}

export function CategoryLabel({ category }: { category: string }) {
  return <span className="text-[13px] font-medium text-gray-800">{CATEGORY_LABELS[category] ?? category}</span>;
}

export function TargetTag({ type }: { type: string }) {
  return (
    <span className="inline-flex items-center rounded-md border border-gray-200 px-1.5 py-px text-[10.5px] font-semibold uppercase tracking-wide text-gray-500">
      {TARGET_LABELS[type] ?? type}
    </span>
  );
}

export function ActionBadge({ type }: { type: string }) {
  return <span className={`badge ${ACTION_TONE[type] ?? "bg-gray-100 text-gray-600"}`}>{ACTION_LABELS[type] ?? type}</span>;
}

/**
 * Which kind of truth an item is. The investigation view never lets a report
 * (what someone said) read like platform data (what the system recorded) or
 * like a decision (what an admin did).
 */
export const LAYER = {
  allegation: { label: "Allegation", cls: "bg-caution-100 text-caution-700 border-caution-200", dot: "bg-caution-500" },
  platform: { label: "Platform record", cls: "bg-info-100 text-info-700 border-info-200", dot: "bg-info-500" },
  decision: { label: "Admin decision", cls: "bg-gray-900 text-on-action border-gray-900", dot: "bg-gray-900" },
} as const;

export function LayerTag({ layer }: { layer: keyof typeof LAYER }) {
  const l = LAYER[layer];
  return (
    <span className={`inline-flex items-center rounded-md border px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide ${l.cls}`}>
      {l.label}
    </span>
  );
}

export function Avatar({ name, src, size = 36 }: { name?: string | null; src?: string | null; size?: number }) {
  const initial = (name ?? "?").trim().charAt(0).toUpperCase() || "?";
  const style = { width: size, height: size };
  if (src) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={src} alt="" style={style} className="rounded-full object-cover bg-gray-100 shrink-0" />;
  }
  return (
    <span style={style} className="rounded-full bg-gray-100 text-gray-500 font-semibold flex items-center justify-center shrink-0 text-sm">
      {initial}
    </span>
  );
}
