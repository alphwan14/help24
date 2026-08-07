import {
  HttpException,
  HttpStatus,
  Inject,
  Injectable,
  InternalServerErrorException,
  Logger,
} from '@nestjs/common';
import { createHash, randomInt } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { OTP_DELIVERY, type OtpDeliveryPort } from './otp-delivery';

/** Matches the sign-in flow and the rate-limit rationale: 6 digits, 5 minutes. */
export const OTP_TTL_MS = 5 * 60 * 1_000;
/** A resend inside this window is refused with Retry-After semantics. */
export const OTP_RESEND_COOLDOWN_MS = 60 * 1_000;

export interface IssuedChallenge {
  verification_id: string;
  expires_at: string;
  resend_available_at: string;
  attempts: number;
  max_attempts: number;
}

export interface LiveChallenge {
  id: string;
  created_at: string;
  expires_at: string;
  attempts: number;
  max_attempts: number;
}

/**
 * Issues and consumes payout-verification challenges against
 * `payout_destination_verifications`.
 *
 * The code is never stored: the row keeps sha256(pepper|code), where the pepper
 * lives only in the backend environment (PAYOUT_OTP_PEPPER). The consume side
 * is `fn_consume_payout_verification`, which owns attempts, expiry, replay and
 * default-promotion atomically — this class only computes the hash it is asked
 * to compare.
 */
@Injectable()
export class PayoutOtpService {
  private readonly logger = new Logger(PayoutOtpService.name);
  private readonly pepper = process.env.PAYOUT_OTP_PEPPER ?? '';

  constructor(
    private readonly supabase: SupabaseService,
    @Inject(OTP_DELIVERY) private readonly delivery: OtpDeliveryPort,
  ) {
    if (!this.pepper && process.env.PAYOUT_DESTINATIONS_ENABLED === 'true') {
      this.logger.warn(
        '[OTP] PAYOUT_OTP_PEPPER is not set — codes are hashed without a server pepper. ' +
          'Set it before real providers onboard; rotating it later invalidates live challenges only.',
      );
    }
  }

  hashCode(code: string): string {
    return createHash('sha256').update(`${this.pepper}|${code.trim()}`).digest('hex');
  }

  /** The one un-consumed, un-failed challenge for a destination, if any. */
  async liveChallenge(destinationId: string): Promise<LiveChallenge | null> {
    const { data, error } = await this.supabase.client
      .from('payout_destination_verifications')
      .select('id, created_at, expires_at, attempts, max_attempts')
      .eq('destination_id', destinationId)
      .is('consumed_at', null)
      .is('failed_at', null)
      .maybeSingle();
    if (error) {
      throw new InternalServerErrorException('Could not read the verification state.');
    }
    return (data as LiveChallenge | null) ?? null;
  }

  /**
   * Issue a challenge for a destination, superseding any live one.
   *
   * The cooldown is measured from the live challenge's creation, so "resend"
   * cannot be used to hold a fresh code open forever — each reissue restarts
   * the 5-minute expiry but is itself limited to once a minute (plus the
   * payout:issue rate-limit policy above this).
   */
  async issue(args: {
    destinationId: string;
    sentTo: string;
    uid: string;
  }): Promise<IssuedChallenge> {
    const existing = await this.liveChallenge(args.destinationId);
    if (existing) {
      const elapsed = Date.now() - new Date(existing.created_at).getTime();
      if (elapsed < OTP_RESEND_COOLDOWN_MS) {
        const retryAfterSeconds = Math.ceil((OTP_RESEND_COOLDOWN_MS - elapsed) / 1_000);
        throw new HttpException(
          {
            message: 'A code was just sent. Wait a moment before asking for another.',
            code: 'OTP_COOLDOWN',
            retryAfterSeconds,
          },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      }
      // Supersede: the append-only trigger permits exactly this transition, and
      // the one-live-per-destination index requires it before a new insert.
      const { error: failError } = await this.supabase.client
        .from('payout_destination_verifications')
        .update({ failed_at: new Date().toISOString(), failed_reason: 'superseded' })
        .eq('id', existing.id)
        .is('consumed_at', null)
        .is('failed_at', null);
      if (failError) {
        throw new InternalServerErrorException('Could not refresh the verification code.');
      }
    }

    const code = randomInt(100_000, 1_000_000).toString();
    const now = Date.now();
    const expiresAt = new Date(now + OTP_TTL_MS).toISOString();

    const { data, error } = await this.supabase.client
      .from('payout_destination_verifications')
      .insert({
        destination_id: args.destinationId,
        code_hash: this.hashCode(code),
        sent_to: args.sentTo,
        channel: 'mpesa',
        expires_at: expiresAt,
        created_by_uid: args.uid,
      })
      .select('id, expires_at, attempts, max_attempts')
      .single();

    if (error || !data) {
      throw new InternalServerErrorException('Could not issue a verification code.');
    }

    await this.delivery.deliver({
      msisdn: args.sentTo,
      code,
      ttlSeconds: Math.floor(OTP_TTL_MS / 1_000),
    });

    const row = data as unknown as {
      id: string;
      expires_at: string;
      attempts: number;
      max_attempts: number;
    };
    return {
      verification_id: row.id,
      expires_at: row.expires_at,
      resend_available_at: new Date(now + OTP_RESEND_COOLDOWN_MS).toISOString(),
      attempts: row.attempts,
      max_attempts: row.max_attempts,
    };
  }

  /**
   * Attempt to consume the live challenge for a destination.
   *
   * All judgement (expiry, attempts, replay, activation, default promotion) is
   * inside `fn_consume_payout_verification`; the outcome string comes back
   * verbatim: 'verified' | 'invalid_code' | 'expired' | 'already_used' |
   * 'too_many_tries' | 'not_found'.
   */
  async consume(args: {
    destinationId: string;
    code: string;
    makeDefault: boolean;
  }): Promise<{ outcome: string; attemptsRemaining: number }> {
    const live = await this.liveChallenge(args.destinationId);
    if (!live) return { outcome: 'not_found', attemptsRemaining: 0 };

    const { data, error } = await this.supabase.client.rpc('fn_consume_payout_verification', {
      p_verification_id: live.id,
      p_code_hash: this.hashCode(args.code),
      p_make_default: args.makeDefault,
    });

    if (error) {
      this.logger.error(`[OTP] consume failed for ${live.id}: ${error.message}`);
      throw new InternalServerErrorException('Verification failed. Try again.');
    }

    const row = (Array.isArray(data) ? data[0] : data) as
      | { outcome: string; attempts_remaining: number }
      | undefined;
    if (!row?.outcome) {
      throw new InternalServerErrorException('Verification failed. Try again.');
    }
    return { outcome: row.outcome, attemptsRemaining: row.attempts_remaining ?? 0 };
  }
}
