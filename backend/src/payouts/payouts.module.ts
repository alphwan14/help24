import { Module } from '@nestjs/common';
import { PayoutDestinationsService } from './payout-destinations.service';
import { PayoutAuditService } from './payout-audit.service';
import { PayoutDestinationsController } from './payout-destinations.controller';
import { PayoutOnboardingService } from './payout-onboarding.service';
import { PayoutOtpService } from './payout-otp.service';
import { LogOnlyOtpDelivery, OTP_DELIVERY } from './otp-delivery';

/**
 * Payout destinations — where money goes, as a concept separate from who
 * someone is.
 *
 * Phase 1–3 shipped server-side only; the HTTP layer was withheld until the
 * OTP flow existed, "because adding the endpoints before the verification path
 * would mean shipping a way to create destinations that nothing can prove".
 * That condition is now met: PayoutDestinationsController exposes the owner
 * flow (add → OTP verify → default → retire) on top of the RPCs from
 * migration 106, and PayoutOtpService is the issuer.
 *
 * OTP delivery is a port (OTP_DELIVERY). Sign-in verification stays on
 * Firebase Auth; business OTPs like this one will ship via Africa's Talking —
 * until that account exists, LogOnlyOtpDelivery records issuance without
 * sending, and the whole surface stays behind PAYOUT_DESTINATIONS_ENABLED.
 */
@Module({
  controllers: [PayoutDestinationsController],
  providers: [
    PayoutDestinationsService,
    PayoutAuditService,
    PayoutOnboardingService,
    PayoutOtpService,
    { provide: OTP_DELIVERY, useClass: LogOnlyOtpDelivery },
  ],
  exports: [PayoutDestinationsService, PayoutAuditService],
})
export class PayoutsModule {}
