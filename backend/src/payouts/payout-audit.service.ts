import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { RequestContextStore } from '../common/request-context/request-context';
import type { PayoutChannel } from './payout-destination.resolver';

/** Every payout-related transition worth reconstructing years from now. */
export type PayoutAuditEventType =
  // destination lifecycle
  | 'destination_created'
  | 'otp_requested'
  | 'otp_verified'
  | 'otp_failed'
  | 'default_changed'
  | 'destination_retired'
  // money lifecycle
  | 'payout_snapshot_captured'
  | 'payout_initiated'
  | 'payout_sent_to_processor'
  | 'payout_completed'
  | 'payout_failed'
  | 'payout_reversed'
  // exceptional
  | 'payout_refused'
  | 'manual_admin_override';

/** The class of authority behind an event. */
export type PayoutActorType = 'provider' | 'admin' | 'support' | 'system' | 'processor';

export interface PayoutAuditEvent {
  readonly eventId?: string;
  readonly providerUserId: string;
  readonly eventType: PayoutAuditEventType;
  readonly actorType: PayoutActorType;
  readonly actorId?: string | null;
  readonly payoutDestinationId?: string | null;
  readonly escrowId?: string | null;
  readonly transactionId?: string | null;
  readonly verificationId?: string | null;
  readonly destinationFingerprint?: string | null;
  readonly normalizedDestination?: string | null;
  readonly channel?: PayoutChannel | null;
  /** When it happened in the world. Defaults to now — pass it for callbacks. */
  readonly occurredAt?: Date;
  readonly reason?: string | null;
  readonly metadata?: Record<string, unknown>;
}

/**
 * The forensic trail. One append-only event per payout state transition.
 *
 * WHY EMISSION FAILURE IS HANDLED TWO DIFFERENT WAYS
 * --------------------------------------------------
 * There is a real tension between "never bypass emission" and "never let an
 * audit problem become a money outage", and resolving it the same way in both
 * directions gets one of them badly wrong. So the rule depends on whether money
 * has already moved:
 *
 *   BEFORE money moves  — `emitOrThrow`. Capturing a snapshot or initiating a
 *                         payout that cannot be recorded must not proceed.
 *                         Nothing is lost by refusing: no money has left, and
 *                         an unauditable payout is exactly what this system
 *                         exists to prevent.
 *
 *   AFTER money moves   — `emit`. The funds are gone. Refusing to record that
 *                         does not un-send them; it only destroys the evidence
 *                         that they went. Failure is logged at error level with
 *                         everything needed to reconstruct the event by hand.
 *
 * The database owns `chain_seq`, `prev_event_hash` and `event_hash` — this
 * class never computes them. A chain the application could write is a chain the
 * application could forge.
 */
@Injectable()
export class PayoutAuditService {
  private readonly logger = new Logger(PayoutAuditService.name);

  /** Off until migrations 104–108 are applied. Mirrors the destinations flag. */
  private readonly enabled = process.env.PAYOUT_DESTINATIONS_ENABLED === 'true';

  constructor(private readonly supabase: SupabaseService) {}

  /**
   * Record an event. Never throws.
   *
   * For transitions where the money has already moved — use this, and treat a
   * failure as an operational alert rather than a reason to abort.
   */
  async emit(event: PayoutAuditEvent): Promise<string | null> {
    if (!this.enabled) return null;
    try {
      return await this.insert(event);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      // Everything needed to reconstruct the event by hand is in this line.
      this.logger.error(
        `[PAYOUT][AUDIT][LOST] type=${event.eventType} provider=${event.providerUserId} ` +
          `destination=${event.payoutDestinationId ?? '-'} escrow=${event.escrowId ?? '-'} ` +
          `tx=${event.transactionId ?? '-'} actor=${event.actorType}:${event.actorId ?? '-'} ` +
          `request=${RequestContextStore.requestId() ?? '-'} — ${detail}`,
      );
      return null;
    }
  }

  /**
   * Record an event, or refuse to continue.
   *
   * For transitions BEFORE money moves. The caller must let this propagate.
   */
  async emitOrThrow(event: PayoutAuditEvent): Promise<string | null> {
    if (!this.enabled) return null;
    return this.insert(event);
  }

  private async insert(event: PayoutAuditEvent): Promise<string> {
    const row: Record<string, unknown> = {
      provider_user_id: event.providerUserId,
      event_type: event.eventType,
      actor_type: event.actorType,
      actor_id: event.actorId ?? null,
      payout_destination_id: event.payoutDestinationId ?? null,
      escrow_id: event.escrowId ?? null,
      transaction_id: event.transactionId ?? null,
      verification_id: event.verificationId ?? null,
      destination_fingerprint: event.destinationFingerprint ?? null,
      normalized_destination: event.normalizedDestination ?? null,
      channel: event.channel ?? null,
      request_id: RequestContextStore.requestId() ?? null,
      reason: event.reason ?? null,
      metadata: event.metadata ?? {},
    };
    // Only set when supplied so the column default (now()) applies otherwise.
    if (event.occurredAt) row.occurred_at = event.occurredAt.toISOString();
    // Pre-generated by the caller when a snapshot must reference this event.
    if (event.eventId) row.event_id = event.eventId;

    const { data, error } = await this.supabase.client
      .from('payout_audit_events')
      .insert(row)
      .select('event_id')
      .single();

    if (error) throw new Error(`payout audit insert failed: ${error.message}`);
    return (data as unknown as { event_id: string }).event_id;
  }
}
