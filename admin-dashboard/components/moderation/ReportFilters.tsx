"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  CATEGORY_LABELS,
  REPORT_CATEGORIES,
  REPORT_STATUSES,
  SEVERITIES,
  SEVERITY_LABELS,
  STATUS_LABELS,
  TARGET_LABELS,
} from "@/lib/moderation-labels";

export type ReportFilterValues = {
  q?: string;
  status?: string;
  severity?: string;
  category?: string;
  target_type?: string;
  assigned?: string;
  from?: string;
  to?: string;
  sort?: string;
};

type Field = keyof ReportFilterValues;

/**
 * Filters live in the URL, so a filtered view can be linked, refreshed and
 * shared between admins. Selects apply as soon as they change; text and dates
 * apply on Enter or "Apply", so typing does not fire a request per keystroke.
 */
export default function ReportFilters({
  basePath,
  initial,
  fields = ["q", "status", "severity", "category", "target_type", "assigned", "from", "to", "sort"],
  fixed = {},
}: {
  basePath: string;
  initial: ReportFilterValues;
  fields?: Field[];
  /** Params every navigation keeps (e.g. the queue's scope). */
  fixed?: Record<string, string>;
}) {
  const router = useRouter();
  const [values, setValues] = useState<ReportFilterValues>(initial);
  const [pending, start] = useTransition();
  const show = (f: Field) => fields.includes(f);

  function go(next: ReportFilterValues) {
    const params = new URLSearchParams(fixed);
    for (const [k, v] of Object.entries(next)) {
      if (v && fields.includes(k as Field)) params.set(k, v);
    }
    const qs = params.toString();
    start(() => router.push(qs ? `${basePath}?${qs}` : basePath));
  }

  function set(field: Field, value: string, apply = false) {
    const next = { ...values, [field]: value || undefined };
    setValues(next);
    if (apply) go(next);
  }

  const active = fields.filter((f) => f !== "sort" && initial[f]).length;

  return (
    <form
      className="card p-3 sm:p-4 space-y-3"
      onSubmit={(e) => {
        e.preventDefault();
        go(values);
      }}
      aria-busy={pending}
    >
      <div className="flex flex-col sm:flex-row gap-2">
        {show("q") && (
          <input
            type="search"
            className="input flex-1"
            placeholder="Search a reference (e.g. 7F3A9C21), a name, an account id or words in a report"
            value={values.q ?? ""}
            onChange={(e) => set("q", e.target.value)}
            maxLength={100}
            aria-label="Search reports"
          />
        )}
        <div className="flex gap-2">
          <button type="submit" className="btn-primary flex-1 sm:flex-none" disabled={pending}>
            {pending ? "Loading…" : "Apply"}
          </button>
          {active > 0 && (
            <button
              type="button"
              className="btn-ghost border border-gray-200"
              onClick={() => {
                setValues({ sort: values.sort });
                go({ sort: values.sort });
              }}
            >
              Clear
            </button>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 xl:grid-cols-8 gap-2">
        {show("status") && (
          <Select label="Status" value={values.status} onChange={(v) => set("status", v, true)}>
            <option value="">All statuses</option>
            <option value="open">Open (awaiting decision)</option>
            {REPORT_STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_LABELS[s]}
              </option>
            ))}
            <option value="closed">Closed (resolved or dismissed)</option>
          </Select>
        )}
        {show("severity") && (
          <Select label="Severity" value={values.severity} onChange={(v) => set("severity", v, true)}>
            <option value="">All severities</option>
            {SEVERITIES.map((s) => (
              <option key={s} value={s}>
                {SEVERITY_LABELS[s]}
              </option>
            ))}
          </Select>
        )}
        {show("category") && (
          <Select label="Category" value={values.category} onChange={(v) => set("category", v, true)}>
            <option value="">All categories</option>
            {REPORT_CATEGORIES.map((c) => (
              <option key={c} value={c}>
                {CATEGORY_LABELS[c]}
              </option>
            ))}
          </Select>
        )}
        {show("target_type") && (
          <Select label="Reported" value={values.target_type} onChange={(v) => set("target_type", v, true)}>
            <option value="">Anything</option>
            {Object.entries(TARGET_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </Select>
        )}
        {show("assigned") && (
          <Select label="Assigned" value={values.assigned} onChange={(v) => set("assigned", v, true)}>
            <option value="">Anyone</option>
            <option value="me">Assigned to me</option>
            <option value="none">Unassigned</option>
          </Select>
        )}
        {show("from") && (
          <label className="block">
            <span className="text-[11px] font-semibold text-gray-500">Filed from</span>
            <input type="date" className="input mt-1" value={values.from ?? ""} onChange={(e) => set("from", e.target.value)} />
          </label>
        )}
        {show("to") && (
          <label className="block">
            <span className="text-[11px] font-semibold text-gray-500">Filed to</span>
            <input type="date" className="input mt-1" value={values.to ?? ""} onChange={(e) => set("to", e.target.value)} />
          </label>
        )}
        {show("sort") && (
          <Select label="Order" value={values.sort} onChange={(v) => set("sort", v, true)}>
            <option value="">Newest first</option>
            <option value="queue">Most serious, oldest first</option>
          </Select>
        )}
      </div>
    </form>
  );
}

function Select({
  label,
  value,
  onChange,
  children,
}: {
  label: string;
  value: string | undefined;
  onChange: (v: string) => void;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <span className="text-[11px] font-semibold text-gray-500">{label}</span>
      <select className="input mt-1" value={value ?? ""} onChange={(e) => onChange(e.target.value)}>
        {children}
      </select>
    </label>
  );
}
