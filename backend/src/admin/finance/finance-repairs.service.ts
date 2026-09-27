import { ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SupabaseService } from '../../supabase/supabase.service';
import { MpesaService } from '../../mpesa/mpesa.service';
import { RequestContextStore } from '../../common/request-context/request-context';
import { toHttpError } from '../../moderation/moderation-errors';
import { AdminAlertsService } from '../alerts/admin-alerts.service';
import { AdminContext, roleAtLeast } from '../auth/admin-role';
import { ApplyRulingDto, ManualSettlementDto } from './dto/finance.dto';

type Row = Record<string, any>;

const CLOSED = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial'];

export type ShareState = 'owed' | 'paid' | 'in_flight' | 'not_applicable';

export interface DisputeMoney {
  dispute: { id: string; status: string; closed: boolean };
  ruling: { id: string; type: string; provider_amount: number | null; client_refund_amount: number | null; decided_at: string } | null;
  payment: { id: string; status: string; escrow_status: string | null; total_paid: number | null } | null;
  /** A closed dispute whose money is still frozen in 'disputed'. */
  frozen: boolean;
  /** The ruling on record can be applied (or its release retried). */
  can_apply_ruling: boolean;
  shares: {
    provider_payout: { amount: number | null; state: ShareState };
    client_refund: { amount: number | null; state: ShareState };
  };
  legs: Array<{ id: string; direction: string; rail: string; status: string; amount: number; reference: string | null;
    created_by: string; created_at: string; settled_at: string | null; environment: string }>;
  history: Array<{ action_type: string; admin_email: string; admin_role: string; reason: string; reference: string | null;
    new_state: Record<string, unknown>; created_at: string }>;
  environment: 'sandbox' | 'production';
}

/**
 * The two finance repairs from migration 117, behind senior_admin.
 *
 * Both write through database functions that validate against the ruling on
 * record and append an audit row in the same transaction; this service adds
 * the role check, the M-Pesa dispatch a FULL_RELEASE needs, and refreshes the
 * alerts so the bell reflects the repair at once.
 */
@Injectable()
export class FinanceRepairsService {
  private readonly logger = new Logger(FinanceRepairsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly mpesa: MpesaService,
    private readonly alerts: AdminAlertsService,
    private readonly config: ConfigService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  /** Everything the dispute page needs to show the money after a ruling. */
  async money(disputeId: string): Promise<DisputeMoney> {
    const { data: dispute, error } = await this.db.from('disputes')
      .select('id, status, post_id, transaction_id').eq('id', disputeId).maybeSingle();
    if (error) throw toHttpError(error);
    if (!dispute) throw new NotFoundException({ code: 'FINANCE_NOT_FOUND', message: 'Dispute not found.' });

    const [ruling, payment, escrow, legs, history] = await Promise.all([
      this.db.from('dispute_decisions').select('id, decision_type, provider_amount, client_refund_amount, created_at')
        .eq('dispute_id', disputeId).neq('decision_type', 'ESCALATE').order('created_at', { ascending: false }).limit(1),
      this.db.from('transactions').select('id, status, total_paid').eq('id', dispute.transaction_id).maybeSingle(),
      this.db.from('escrow').select('status').eq('transaction_id', dispute.transaction_id).maybeSingle(),
      this.db.from('settlements')
        .select('id, direction, rail, status, amount, mpesa_receipt, created_by, created_at, settled_at, environment')
        .eq('transaction_id', dispute.transaction_id).order('created_at', { ascending: true }).limit(50),
      this.db.from('admin_finance_actions')
        .select('action_type, admin_email, admin_role, reason, reference, new_state, created_at')
        .eq('dispute_id', disputeId).order('created_at', { ascending: false }).limit(50),
    ]);
    for (const r of [ruling, payment, escrow, legs]) if (r.error) throw toHttpError(r.error);

    const dec = (ruling.data ?? [])[0] as Row | undefined;
    const tx = payment.data as Row | null;
    const legRows = (legs.data ?? []) as Row[];
    const actions = history.error ? [] : ((history.data ?? []) as Row[]);
    const closed = CLOSED.includes(dispute.status);
    const txStatus = tx?.status as string | undefined;

    const shareState = (direction: 'provider_payout' | 'client_refund', due: boolean): ShareState => {
      if (!due || txStatus !== 'refunded') return 'not_applicable';
      const live = legRows.filter((l) => l.direction === direction && !['voided', 'failed'].includes(l.status));
      if (live.some((l) => ['completed', 'succeeded'].includes(l.status))) return 'paid';
      if (live.some((l) => ['initiated', 'pending'].includes(l.status))) return 'in_flight';
      return 'owed';
    };
    const providerDue = dec?.decision_type === 'PARTIAL_SPLIT' && (dec?.provider_amount ?? 0) > 0;
    const refundDue = ['FULL_REFUND', 'PARTIAL_SPLIT'].includes(dec?.decision_type) && (dec?.client_refund_amount ?? 0) > 0;

    return {
      dispute: { id: dispute.id, status: dispute.status, closed },
      ruling: dec
        ? { id: dec.id, type: dec.decision_type, provider_amount: dec.provider_amount, client_refund_amount: dec.client_refund_amount, decided_at: dec.created_at }
        : null,
      payment: tx ? { id: tx.id, status: tx.status, escrow_status: (escrow.data as Row | null)?.status ?? null, total_paid: tx.total_paid } : null,
      frozen: closed && txStatus === 'disputed',
      can_apply_ruling: !!dec && closed && (txStatus === 'disputed'
        || (txStatus === 'paid' && dec.decision_type === 'FULL_RELEASE' && actions.some((a) => a.action_type === 'ruling_applied'))),
      shares: {
        provider_payout: { amount: providerDue ? dec!.provider_amount : null, state: shareState('provider_payout', providerDue) },
        client_refund: { amount: refundDue ? dec!.client_refund_amount : null, state: shareState('client_refund', refundDue) },
      },
      legs: legRows.map((l) => ({
        id: l.id, direction: l.direction, rail: l.rail, status: l.status, amount: l.amount, reference: l.mpesa_receipt ?? null,
        created_by: l.created_by, created_at: l.created_at, settled_at: l.settled_at, environment: l.environment,
      })),
      history: actions.map((a) => ({
        action_type: a.action_type, admin_email: a.admin_email, admin_role: a.admin_role, reason: a.reason,
        reference: a.reference, new_state: a.new_state, created_at: a.created_at,
      })),
      environment: this.environment(),
    };
  }

  /** Finance paid a ruling's share by hand: record it, for the ruling's amount. */
  async recordManualSettlement(admin: AdminContext, transactionId: string, dto: ManualSettlementDto) {
    requireSenior(admin, 'Recording a manual settlement');
    const { data, error } = await this.db.rpc('admin_record_manual_settlement', {
      p_admin_id: admin.id,
      p_transaction_id: transactionId,
      p_direction: dto.direction,
      p_reference: dto.reference.trim(),
      p_reason: dto.reason.trim(),
      p_environment: this.environment(),
      p_request_id: RequestContextStore.requestId() ?? null,
    });
    if (error) throw toHttpError(error);
    this.logger.log(`[FINANCE] manual ${dto.direction} recorded tx=${transactionId} by=${admin.email} (${admin.role})`);
    this.alerts.invalidate();
    return data as Record<string, unknown>;
  }

  /**
   * Apply the ruling on record to money a legacy resolve left frozen. For a
   * FULL_RELEASE the database unfreezes it (once — a second caller is refused)
   * and the payout goes out through the normal release path; if M-Pesa refuses
   * it, the result says so and calling again retries.
   */
  async applyRecordedRuling(admin: AdminContext, disputeId: string, dto: ApplyRulingDto) {
    requireSenior(admin, 'Applying a ruling');
    const { data, error } = await this.db.rpc('admin_apply_recorded_ruling', {
      p_admin_id: admin.id,
      p_dispute_id: disputeId,
      p_reason: dto.reason.trim(),
      p_request_id: RequestContextStore.requestId() ?? null,
    });
    if (error) throw toHttpError(error);
    const result = data as { phase: string; decision_type: string; post_id: string; needs_payout: boolean; action_id: string };
    this.logger.log(`[FINANCE] ruling ${result.decision_type} ${result.phase} dispute=${disputeId} by=${admin.email} (${admin.role})`);

    let payout: { dispatched: boolean; message: string } | null = null;
    if (result.needs_payout) {
      try {
        await this.mpesa.releasePayout({ post_id: result.post_id });
        payout = { dispatched: true, message: 'Payout sent to M-Pesa. It settles when M-Pesa confirms it.' };
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        this.logger.error(`[FINANCE] release after applying ruling failed dispute=${disputeId}: ${message}`);
        payout = { dispatched: false, message: `The money is unfrozen, but the payout did not go out: ${message} Apply the ruling again to retry.` };
      }
    }
    this.alerts.invalidate();
    return { ...result, payout };
  }

  private environment(): 'sandbox' | 'production' {
    return String(this.config.get<string>('MPESA_ENV', 'sandbox')).toLowerCase() === 'production' ? 'production' : 'sandbox';
  }
}

function requireSenior(admin: AdminContext, what: string): void {
  if (!roleAtLeast(admin.role, 'senior_admin')) {
    throw new ForbiddenException({ code: 'ROLE_REQUIRED', message: `${what} requires the senior admin role or higher.` });
  }
}
