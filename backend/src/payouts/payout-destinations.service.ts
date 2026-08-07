import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import {
  resolvePayoutDestination,
  snapshotOf,
  type PayoutChannel,
  type PayoutDestination,
  type PayoutDestinationSnapshot,
  type ResolveOutcome,
} from './payout-destination.resolver';

/**
 * Every field the resolver reads. `verification_method` in particular is NOT
 * optional: omit it and `isStronglyVerified` sees null for everything, so Phase
 * 5 would refuse every payout in the system while looking like a policy
 * decision rather than a missing column.
 */
const DESTINATION_COLUMNS =
  'id, provider_user_id, channel, country, normalized_destination, ' +
  'destination_fingerprint, status, is_default, ' +
  'verification_method, verified_at, verified_by, verification_id';

/**
 * Reads payout destinations and answers the only question that matters:
 * WHERE DOES THIS MONEY GO?
 *
 * The decision itself lives in the pure resolver next door and is unit-tested
 * without a database. This class does I/O and nothing else, so there is exactly
 * one place to read to know the rule, and exactly one place to read to know
 * where the data came from.
 *
 * ROLLOUT SAFETY — WHY EVERYTHING IS OFF BY DEFAULT
 * -------------------------------------------------
 * Migrations 104–107 are written but NOT applied. If this service queried
 * `payout_destinations` unconditionally, deploying it before the migrations
 * would turn every escrow payment into a 500 against a table that does not
 * exist. So the whole feature is behind `PAYOUT_DESTINATIONS_ENABLED`, which
 * defaults to FALSE: until it is switched on, every method here returns "no
 * opinion" and `MpesaService` behaves exactly as it does today.
 *
 * That is also the Phase 2/3 rollout switch, not a temporary scaffold. The
 * order is: apply migrations → enable the flag → watch `source=` in the payout
 * logs → only then tighten.
 */
@Injectable()
export class PayoutDestinationsService {
  private readonly logger = new Logger(PayoutDestinationsService.name);

  /** Master switch. Off until migrations 104–107 are applied. */
  private readonly enabled = process.env.PAYOUT_DESTINATIONS_ENABLED === 'true';

  /**
   * Phase 4 flips this to 'false'. While true, an escrow created before the
   * snapshot existed may still be settled from the provider's current
   * destination — because refusing would strand money that is already owed.
   */
  private readonly allowLegacyFallback =
    process.env.PAYOUT_ALLOW_LEGACY_FALLBACK !== 'false';

  /**
   * Phase 5 flips this to 'true'. While false, a destination whose provenance
   * is 'migration' or 'admin' is still payable, which is what stops the
   * migration holding an existing provider's earnings hostage to an OTP they
   * have not been asked for yet.
   */
  private readonly requireVerified =
    process.env.PAYOUT_REQUIRE_VERIFIED === 'true';

  constructor(private readonly supabase: SupabaseService) {}

  get isEnabled(): boolean {
    return this.enabled;
  }

  /**
   * The destination a NEW escrow should freeze: the provider's DEFAULT.
   *
   * A provider may now hold several active destinations — an M-Pesa line and,
   * later, a bank account. Exactly one is the default, and that is the one an
   * escrow selects automatically. Ordering by `is_default` first means that if
   * the one-default index were ever violated by a bug, this degrades to "pay
   * the chosen one" rather than "pay whichever row the planner returned first".
   *
   * A provider with active destinations but NO default resolves to null and the
   * payout refuses with a clear message. That is deliberate: after retiring
   * their default, choosing the replacement is theirs to do, not ours to guess.
   */
  async getPayable(
    providerUserId: string,
    channel: PayoutChannel = 'mpesa',
  ): Promise<PayoutDestination | null> {
    if (!this.enabled) return null;

    const { data, error } = await this.supabase.client
      .from('payout_destinations')
      .select(DESTINATION_COLUMNS)
      .eq('provider_user_id', providerUserId)
      .eq('channel', channel)
      .eq('status', 'active')
      .eq('is_default', true)
      .limit(1)
      .maybeSingle();

    if (error) {
      // Never throw from here. A failed lookup must degrade to the existing
      // behaviour, not take down a payment that would otherwise have worked.
      this.logger.error(
        `[PAYOUT][DEST] lookup failed for ${providerUserId}/${channel}: ${error.message}`,
      );
      return null;
    }
    // Double cast: the concatenated column list defeats the client's literal
    // type inference, so it widens to a union that includes its error shape.
    return (data as unknown as PayoutDestination | null) ?? null;
  }

  /**
   * Freeze the provider's destination for an escrow being created.
   *
   * Returns null when there is nothing to freeze, which is not an error: the
   * escrow is simply created without a snapshot and settles through the
   * transitional path, exactly as every escrow does today.
   */
  async buildSnapshot(
    providerUserId: string,
    channel: PayoutChannel = 'mpesa',
    auditEventId: string | null = null,
  ): Promise<{ id: string; snapshot: PayoutDestinationSnapshot } | null> {
    const destination = await this.getPayable(providerUserId, channel);
    if (!destination) return null;
    return {
      id: destination.id,
      snapshot: snapshotOf(destination, new Date(), auditEventId),
    };
  }

  /**
   * Decide where a payout goes.
   *
   * `escrowSnapshot` is whatever was frozen onto the escrow — pass it straight
   * through, including null for pre-migration escrows. The resolver decides;
   * this method only supplies the inputs and the phase flags.
   */
  async resolveForPayout(args: {
    providerUserId: string;
    escrowSnapshot: PayoutDestinationSnapshot | null;
    channel?: PayoutChannel;
  }): Promise<ResolveOutcome> {
    const channel = args.channel ?? 'mpesa';

    // A snapshot ends the question — no lookup, no chance of drifting.
    if (args.escrowSnapshot) {
      return resolvePayoutDestination({
        snapshot: args.escrowSnapshot,
        current: null,
        allowLegacyFallback: this.allowLegacyFallback,
        requireVerified: this.requireVerified,
      });
    }

    const current = await this.getPayable(args.providerUserId, channel);
    return resolvePayoutDestination({
      snapshot: null,
      current,
      allowLegacyFallback: this.allowLegacyFallback,
      requireVerified: this.requireVerified,
    });
  }

  /**
   * Parse the jsonb column back into a snapshot.
   *
   * Returns null on anything malformed rather than throwing: a snapshot we
   * cannot read must fall through to the transitional path, not abort a payout.
   * A malformed snapshot is logged loudly because it should be impossible.
   */
  parseSnapshot(raw: unknown): PayoutDestinationSnapshot | null {
    if (!raw || typeof raw !== 'object') return null;
    const s = raw as Partial<PayoutDestinationSnapshot>;
    if (typeof s.destination_id !== 'string' || typeof s.normalized_destination !== 'string') {
      this.logger.error(
        `[PAYOUT][DEST] unreadable escrow snapshot: ${JSON.stringify(raw).slice(0, 200)}`,
      );
      return null;
    }
    return s as PayoutDestinationSnapshot;
  }
}
