import { Injectable, Logger } from '@nestjs/common';

/**
 * How a payout-verification code reaches the provider's phone.
 *
 * WHY THIS IS A PORT AND NOT A METHOD ON THE OTP SERVICE
 * ------------------------------------------------------
 * Sign-in OTPs stay on Firebase Authentication — Google delivers those and we
 * never see the code. Business/security OTPs (payout verification is the first)
 * will go out through Africa's Talking, where we control the wording and the
 * sender identity. That split is a product decision already made; what is NOT
 * implemented yet is the sending itself, because no SMS account exists.
 *
 * Keeping delivery behind this interface means the Africa's Talking client is
 * one new class and one provider swap in `payouts.module.ts` — the issuer, the
 * challenge schema and the verify path do not change when SMS arrives.
 */
export const OTP_DELIVERY = Symbol('OTP_DELIVERY');

export interface OtpDeliveryPort {
  /**
   * Deliver `code` to `msisdn`. Implementations must never log or store the
   * code beyond what delivery itself requires.
   */
  deliver(args: { msisdn: string; code: string; ttlSeconds: number }): Promise<void>;
}

/**
 * Pre-SMS delivery: records THAT a code was issued, never the code itself.
 *
 * Until an SMS provider is wired, a real provider cannot receive the code —
 * that is a known launch dependency (Launch Readiness Sprint §3.2), not a bug.
 * For device QA, setting PAYOUT_OTP_ECHO_CODES=true echoes the code into the
 * logs. That flag must NEVER be set once real providers exist: a logged OTP is
 * a logged password for redirecting payouts.
 */
@Injectable()
export class LogOnlyOtpDelivery implements OtpDeliveryPort {
  private readonly logger = new Logger('OtpDelivery');
  private readonly echoCodes = process.env.PAYOUT_OTP_ECHO_CODES === 'true';

  deliver(args: { msisdn: string; code: string; ttlSeconds: number }): Promise<void> {
    const masked = args.msisdn.slice(0, 6) + '***' + args.msisdn.slice(-2);
    if (this.echoCodes) {
      this.logger.warn(
        `[OTP][ECHO] code=${args.code} → ${masked} (PAYOUT_OTP_ECHO_CODES is on — QA only, ` +
          `disable before real providers onboard)`,
      );
    } else {
      this.logger.log(
        `[OTP] payout verification code issued → ${masked} ttl=${args.ttlSeconds}s ` +
          `(no SMS provider wired yet — delivery is a launch dependency)`,
      );
    }
    return Promise.resolve();
  }
}

// Africa's Talking implementation intentionally absent. It arrives with the SMS
// account credentials as `AfricasTalkingOtpDelivery implements OtpDeliveryPort`,
// registered against OTP_DELIVERY in payouts.module.ts. Do not scaffold it
// earlier: an unsendable sender is untestable code.
