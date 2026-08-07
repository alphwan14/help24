import { Module } from '@nestjs/common';
import { PayoutDestinationsService } from './payout-destinations.service';
import { PayoutAuditService } from './payout-audit.service';

/**
 * Payout destinations — where money goes, as a concept separate from who
 * someone is.
 *
 * Deliberately has no controller yet. Phase 1–3 are server-side only: the
 * backend snapshots and resolves destinations, and nothing is exposed to the
 * app until the OTP flow exists. Adding the endpoints before the verification
 * path would mean shipping a way to create destinations that nothing can prove.
 */
@Module({
  providers: [PayoutDestinationsService, PayoutAuditService],
  exports: [PayoutDestinationsService, PayoutAuditService],
})
export class PayoutsModule {}
