import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleInit,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { DarajaService } from '../mpesa/daraja.service';
import { MpesaService, ParsedStkCallback } from '../mpesa/mpesa.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { CampaignsService, PromotionCampaignRow } from './campaigns.service';

export interface PromotionPaymentRow {
  id: string;
  campaign_id: string;
  payer_user_id: string;
  phone: string;
  amount_kes: number;
  status: 'pending' | 'paid' | 'failed';
  checkout_request_id: string | null;
  merchant_request_id: string | null;
  mpesa_receipt: string | null;
  failure_reason: string | null;
  paid_at: string | null;
  created_at: string;
}

const PAYMENT_COLUMNS =
  'id, campaign_id, payer_user_id, phone, amount_kes, status, checkout_request_id, ' +
  'merchant_request_id, mpesa_receipt, failure_reason, paid_at, created_at';

const PHONE_RE = /^254\d{9}$/;

/** Same normalization contract as MpesaService (kept identical on purpose). */
function normalizePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let phone = raw.replace(/[\s\-\(\)\+]/g, '');
  if (/^0\d{9}$/.test(phone)) phone = '254' + phone.slice(1);
  else if (/^7\d{8}$/.test(phone)) phone = '254' + phone;
  return PHONE_RE.test(phone) ? phone : null;
}

/**
 * An STK prompt Daraja never resolved is abandoned after this long; a fresh
 * initiate is then allowed. A late success callback for an abandoned attempt
 * is still honoured (money moved — see handleStkCallback recovery).
 */
const STALE_PENDING_MS = 3 * 60 * 1000;

/**
 * Promotion purchases over M-Pesa STK.
 *
 * Deliberately NOT the escrow path (MpesaService.initiatePayment): promotion
 * money is platform revenue — no provider, no escrow row, no B2C payout, no
 * fee tiers (the package price IS the total). What IS shared: DarajaService
 * (STK + OAuth), phone normalization, the single MPESA_CALLBACK_URL, and the
 * dev force-success simulation pattern.
 *
 * Callback routing: Daraja posts every STK result to /mpesa/stk-callback.
 * MpesaService owns that route; this service registers itself as a fallback
 * consumer, claiming callbacks whose checkout_request_id matches a
 * promotion_payments row.
 */
@Injectable()
export class PromotionPaymentsService implements OnModuleInit {
  private readonly logger = new Logger(PromotionPaymentsService.name);

  /** Same dev-simulation contract as MpesaService (which hard-blocks prod at boot). */
  private readonly devForceSuccess =
    process.env.MPESA_DEV_FORCE_SUCCESS === 'true' && process.env.NODE_ENV !== 'production';

  constructor(
    private readonly supabase: SupabaseService,
    private readonly daraja: DarajaService,
    private readonly mpesa: MpesaService,
    private readonly campaigns: CampaignsService,
    private readonly events: EventsService,
  ) {}

  onModuleInit(): void {
    this.mpesa.registerStkCallbackFallback({
      name: 'promotion_payments',
      handle: (parsed) => this.handleStkCallback(parsed),
    });
  }

  // ── Initiate ────────────────────────────────────────────────────────────────

  async initiate(campaignId: string, userId: string, phoneOverride?: string) {
    this.logger.log(`[PROMO][PAY] ▶ initiate — campaign=${campaignId} payer=${userId}`);

    const { data: campaignData, error: campaignError } = await this.supabase.client
      .from('promotion_campaigns')
      .select('id, owner_user_id, status, price_kes, package_name, post_title')
      .eq('id', campaignId)
      .maybeSingle();

    if (campaignError) throw new Error(`Failed to load campaign: ${campaignError.message}`);
    if (!campaignData) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    const campaign = campaignData as Pick<
      PromotionCampaignRow,
      'id' | 'owner_user_id' | 'status' | 'price_kes' | 'package_name' | 'post_title'
    >;

    if (campaign.owner_user_id !== userId) {
      throw new ForbiddenException('This campaign belongs to another account.');
    }
    if (campaign.status !== 'awaiting_payment') {
      throw new ConflictException(
        campaign.status === 'pending_review' || campaign.status === 'active'
          ? 'This campaign is already paid for.'
          : `This campaign can no longer be paid (status: ${campaign.status}).`,
      );
    }

    // One STK prompt at a time; self-heal prompts Daraja never resolved.
    const { data: pending } = await this.supabase.client
      .from('promotion_payments')
      .select(PAYMENT_COLUMNS)
      .eq('campaign_id', campaignId)
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (pending) {
      const ageMs = Date.now() - new Date((pending as unknown as PromotionPaymentRow).created_at).getTime();
      if (ageMs < STALE_PENDING_MS) {
        throw new ConflictException(
          'A payment is already in progress — check your phone for the M-Pesa prompt.',
        );
      }
      await this.supabase.client
        .from('promotion_payments')
        .update({ status: 'failed', failure_reason: 'Payment window expired without confirmation.' })
        .eq('id', (pending as unknown as PromotionPaymentRow).id)
        .eq('status', 'pending');
      this.logger.warn(`[PROMO][PAY] stale pending payment ${(pending as unknown as PromotionPaymentRow).id} expired`);
    }

    // Phone: explicit override wins; otherwise the payer's profile M-Pesa number.
    let phone = normalizePhone(phoneOverride);
    if (!phone) {
      const { data: user } = await this.supabase.client
        .from('users')
        .select('phone_number')
        .eq('id', userId)
        .maybeSingle();
      phone = normalizePhone(user?.phone_number);
    }
    if (!phone) {
      throw new BadRequestException(
        'Please add your M-Pesa number to your profile to pay for the promotion.',
      );
    }

    const amount = campaign.price_kes;

    const { data: inserted, error: insertError } = await this.supabase.client
      .from('promotion_payments')
      .insert({
        campaign_id: campaignId,
        payer_user_id: userId,
        phone,
        amount_kes: amount,
        status: 'pending',
      })
      .select(PAYMENT_COLUMNS)
      .single();

    if (insertError) throw new Error(`Failed to create promotion payment: ${insertError.message}`);
    const payment = inserted as unknown as PromotionPaymentRow;

    let stkResult: { checkoutRequestId: string; merchantRequestId?: string; customerMessage: string };
    if (this.devForceSuccess) {
      stkResult = { checkoutRequestId: `DEV_${randomUUID()}`, customerMessage: 'DEV SIMULATED SUCCESS' };
      this.logger.warn(
        `[MPESA][DEV MODE ACTIVE] Simulating promotion STK success for campaign=${campaignId} (no Daraja call)`,
      );
    } else {
      try {
        stkResult = await this.daraja.stkPush({
          phone,
          amount,
          postId: campaignId, // correlation id for AccountReference
          accountReference: `Help24-Promo`,
          transactionDesc: 'Help24 Business Promotion',
        });
      } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        await this.supabase.client
          .from('promotion_payments')
          .update({ status: 'failed', failure_reason: detail.slice(0, 500) })
          .eq('id', payment.id);
        this.logger.error(`[PROMO][PAY] STK push failed — ${detail}`);
        throw new BadRequestException(detail);
      }
    }

    const { error: updateError } = await this.supabase.client
      .from('promotion_payments')
      .update({
        checkout_request_id: stkResult.checkoutRequestId,
        merchant_request_id: stkResult.merchantRequestId ?? null,
      })
      .eq('id', payment.id);

    if (updateError) {
      // Callback correlation would fail without this — surface loudly.
      this.logger.error(
        `[PROMO][PAY] failed to store checkout_request_id for payment ${payment.id}: ${updateError.message}`,
      );
    }

    if (this.devForceSuccess) {
      await this.handleStkCallback({
        checkoutRequestId: stkResult.checkoutRequestId,
        resultCode: 0,
        resultDesc: 'DEV SIMULATED SUCCESS',
        receipt: `DEV${randomUUID().replace(/-/g, '').slice(0, 10).toUpperCase()}`,
        amount,
      });
    }

    return {
      payment_id: payment.id,
      campaign_id: campaignId,
      checkout_request_id: stkResult.checkoutRequestId,
      amount_kes: amount,
      message: stkResult.customerMessage,
    };
  }

  // ── Callback settlement (fallback consumer of /mpesa/stk-callback) ─────────

  /**
   * Returns true when the callback belonged to a promotion payment (claimed),
   * false when it isn't ours. Idempotent: replays on a settled payment are
   * no-ops. A success callback landing on a payment we marked failed (stale
   * self-heal) is RECOVERED to paid — the money moved, the record must say so.
   */
  async handleStkCallback(parsed: ParsedStkCallback): Promise<boolean> {
    const { data, error } = await this.supabase.client
      .from('promotion_payments')
      .select(PAYMENT_COLUMNS)
      .eq('checkout_request_id', parsed.checkoutRequestId)
      .maybeSingle();

    if (error) {
      throw new Error(`Promotion payment lookup failed for ${parsed.checkoutRequestId}: ${error.message}`);
    }
    if (!data) return false; // not a promotion payment — let other consumers try
    const payment = data as unknown as PromotionPaymentRow;

    if (payment.status === 'paid') {
      this.logger.log(`[PROMO][PAY] callback replay on paid payment ${payment.id} — skipping`);
      return true;
    }

    if (parsed.resultCode === 0) {
      const { error: updateError } = await this.supabase.client
        .from('promotion_payments')
        .update({
          status: 'paid',
          mpesa_receipt: parsed.receipt ?? null,
          failure_reason: null,
          paid_at: new Date().toISOString(),
        })
        .eq('id', payment.id);

      if (updateError) {
        throw new Error(`Failed to mark promotion payment ${payment.id} paid: ${updateError.message}`);
      }

      this.logger.log(
        `[PROMO][PAY] ✓ paid — payment=${payment.id} campaign=${payment.campaign_id} receipt=${parsed.receipt ?? 'n/a'}` +
          (payment.status === 'failed' ? ' (recovered from stale-failed)' : ''),
      );

      void this.events.emit({
        type: EVENT_TYPES.PROMOTION_PAYMENT_SUCCESS,
        actorUserId: payment.payer_user_id,
        entityType: 'promotion_payment',
        entityId: payment.id,
        payload: {
          campaign_id: payment.campaign_id,
          amount: payment.amount_kes,
          receipt: parsed.receipt ?? null,
        },
      });

      // Progress the campaign (pending_review, or active when auto_approve).
      await this.campaigns.onPaymentSuccess(payment.campaign_id);
    } else {
      // Never clobber a paid record with a late failure signal.
      const { error: updateError } = await this.supabase.client
        .from('promotion_payments')
        .update({
          status: 'failed',
          failure_reason: (parsed.resultDesc ?? 'Payment failed.').slice(0, 500),
        })
        .eq('id', payment.id)
        .eq('status', 'pending');

      if (updateError) {
        throw new Error(`Failed to mark promotion payment ${payment.id} failed: ${updateError.message}`);
      }

      this.logger.warn(
        `[PROMO][PAY] ✗ failed — payment=${payment.id} code=${parsed.resultCode} desc="${parsed.resultDesc}"`,
      );

      void this.events.emit({
        type: EVENT_TYPES.PROMOTION_PAYMENT_FAILED,
        actorUserId: payment.payer_user_id,
        entityType: 'promotion_payment',
        entityId: payment.id,
        payload: {
          campaign_id: payment.campaign_id,
          result_code: parsed.resultCode,
          result_desc: parsed.resultDesc,
        },
      });
    }

    return true;
  }

  // ── Owner reads ─────────────────────────────────────────────────────────────

  /** Poll target for the checkout screen (PaymentScreen state machine). */
  async statusForCampaign(campaignId: string, userId: string) {
    const { data: campaign, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select('id, owner_user_id, status')
      .eq('id', campaignId)
      .maybeSingle();

    if (error) throw new Error(`Failed to load campaign: ${error.message}`);
    if (!campaign) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    if (campaign.owner_user_id !== userId) {
      throw new ForbiddenException('This campaign belongs to another account.');
    }

    const { data: payment } = await this.supabase.client
      .from('promotion_payments')
      .select(PAYMENT_COLUMNS)
      .eq('campaign_id', campaignId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    const p = payment as unknown as PromotionPaymentRow | null;
    return {
      campaign_id: campaignId,
      campaign_status: campaign.status,
      payment_status: p?.status ?? null,
      mpesa_receipt: p?.mpesa_receipt ?? null,
      failure_reason: p?.failure_reason ?? null,
      amount_kes: p?.amount_kes ?? null,
    };
  }

  /** Payment history for the Profile → Promote Business → Payments screen. */
  async listByPayer(userId: string) {
    const { data, error } = await this.supabase.client
      .from('promotion_payments')
      .select(`${PAYMENT_COLUMNS}, promotion_campaigns(package_name, post_title)`)
      .eq('payer_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(100);

    if (error) throw new Error(`Failed to list promotion payments: ${error.message}`);
    return data ?? [];
  }

  // ── Admin ───────────────────────────────────────────────────────────────────

  /** Revenue summary: paid totals overall / last 30 days / by package. */
  async revenueSummary() {
    const { data, error } = await this.supabase.client
      .from('promotion_payments')
      .select('amount_kes, paid_at, created_at, promotion_campaigns(package_id, package_name)')
      .eq('status', 'paid')
      .order('created_at', { ascending: false })
      .limit(10000);

    if (error) throw new Error(`Failed to load revenue: ${error.message}`);

    const rows = (data ?? []) as unknown as Array<{
      amount_kes: number;
      paid_at: string | null;
      created_at: string;
      promotion_campaigns: { package_id: string; package_name: string } | null;
    }>;

    const cutoff30 = Date.now() - 30 * 24 * 60 * 60 * 1000;
    let total = 0;
    let last30 = 0;
    const byPackage: Record<string, { package_name: string; count: number; amount_kes: number }> = {};

    for (const row of rows) {
      total += row.amount_kes;
      const paidTime = new Date(row.paid_at ?? row.created_at).getTime();
      if (paidTime >= cutoff30) last30 += row.amount_kes;

      const key = row.promotion_campaigns?.package_id ?? 'unknown';
      byPackage[key] ??= {
        package_name: row.promotion_campaigns?.package_name ?? 'Unknown',
        count: 0,
        amount_kes: 0,
      };
      byPackage[key].count++;
      byPackage[key].amount_kes += row.amount_kes;
    }

    return {
      total_kes: total,
      last_30_days_kes: last30,
      payments_count: rows.length,
      by_package: byPackage,
    };
  }
}
