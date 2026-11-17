import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import ReclassifyListing from "@/components/marketplace/ReclassifyListing";
import { LISTING_TYPE_WORDS, isListingType, reclassifyBlockedReason } from "@/lib/listing-type";
import { suggestPostType, type IntentSuggestion } from "@/lib/post-intent";

// Live listings whose own words say the other kind: "Edger here anyone in
// need of plumber", posted as a Request. Read fresh on every visit, so a
// listing an admin just changed has already left the list.
export const dynamic = "force-dynamic";

type PostRow = {
  id: string;
  title: string;
  description: string | null;
  category: string | null;
  location: string | null;
  type: string;
  status: string | null;
  archived_at: string | null;
  archived_by: string | null;
  selected_provider_id: string | null;
  created_at: string;
  users: { name: string | null; email: string | null } | null;
};

type Row = PostRow & { suggestion: IntentSuggestion; applications: number; blocked: string | null };

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getRows(): Promise<{ rows: Row[]; error: string | null }> {
  const db = createServiceClient();
  const { data, error } = await db
    .from("posts")
    .select("id, title, description, category, location, type, status, archived_at, archived_by, selected_provider_id, created_at, users(name, email)")
    .in("type", ["request", "offer"])
    .is("archived_at", null)
    .order("created_at", { ascending: false })
    .limit(1000);
  if (error) return { rows: [], error: error.message };

  // The same check the app's composer runs (lib/post-intent.ts). Filtered here
  // as well as in the query, so a listing taken down meanwhile never shows.
  const flagged = ((data ?? []) as unknown as PostRow[]).flatMap((p) => {
    if (p.archived_at || (p.type !== "request" && p.type !== "offer")) return [];
    const suggestion = suggestPostType({ chosen: p.type, title: p.title ?? "", description: p.description });
    return suggestion ? [{ ...p, suggestion }] : [];
  });
  if (flagged.length === 0) return { rows: [], error: null };

  const { data: apps } = await db
    .from("applications")
    .select("post_id")
    .in("post_id", flagged.map((p) => p.id));
  const counts = new Map<string, number>();
  for (const a of (apps ?? []) as { post_id: string }[]) counts.set(a.post_id, (counts.get(a.post_id) ?? 0) + 1);

  const rows = flagged.map((p) => ({ ...p, applications: counts.get(p.id) ?? 0, blocked: reclassifyBlockedReason(p) }));
  // The ones an admin can change first, the clearest (a phrase, not only a
  // hint) first among those, newest first within each.
  rows.sort(
    (a, b) =>
      Number(!!a.blocked) - Number(!!b.blocked) ||
      Number(!a.suggestion.strong) - Number(!b.suggestion.strong) ||
      b.created_at.localeCompare(a.created_at),
  );
  return { rows, error: null };
}

function kind(type: string) {
  return isListingType(type) ? LISTING_TYPE_WORDS[type] : null;
}

export default async function TypeCheckPage() {
  const { rows, error } = await getRows();
  const changeable = rows.filter((r) => !r.blocked).length;

  const columns = [
    {
      key: "title",
      label: "Listing",
      render: (r: Row) => (
        <div className="max-w-xs">
          <Link href={`/dashboard/marketplace/requests/${r.id}`} className="font-medium text-gray-900 truncate block hover:underline">
            {r.title}
          </Link>
          <p className="text-xs text-gray-400 truncate">{[r.category, r.location].filter(Boolean).join(" · ")}</p>
          <p className="text-xs text-gray-400 truncate">
            {[r.users?.name || r.users?.email, fmtDate(r.created_at)].filter(Boolean).join(" · ")}
          </p>
          {r.description && (
            <p className="text-xs text-gray-500 truncate" title={r.description}>
              {r.description}
            </p>
          )}
        </div>
      ),
    },
    {
      key: "posted_as",
      label: "Posted as",
      render: (r: Row) => {
        const k = kind(r.type);
        return (
          <div>
            <p className="text-gray-800">{k?.name ?? r.type}</p>
            {k && <p className="text-xs text-gray-400">Shows as {k.feed}</p>}
          </div>
        );
      },
    },
    {
      key: "reads_as",
      label: "Reads as",
      render: (r: Row) => {
        const k = kind(r.suggestion.type);
        return (
          <div data-testid="reads-as">
            <p className="font-medium text-gray-900">{k?.name ?? r.suggestion.type}</p>
            <p className="text-xs text-gray-500 max-w-[14rem] truncate" title={r.suggestion.evidence.join(", ")}>
              {r.suggestion.evidence.map((e) => `“${e}”`).join(", ")}
            </p>
            {!r.suggestion.strong && (
              <p className="text-xs text-caution-700">Weak: words both kinds use. Check the listing first.</p>
            )}
          </div>
        );
      },
    },
    {
      key: "action",
      label: "",
      render: (r: Row) => (
        // Keyed by listing: the table keys its rows by position, so without
        // this a changed listing's "Changed: ..." note would stay behind on
        // the row that moves up into its place.
        <div className="w-44 whitespace-normal">
          <ReclassifyListing
            key={r.id}
            postId={r.id}
            currentType={r.type}
            suggestedType={r.suggestion.type}
            applications={r.applications}
            blockedReason={r.blocked}
          />
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="space-y-1">
        <p className="text-sm text-gray-700">
          Live requests and offers whose own words read as the other kind, by the same phrase check the app runs before
          posting. A suggestion, not a verdict: open the listing when the words are unclear.
        </p>
        <p className="text-xs text-gray-400">
          {rows.length === 1 ? "1 listing" : `${rows.length} listings`}
          {rows.length > 0 && `, ${changeable} can be changed here`}. A changed listing leaves this list.
        </p>
      </div>
      {error ? (
        <p className="text-[13px] text-critical-700">Couldn&apos;t load the listings ({error}). Reload to try again.</p>
      ) : (
        <DataTable columns={columns} rows={rows} emptyMessage="No live listing reads as the other kind." />
      )}
    </div>
  );
}
