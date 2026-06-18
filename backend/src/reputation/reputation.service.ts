import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';

/**
 * The single reputation authority on the backend side.
 *
 * - recompute(providerId): invokes the idempotent SQL function
 *   fn_recompute_provider_reputation, which DERIVES every metric from canonical
 *   data (reviews, job_completions, disputes, posts). Never increments counters.
 * - getReputation / listProviderReviews: read-only, backend-mediated (service
 *   role), so the mobile app never reads the RLS-protected tables directly.
 *
 * All recompute calls are non-fatal: a reputation failure must never break the
 * event that triggered it (e.g. a payout or dispute resolution).
 */
@Injectable()
export class ReputationService {
  private readonly logger = new Logger(ReputationService.name);

  constructor(private readonly supabase: SupabaseService) {}

  /** Recompute a provider's reputation from canonical data. Idempotent + non-fatal. */
  async recompute(providerId: string | null | undefined): Promise<void> {
    if (!providerId) return;
    const { error } = await this.supabase.client.rpc('fn_recompute_provider_reputation', {
      p_provider_id: providerId,
    });
    if (error) {
      this.logger.error(`[REPUTATION] recompute failed for ${providerId}: ${error.message}`);
      return;
    }
    this.logger.log(`[REPUTATION] recomputed provider=${providerId}`);
  }

  /** Public reputation summary for a provider profile. */
  async getReputation(providerId: string) {
    let rep = await this.fetchRow(providerId);

    // Lazy backfill: if a provider has no row yet (e.g. created before the
    // migration backfill), compute it once on first read.
    if (!rep) {
      await this.recompute(providerId);
      rep = await this.fetchRow(providerId);
    }

    const { data: user } = await this.supabase.client
      .from('users')
      .select('created_at')
      .eq('id', providerId)
      .maybeSingle();

    return {
      provider_id: providerId,
      average_rating: round1(rep?.avg_rating ?? 0),
      bayesian_rating: round1(rep?.bayesian_rating ?? 0),
      total_reviews: rep?.total_reviews ?? 0,
      completed_jobs: rep?.completed_jobs ?? 0,
      disputed_jobs: rep?.disputed_jobs ?? 0,
      open_disputes: rep?.open_disputes ?? 0,
      completion_rate: rep?.completion_rate ?? 0, // 0..1
      dispute_rate: rep?.dispute_rate ?? 0, // 0..1
      repeat_clients: rep?.repeat_clients ?? 0,
      tier: (rep?.tier as string) ?? 'new_provider',
      member_since: (user?.created_at as string | null) ?? null,
      last_active_at: (rep?.last_active_at as string | null) ?? null,
      recomputed_at: (rep?.recomputed_at as string | null) ?? null,
    };
  }

  /** Visible reviews for a provider, newest first, cursor-paginated by created_at. */
  async listProviderReviews(providerId: string, limit: number, cursor?: string) {
    let query = this.supabase.client
      .from('reviews')
      .select(
        'id, post_id, client_id, rating, comment, from_disputed_job, provider_reply, provider_reply_at, created_at, edited_at',
      )
      .eq('provider_id', providerId)
      .eq('status', 'visible')
      .order('created_at', { ascending: false })
      .limit(limit);

    if (cursor) query = query.lt('created_at', cursor);

    const { data, error } = await query;
    if (error) {
      this.logger.error(`[REPUTATION] listReviews failed for ${providerId}: ${error.message}`);
      return { reviews: [], next_cursor: null };
    }
    const reviews = data ?? [];
    const nextCursor =
      reviews.length === limit ? (reviews[reviews.length - 1].created_at as string) : null;
    return { reviews, next_cursor: nextCursor };
  }

  private async fetchRow(providerId: string) {
    const { data } = await this.supabase.client
      .from('provider_reputation')
      .select('*')
      .eq('provider_id', providerId)
      .maybeSingle();
    return data as Record<string, unknown> | null;
  }
}

function round1(n: unknown): number {
  return Math.round((Number(n) || 0) * 10) / 10;
}
