import { createServiceClient } from "@/lib/supabase-server";

// Server-authoritative provider stats. The `provider_reputation` table is
// derived by fn_recompute_provider_reputation from canonical data (reviews,
// job_completions, disputes, posts) — the SAME source the mobile app displays.
//
// The users.average_rating / users.total_reviews / users.completed_jobs_count
// columns are DEAD: nothing has written them since client-side counters were
// removed, so any page reading them shows stale zeros. Do not use them.

export type ProviderRep = {
  provider_id: string;
  completed_jobs: number;
  avg_rating: number | null;
  total_reviews: number;
  completion_rate: number | null;
  dispute_rate: number | null;
  open_disputes: number;
  tier: string | null;
};

export async function fetchAllReputations(): Promise<ProviderRep[]> {
  const db = createServiceClient();
  const { data, error } = await db
    .from("provider_reputation")
    .select(
      "provider_id, completed_jobs, avg_rating, total_reviews, completion_rate, dispute_rate, open_disputes, tier",
    );
  if (error) console.error("[reputation] ERROR:", error.message);
  return (data ?? []) as ProviderRep[];
}

export function reputationByProvider(reps: ProviderRep[]): Map<string, ProviderRep> {
  return new Map(reps.map((r) => [r.provider_id, r]));
}

/** Rating cell text — only real ratings (≥1 visible review), never a dressed-up zero. */
export function ratingLabel(rep: ProviderRep | undefined): string | null {
  if (!rep || rep.total_reviews <= 0 || rep.avg_rating == null) return null;
  return `★ ${Number(rep.avg_rating).toFixed(1)}`;
}
