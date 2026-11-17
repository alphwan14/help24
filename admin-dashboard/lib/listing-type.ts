// Reclassifying a listing (migration 145, admin_reclassify_post).
//
// People pick the wrong kind: "Edger here anyone in need of plumber" went up
// as a Request. The app lets the author switch a request and an offer while
// nobody has responded; an admin can reclassify any OPEN listing, a job
// included, with a reason. The database checks everything again (the admin is
// active, the listing is open with nobody chosen, a care offer's author is
// vetted) and records who did it. This file is only the console's words.

export const LISTING_TYPES = ["request", "offer", "job"] as const;
export type ListingType = (typeof LISTING_TYPES)[number];

export const EMPLOYMENT_TYPES = [
  ["full_time", "Full-time"],
  ["part_time", "Part-time"],
  ["contract", "Contract"],
  ["temporary", "Temporary"],
] as const;
export type EmploymentType = (typeof EMPLOYMENT_TYPES)[number][0];

/** What each kind is, in the words the app's feed now uses. */
export const LISTING_TYPE_WORDS: Record<ListingType, { name: string; feed: string; means: string }> = {
  request: { name: "Request", feed: "Needs help", means: "Someone needs a task or a service done." },
  offer: { name: "Offer", feed: "Offering", means: "Someone advertising work they do." },
  job: { name: "Job", feed: "Hiring", means: "A position with regular pay." },
};

export function isListingType(v: unknown): v is ListingType {
  return typeof v === "string" && (LISTING_TYPES as readonly string[]).includes(v);
}

export function isEmploymentType(v: unknown): v is EmploymentType {
  return typeof v === "string" && EMPLOYMENT_TYPES.some(([k]) => k === v);
}

/**
 * Why this listing's type cannot change here, or null when it can. The same
 * rules the database applies, said before the admin fills in a reason.
 */
export function reclassifyBlockedReason(post: {
  status: string | null;
  selected_provider_id: string | null;
  archived_by: string | null;
}): string | null {
  if (post.archived_by === "moderation") return "Hidden by moderation, so its type stays.";
  if ((post.status ?? "open") !== "open" || post.selected_provider_id) return "It already has a provider, so its type stays.";
  return null;
}

/** The checks the console makes before asking the database. */
export function reclassifyInputError(input: {
  type: unknown;
  current: string;
  employmentType: unknown;
  reason: string;
}): string | null {
  if (!isListingType(input.type)) return "Choose request, offer or job.";
  if (input.type === input.current) return `It is already a ${input.type}.`;
  if (input.type === "job" && !isEmploymentType(input.employmentType)) return "A job needs an employment type.";
  const reason = input.reason.trim();
  if (reason.length < 5) return "Say why, in at least 5 characters.";
  if (reason.length > 500) return "Keep the reason under 500 characters.";
  return null;
}

/** The database's refusal, as the sentence after its marker. */
export function reclassifyRefusalWords(message: string | undefined): string {
  const m = /HELP24_(?:RECLASSIFY_[A-Z_]+|ADMIN_INVALID|MODERATION_FORBIDDEN):\s*(.+)$/.exec(message ?? "");
  if (!m) return "That could not be saved just now. Nothing was changed. Please try again.";
  const s = m[1].trim();
  return s.charAt(0).toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? "" : ".");
}

/** "Request to Offer", for the history and the confirmation. */
export function changeLabel(from: string, to: string): string {
  const name = (t: string) => (isListingType(t) ? LISTING_TYPE_WORDS[t].name : t);
  return `${name(from)} to ${name(to)}`;
}
