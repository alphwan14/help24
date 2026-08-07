import {
  BadRequestException,
  ConflictException,
  Injectable,
  InternalServerErrorException,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { normalizeMsisdn } from '../common/phone/msisdn';
import { PayoutAuditService } from './payout-audit.service';
import {
  OTP_RESEND_COOLDOWN_MS,
  PayoutOtpService,
  type IssuedChallenge,
} from './payout-otp.service';

/** Owner-facing view of a destination row. */
export interface OwnedDestination {
  id: string;
  channel: string;
  country: string;
  destination: string;
  status: 'pending' | 'active' | 'retired';
  is_default: boolean;
  verification_method: string | null;
  verified_at: string | null;
  created_at: string;
  retired_at: string | null;
  retired_reason: string | null;
  verification: {
    verification_id: string;
    expires_at: string;
    attempts: number;
    max_attempts: number;
    resend_available_at: string;
  } | null;
}

const OWNER_COLUMNS =
  'id, provider_user_id, channel, country, normalized_destination, status, is_default, ' +
  'verification_method, verified_at, created_at, retired_at, retired_reason';

interface DestinationRow {
  id: string;
  provider_user_id: string;
  channel: string;
  country: string;
  normalized_destination: string;
  status: 'pending' | 'active' | 'retired';
  is_default: boolean;
  verification_method: string | null;
  verified_at: string | null;
  created_at: string;
  retired_at: string | null;
  retired_reason: string | null;
}

/**
 * The provider-facing side of payout destinations: add, verify, choose,
 * retire. `PayoutDestinationsService` next door stays what it was — the
 * read/resolve path the money flow uses — so the class MpesaService depends on
 * is untouched by onboarding concerns.
 *
 * Every method takes the token-verified uid and refuses to see rows belonging
 * to anyone else; a foreign id gets the same 404 as a missing one.
 */
@Injectable()
export class PayoutOnboardingService {
  private readonly logger = new Logger(PayoutOnboardingService.name);
  private readonly enabled = process.env.PAYOUT_DESTINATIONS_ENABLED === 'true';

  constructor(
    private readonly supabase: SupabaseService,
    private readonly otp: PayoutOtpService,
    private readonly audit: PayoutAuditService,
  ) {}

  /** Called by every route: the whole surface is behind the rollout flag. */
  assertEnabled(): void {
    if (!this.enabled) {
      throw new ServiceUnavailableException(
        'Payout destinations are not enabled on this server yet.',
      );
    }
  }

  async list(uid: string): Promise<OwnedDestination[]> {
    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .select(OWNER_COLUMNS)
      .eq('provider_user_id', uid)
      .order('created_at', { ascending: false });
    if (error) {
      throw new InternalServerErrorException('Could not load payout destinations.');
    }

    const rows = (data as unknown as DestinationRow[]) ?? [];
    const out: OwnedDestination[] = [];
    for (const row of rows) {
      out.push(await this.toOwned(row));
    }
    return out;
  }

  /**
   * Add a number and issue its verification challenge.
   *
   * Idempotent on the number: re-adding the pending one just reissues its code
   * (subject to the cooldown), and re-adding an active one is a 409 rather
   * than a duplicate. A DIFFERENT pending number supersedes the old pending —
   * the schema allows one pending per channel, and the newest intent wins.
   */
  async add(uid: string, rawMsisdn: string): Promise<OwnedDestination> {
    const msisdn = normalizeMsisdn(rawMsisdn);
    if (!msisdn || !msisdn.startsWith('2547')) {
      throw new BadRequestException(
        'Enter a valid Safaricom number (07XX XXX XXX) — M-Pesa payouts only work to Safaricom lines.',
      );
    }

    const existing = await this.ownRows(uid);
    const activeSame = existing.find(
      (d) => d.status === 'active' && d.normalized_destination === msisdn,
    );
    if (activeSame) {
      throw new ConflictException('This number is already a verified payout destination.');
    }

    const pending = existing.find((d) => d.status === 'pending');
    if (pending && pending.normalized_destination === msisdn) {
      await this.issueFor(pending, uid);
      return this.toOwned(await this.freshRow(pending.id));
    }
    if (pending) {
      await this.retireInternal(pending, uid, 'superseded by a new payout number');
    }

    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .insert({
        provider_user_id: uid,
        channel: 'mpesa',
        country: 'KE',
        destination_value: rawMsisdn.trim(),
        normalized_destination: msisdn,
        status: 'pending',
        created_by_uid: uid,
      })
      .select(OWNER_COLUMNS)
      .single();

    if (error || !data) {
      // 23503: the uid has no users row yet — profile creation precedes payouts.
      if (error?.code === '23503') {
        throw new BadRequestException('Finish setting up your profile first, then add a payout number.');
      }
      this.logger.error(`[PAYOUT][ONBOARD] insert failed for ${uid}: ${error?.message}`);
      throw new InternalServerErrorException('Could not save the payout number.');
    }

    const row = data as unknown as DestinationRow;
    await this.audit.emit({
      providerUserId: uid,
      eventType: 'destination_created',
      actorType: 'provider',
      actorId: uid,
      payoutDestinationId: row.id,
      normalizedDestination: msisdn,
      channel: 'mpesa',
    });

    await this.issueFor(row, uid);
    return this.toOwned(await this.freshRow(row.id));
  }

  /** Resend: reissue the challenge for a pending destination. */
  async requestChallenge(uid: string, destinationId: string): Promise<IssuedChallenge> {
    const row = await this.ownRow(uid, destinationId);
    if (row.status !== 'pending') {
      throw new BadRequestException(
        row.status === 'active'
          ? 'This destination is already verified.'
          : 'This destination is retired. Add the number again to use it.',
      );
    }
    return this.issueFor(row, uid);
  }

  /**
   * Verify the live challenge. The RPC owns the judgement; this maps its
   * outcome onto HTTP so the client can branch without parsing prose.
   */
  async verify(
    uid: string,
    destinationId: string,
    code: string,
    makeDefault: boolean,
  ): Promise<OwnedDestination> {
    const row = await this.ownRow(uid, destinationId);
    if (row.status === 'active') {
      throw new BadRequestException('This destination is already verified.');
    }
    if (row.status === 'retired') {
      throw new BadRequestException('This destination is retired. Add the number again to use it.');
    }

    const result = await this.otp.consume({ destinationId, code, makeDefault });

    if (result.outcome === 'verified') {
      await this.audit.emit({
        providerUserId: uid,
        eventType: 'otp_verified',
        actorType: 'provider',
        actorId: uid,
        payoutDestinationId: destinationId,
        normalizedDestination: row.normalized_destination,
        channel: 'mpesa',
      });
      return this.toOwned(await this.freshRow(destinationId));
    }

    await this.audit.emit({
      providerUserId: uid,
      eventType: 'otp_failed',
      actorType: 'provider',
      actorId: uid,
      payoutDestinationId: destinationId,
      reason: result.outcome,
      channel: 'mpesa',
    });

    switch (result.outcome) {
      case 'invalid_code':
        throw new BadRequestException({
          message:
            result.attemptsRemaining > 0
              ? `Incorrect code. ${result.attemptsRemaining} ${
                  result.attemptsRemaining === 1 ? 'attempt' : 'attempts'
                } left.`
              : 'Incorrect code.',
          code: 'OTP_INVALID',
          attemptsRemaining: result.attemptsRemaining,
        });
      case 'expired':
        throw new BadRequestException({
          message: 'That code has expired. Request a new one.',
          code: 'OTP_EXPIRED',
        });
      case 'too_many_tries':
        throw new BadRequestException({
          message: 'Too many incorrect attempts. Request a new code.',
          code: 'OTP_LOCKED',
        });
      case 'already_used':
      case 'not_found':
      default:
        throw new BadRequestException({
          message: 'No active code for this number. Request a new one.',
          code: 'OTP_NOT_FOUND',
        });
    }
  }

  async setDefault(uid: string, destinationId: string): Promise<OwnedDestination> {
    const row = await this.ownRow(uid, destinationId);

    const { data, error } = await this.supabase.client.rpc(
      'fn_set_default_payout_destination',
      { p_destination_id: destinationId, p_actor: `provider:${uid}` },
    );
    if (error) {
      if (error.message.includes('help24_payout_default_requires_active')) {
        throw new BadRequestException('Verify the destination before making it the default.');
      }
      this.logger.error(`[PAYOUT][ONBOARD] set-default failed for ${destinationId}: ${error.message}`);
      throw new InternalServerErrorException('Could not change the default destination.');
    }
    if (data !== true) {
      throw new NotFoundException('Destination not found.');
    }

    await this.audit.emit({
      providerUserId: uid,
      eventType: 'default_changed',
      actorType: 'provider',
      actorId: uid,
      payoutDestinationId: destinationId,
      normalizedDestination: row.normalized_destination,
      channel: 'mpesa',
    });
    return this.toOwned(await this.freshRow(destinationId));
  }

  async retire(uid: string, destinationId: string, reason: string): Promise<void> {
    const row = await this.ownRow(uid, destinationId);
    if (row.status === 'retired') return;
    await this.retireInternal(row, uid, reason);
  }

  // ── internals ────────────────────────────────────────────────────────────

  private async issueFor(row: DestinationRow, uid: string): Promise<IssuedChallenge> {
    const challenge = await this.otp.issue({
      destinationId: row.id,
      sentTo: row.normalized_destination,
      uid,
    });
    await this.audit.emit({
      providerUserId: uid,
      eventType: 'otp_requested',
      actorType: 'provider',
      actorId: uid,
      payoutDestinationId: row.id,
      verificationId: challenge.verification_id,
      normalizedDestination: row.normalized_destination,
      channel: 'mpesa',
    });
    return challenge;
  }

  private async retireInternal(
    row: DestinationRow,
    uid: string,
    reason: string,
  ): Promise<void> {
    const { data, error } = await this.supabase.client.rpc(
      'fn_retire_payout_destination',
      { p_destination_id: row.id, p_reason: reason, p_actor: `provider:${uid}` },
    );
    if (error || data !== true) {
      this.logger.error(
        `[PAYOUT][ONBOARD] retire failed for ${row.id}: ${error?.message ?? 'not found'}`,
      );
      throw new InternalServerErrorException('Could not retire the destination.');
    }
    await this.audit.emit({
      providerUserId: uid,
      eventType: 'destination_retired',
      actorType: 'provider',
      actorId: uid,
      payoutDestinationId: row.id,
      normalizedDestination: row.normalized_destination,
      reason,
      channel: 'mpesa',
    });
  }

  private async ownRows(uid: string): Promise<DestinationRow[]> {
    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .select(OWNER_COLUMNS)
      .eq('provider_user_id', uid);
    if (error) {
      throw new InternalServerErrorException('Could not load payout destinations.');
    }
    return (data as unknown as DestinationRow[]) ?? [];
  }

  private async ownRow(uid: string, destinationId: string): Promise<DestinationRow> {
    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .select(OWNER_COLUMNS)
      .eq('id', destinationId)
      .eq('provider_user_id', uid)
      .maybeSingle();
    if (error) {
      throw new InternalServerErrorException('Could not load the destination.');
    }
    // A row someone else owns answers exactly like a row that does not exist.
    if (!data) throw new NotFoundException('Destination not found.');
    return data as unknown as DestinationRow;
  }

  private async freshRow(destinationId: string): Promise<DestinationRow> {
    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .select(OWNER_COLUMNS)
      .eq('id', destinationId)
      .single();
    if (error || !data) {
      throw new InternalServerErrorException('Could not reload the destination.');
    }
    return data as unknown as DestinationRow;
  }

  private async toOwned(row: DestinationRow): Promise<OwnedDestination> {
    let verification: OwnedDestination['verification'] = null;
    if (row.status === 'pending') {
      const live = await this.otp.liveChallenge(row.id);
      if (live) {
        verification = {
          verification_id: live.id,
          expires_at: live.expires_at,
          attempts: live.attempts,
          max_attempts: live.max_attempts,
          resend_available_at: new Date(
            new Date(live.created_at).getTime() + OTP_RESEND_COOLDOWN_MS,
          ).toISOString(),
        };
      }
    }
    return {
      id: row.id,
      channel: row.channel,
      country: row.country,
      destination: row.normalized_destination,
      status: row.status,
      is_default: row.is_default,
      verification_method: row.verification_method,
      verified_at: row.verified_at,
      created_at: row.created_at,
      retired_at: row.retired_at,
      retired_reason: row.retired_reason,
      verification,
    };
  }
}
