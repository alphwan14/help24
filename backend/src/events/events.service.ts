import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { EmitEventDto, EventType } from './event.types';

export interface SystemEventRow {
  id: string;
  type: EventType;
  entity_type: string;
  entity_id: string;
  actor_user_id: string | null;
  payload: Record<string, unknown>;
  processed: boolean;
  retry_count: number;
  last_error: string | null;
  dead_letter: boolean;
  created_at: string;
}

/** Summarize a payload for log lines — avoids multi-KB log spam. */
function summarizePayload(payload: Record<string, unknown>): string {
  const keys = ['post_id', 'transaction_id', 'dispute_id', 'completion_id', 'amount'];
  const parts = keys
    .filter((k) => payload[k] !== undefined)
    .map((k) => `${k}=${String(payload[k]).slice(0, 36)}`);
  return parts.length > 0 ? parts.join(' ') : '(no key fields)';
}

/**
 * Thin write layer for system_events.
 * Only knows about Supabase — no business-logic imports, no circular deps.
 *
 * Log tag format (grep-friendly for Render logs):
 *   [EVENTS][EMIT]  — about to write to DB
 *   [EVENTS][SAVE]  — successfully written to DB
 *   [EVENTS][ERROR] — DB write failed
 */
@Injectable()
export class EventsService {
  private readonly logger = new Logger(EventsService.name);

  constructor(private readonly supabase: SupabaseService) {}

  // ── Emit ──────────────────────────────────────────────────────────────────

  /**
   * Write an event row to system_events (processed=false).
   * Returns the new event's UUID, or null if the insert failed.
   * Never throws — failures are logged so the caller's flow is never broken.
   */
  async emit(dto: EmitEventDto): Promise<string | null> {
    const payload = dto.payload ?? {};
    const summary = summarizePayload(payload);

    this.logger.log(
      `[EVENTS][EMIT] type=${dto.type} entity=${dto.entityType}/${dto.entityId} ${summary}`,
    );

    const { data, error } = await this.supabase.client
      .from('system_events')
      .insert({
        type:          dto.type,
        actor_user_id: dto.actorUserId ?? null,
        entity_type:   dto.entityType,
        entity_id:     dto.entityId,
        payload,
        processed:     false,
        retry_count:   0,
        dead_letter:   false,
      })
      .select('id')
      .single();

    if (error) {
      this.logger.error(
        `[EVENTS][ERROR] Failed to save ${dto.type} entity=${dto.entityType}/${dto.entityId}: ${error.message}`,
      );
      return null;
    }

    const eventId = data.id as string;
    this.logger.log(
      `[EVENTS][SAVE] id=${eventId} type=${dto.type} processed=false`,
    );
    return eventId;
  }

  // ── State transitions ─────────────────────────────────────────────────────

  /** Mark an event as successfully processed. */
  async markProcessed(eventId: string): Promise<void> {
    const { error } = await this.supabase.client
      .from('system_events')
      .update({ processed: true })
      .eq('id', eventId);

    if (error) {
      this.logger.error(`[EVENTS][ERROR] markProcessed failed for ${eventId}: ${error.message}`);
    }
  }

  /**
   * Record a processing failure: increment retry_count and store error text.
   * If retry_count reaches maxRetries, mark as dead_letter.
   */
  async markFailed(eventId: string, errorMessage: string, maxRetries = 3): Promise<{ isDead: boolean }> {
    // Fetch current retry_count first.
    const { data: current } = await this.supabase.client
      .from('system_events')
      .select('retry_count')
      .eq('id', eventId)
      .single();

    const nextRetry = ((current?.retry_count as number) ?? 0) + 1;
    const isDead = nextRetry >= maxRetries;

    const { error } = await this.supabase.client
      .from('system_events')
      .update({
        retry_count: nextRetry,
        last_error:  errorMessage.slice(0, 1000), // cap length
        dead_letter: isDead,
      })
      .eq('id', eventId);

    if (error) {
      this.logger.error(`[EVENTS][ERROR] markFailed update failed for ${eventId}: ${error.message}`);
    }

    return { isDead };
  }

  // ── Queries ───────────────────────────────────────────────────────────────

  /**
   * Fetch unprocessed, non-dead-letter events (retry_count < 3) created within
   * the last 24 hours, oldest first. Used by the processor retry loop.
   */
  async fetchUnprocessed(): Promise<SystemEventRow[]> {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { data, error } = await this.supabase.client
      .from('system_events')
      .select('id, type, entity_type, entity_id, actor_user_id, payload, processed, retry_count, last_error, dead_letter, created_at')
      .eq('processed', false)
      .eq('dead_letter', false)
      .lt('retry_count', 3)
      .gte('created_at', since)
      .order('created_at', { ascending: true })
      .limit(100);

    if (error) {
      this.logger.error(`[EVENTS][ERROR] fetchUnprocessed: ${error.message}`);
      return [];
    }

    return (data ?? []) as SystemEventRow[];
  }

  /** Fetch a single event by ID (used by replay). */
  async fetchById(eventId: string): Promise<SystemEventRow | null> {
    const { data, error } = await this.supabase.client
      .from('system_events')
      .select('id, type, entity_type, entity_id, actor_user_id, payload, processed, retry_count, last_error, dead_letter, created_at')
      .eq('id', eventId)
      .single();

    if (error || !data) return null;
    return data as SystemEventRow;
  }

  /**
   * List events for the admin endpoint.
   * Supports filtering by processed/dead_letter and a limit.
   */
  async list(opts: {
    processed?: boolean;
    deadLetter?: boolean;
    limit?: number;
    since?: string;
  } = {}): Promise<SystemEventRow[]> {
    let query = this.supabase.client
      .from('system_events')
      .select('id, type, entity_type, entity_id, actor_user_id, payload, processed, retry_count, last_error, dead_letter, created_at')
      .order('created_at', { ascending: false })
      .limit(opts.limit ?? 100);

    if (opts.processed !== undefined) query = query.eq('processed', opts.processed);
    if (opts.deadLetter !== undefined) query = query.eq('dead_letter', opts.deadLetter);
    if (opts.since) query = query.gte('created_at', opts.since);

    const { data, error } = await query;
    if (error) {
      this.logger.error(`[EVENTS][ERROR] list: ${error.message}`);
      return [];
    }
    return (data ?? []) as SystemEventRow[];
  }

  /**
   * Queue size: unprocessed + non-dead-letter events within the 24h window.
   */
  async queueSize(): Promise<number> {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count, error } = await this.supabase.client
      .from('system_events')
      .select('*', { count: 'exact', head: true })
      .eq('processed', false)
      .eq('dead_letter', false)
      .gte('created_at', since);

    if (error) return -1;
    return count ?? 0;
  }

  /** Dead-letter count. */
  async deadLetterCount(): Promise<number> {
    const { count, error } = await this.supabase.client
      .from('system_events')
      .select('*', { count: 'exact', head: true })
      .eq('dead_letter', true);

    if (error) return -1;
    return count ?? 0;
  }

  /** Reset a dead-letter event so it will be retried (used by replay). */
  async resetForReplay(eventId: string): Promise<void> {
    const { error } = await this.supabase.client
      .from('system_events')
      .update({ dead_letter: false, retry_count: 0, last_error: null, processed: false })
      .eq('id', eventId);

    if (error) {
      this.logger.error(`[EVENTS][ERROR] resetForReplay failed for ${eventId}: ${error.message}`);
    }
  }
}
