/**
 * Canonical event type strings for Help24's system_events table.
 *
 * NAMING CONVENTION: <domain>.<verb_past_tense>
 *
 * Every significant state change in the system MUST emit one of these events.
 * The event type drives the EventProcessorService handler, notification routing,
 * and the FCM data.type field used by the Flutter app for navigation.
 */

export const EVENT_TYPES = {
  // ── Payment lifecycle ──────────────────────────────────────────────────────
  /** STK push initiated; transaction row created (status=pending). */
  PAYMENT_INITIATED:       'payment.initiated',
  /** STK push accepted by Daraja; checkout_request_id stored. */
  PAYMENT_STK_SENT:        'payment.stk_sent',
  /** Daraja STK callback received with resultCode=0; transaction=paid. */
  PAYMENT_SUCCESS:         'payment.success',
  /** Daraja STK callback received with resultCode≠0; transaction=failed. */
  PAYMENT_FAILED:          'payment.failed',
  /** Client approved job — B2C payout should be initiated. */
  PAYMENT_PAYOUT_REQUESTED: 'payment.payout_requested',

  // ── Escrow lifecycle ───────────────────────────────────────────────────────
  /** Escrow row confirmed locked after payment success. */
  ESCROW_LOCKED:           'escrow.locked',
  /** B2C payout call accepted; escrow/transaction=payout_pending. */
  ESCROW_PAYOUT_PENDING:   'escrow.payout_pending',
  /** B2C callback resultCode=0; funds sent to provider. */
  ESCROW_RELEASED:         'escrow.released',
  /** Dispute opened; escrow frozen. */
  ESCROW_DISPUTED:         'escrow.disputed',
  /** Refund issued; escrow closed. */
  ESCROW_REFUNDED:         'escrow.refunded',

  // ── Job completion lifecycle ───────────────────────────────────────────────
  /** Provider marked job done; job_completions row created. */
  JOB_COMPLETION_REQUESTED: 'job.completion_requested',
  /** Client approved completion; payout flow begins. */
  JOB_APPROVED:            'job.approved',
  /** Client disputed completion; funds frozen. */
  JOB_DISPUTED:            'job.disputed',

  // ── Dispute lifecycle ──────────────────────────────────────────────────────
  /** Dispute record created. */
  DISPUTE_OPENED:          'dispute.opened',
  /** Admin resolved: release full payment to provider. */
  DISPUTE_RESOLVED_RELEASE: 'dispute.resolved_release',
  /** Admin resolved: full refund to buyer. */
  DISPUTE_RESOLVED_REFUND:  'dispute.resolved_refund',
  /** Admin resolved: partial split. */
  DISPUTE_RESOLVED_PARTIAL: 'dispute.resolved_partial',

  // ── Post lifecycle ─────────────────────────────────────────────────────────
  POST_PROVIDER_SELECTED:  'post.provider_selected',
  POST_COMPLETED:          'post.completed',

  // ── Chat / messaging ───────────────────────────────────────────────────────
  CHAT_CREATED:            'chat.created',
  MESSAGE_SENT:            'message.sent',
} as const;

export type EventType = (typeof EVENT_TYPES)[keyof typeof EVENT_TYPES];

/** Domain entities referenced in system_events.entity_type. */
export type EntityType =
  | 'post'
  | 'chat'
  | 'payment'
  | 'message'
  | 'application'
  | 'dispute'
  | 'escrow'
  | 'job_completion';

export interface EmitEventDto {
  type: EventType;
  actorUserId?: string;
  entityType: EntityType;
  /** UUID of the primary entity (transaction_id, post_id, dispute_id, etc.). */
  entityId: string;
  /** Structured data needed by the event handler (IDs, titles, amounts). */
  payload?: Record<string, unknown>;
}
