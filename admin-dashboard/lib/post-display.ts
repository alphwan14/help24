// Smart Posting read-side parity (mirrors mobile lib/models/attribute_display.dart).
// Pure helpers: intent-aware money labels + schema-resolved smart answers.

export type Json = Record<string, unknown>;

const RATE_SUFFIX: Record<string, string> = {
  task: "",
  hour: "/hr",
  day: "/day",
  week: "/wk",
  month: "/mo",
};

export function fmtKes(n: number): string {
  return `KES ${Number(n ?? 0).toLocaleString("en-KE")}`;
}

/** Request money: price 0 is a statement, not a missing value. */
export function requestBudgetLabel(price: number): string {
  return !price || price <= 0 ? "Open to offers" : fmtKes(price);
}

/** Offer money: sellers price "from". */
export function offerRateLabel(price: number, pricingType: string): string {
  if (!price || price <= 0) return "—";
  return `From ${fmtKes(price)}${RATE_SUFFIX[pricingType] ?? ""}`;
}

/** Job money: salary with its period. */
export function jobSalaryLabel(price: number, pricingType: string): string {
  if (!price || price <= 0) return "Negotiable";
  return `${fmtKes(price)}${RATE_SUFFIX[pricingType] ?? ""}`;
}

// ── Reserved attribute keys written by the app's guided flows ────────────────
const WHEN_LABELS: Record<string, string> = {
  right_now: "Right now",
  today: "Today",
  this_week: "This week",
  flexible: "Flexible",
};
const AVAILABILITY_LABELS: Record<string, string> = {
  available_now: "Available now",
  this_week: "This week",
  by_appointment: "By appointment",
};
const START_LABELS: Record<string, string> = {
  immediately: "Immediately",
  within_month: "Within a month",
  flexible: "Flexible",
};

/** Map category name (lowercased) → question_schema. Missing table → empty map. */
export function schemasByName(rows: Array<{ name?: string | null; question_schema?: unknown }> | null): Map<string, Json> {
  const map = new Map<string, Json>();
  for (const row of rows ?? []) {
    if (row?.name && row.question_schema && typeof row.question_schema === "object") {
      map.set(String(row.name).toLowerCase(), row.question_schema as Json);
    }
  }
  return map;
}

function humanize(s: string): string {
  const t = s.replace(/^_+/, "").replace(/_/g, " ").trim();
  return t.charAt(0).toUpperCase() + t.slice(1);
}

/**
 * "Label: Value" lines for a post's smart answers — reserved time signals
 * first, then schema questions resolved to their option labels (same rules as
 * the mobile app). Unresolvable keys fall back to humanized raw values so
 * admins always see the stored data.
 */
export function smartAnswerLines(
  schema: Json | null | undefined,
  postType: string,
  attributes: Json | null | undefined,
): string[] {
  if (!attributes || typeof attributes !== "object") return [];
  const attrs = attributes as Record<string, unknown>;
  const lines: string[] = [];
  const consumed = new Set<string>();

  const when = WHEN_LABELS[String(attrs["_when"] ?? "")];
  if (when) { lines.push(`Needed: ${when}`); consumed.add("_when"); }
  const availability = AVAILABILITY_LABELS[String(attrs["_availability"] ?? "")];
  if (availability) { lines.push(`Availability: ${availability}`); consumed.add("_availability"); }
  const start = START_LABELS[String(attrs["_start"] ?? "")];
  if (start) { lines.push(`Start: ${start}`); consumed.add("_start"); }

  const steps = Array.isArray((schema as Json | undefined)?.steps)
    ? ((schema as Json).steps as Json[])
    : [];
  for (const step of steps) {
    const key = String(step.key ?? "");
    if (!key || !(key in attrs)) continue;
    const appliesTo = Array.isArray(step.applies_to) ? (step.applies_to as string[]) : null;
    if (appliesTo && !appliesTo.includes(postType)) continue;
    const answer = attrs[key];
    if (answer === null || answer === undefined) continue;

    const question = String(step.question ?? humanize(key)).replace(/\?$/, "");
    const options = Array.isArray(step.options) ? (step.options as Json[]) : [];
    const labelFor = (v: unknown) =>
      String(options.find((o) => String(o.value) === String(v))?.label ?? humanize(String(v)));

    let value: string | null = null;
    if (typeof answer === "boolean") value = answer ? "Yes" : "No";
    else if (Array.isArray(answer)) value = answer.length ? answer.map(labelFor).join(", ") : null;
    else value = labelFor(answer);

    if (value) {
      lines.push(`${question}: ${value}`);
      consumed.add(key);
    }
  }

  // Anything left (schema missing/older app versions): show honestly, humanized.
  for (const [key, answer] of Object.entries(attrs)) {
    if (consumed.has(key) || key.startsWith("_")) continue;
    if (answer === null || answer === undefined) continue;
    const value = Array.isArray(answer)
      ? answer.map((v) => humanize(String(v))).join(", ")
      : typeof answer === "boolean"
        ? (answer ? "Yes" : "No")
        : humanize(String(answer));
    if (value) lines.push(`${humanize(key)}: ${value}`);
  }
  return lines;
}
