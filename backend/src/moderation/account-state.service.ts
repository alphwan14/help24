import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { Capability, Denial, DENIALS } from './moderation.constants';

/**
 * "May this account do this?", answered by the database.
 *
 * The capability map lives in ONE place — `moderation_denial()` (migration
 * 114) — and the Supabase triggers of migration 116 call the same function, so
 * the backend and the database cannot disagree about what a suspension blocks.
 *
 * CACHING
 * -------
 * A short positive-and-negative cache (15 s) keeps the check off the hot path
 * for a user tapping through a flow. It is not a correctness risk in either
 * direction that matters: moderation actions taken through THIS process
 * invalidate the account's entries immediately (`invalidate`), so the common
 * case — an admin bans someone — takes effect on the next request. Only a
 * restriction applied from somewhere else (SQL editor, a second instance)
 * waits out the TTL.
 *
 * FAILING OPEN, DELIBERATELY
 * --------------------------
 * If the check cannot be answered — Supabase unreachable, migrations not yet
 * applied — the request is ALLOWED and the failure is logged at ERROR. The
 * alternative turns a database blip into "nobody can hire or pay" for the whole
 * marketplace, which is a worse failure than a restricted account slipping one
 * action through during an outage. It matches how the platform's kill switches
 * already fail (open), and the database triggers are a second, independent
 * layer for the direct-write paths.
 */
@Injectable()
export class AccountStateService implements OnModuleInit {
  private readonly logger = new Logger(AccountStateService.name);

  static readonly TTL_MS = 15_000;
  static readonly MAX_ENTRIES = 5_000;
  private static readonly FAILURE_LOG_INTERVAL_MS = 60_000;

  private readonly cache = new Map<string, { value: Denial | null; expiresAt: number }>();
  private lastFailureLogAt = 0;

  /** Set by the boot self-check; exposed so /health-style probes can read it. */
  private schemaPresent: boolean | null = null;

  constructor(private readonly supabase: SupabaseService) {}

  async onModuleInit(): Promise<void> {
    try {
      const { error } = await this.supabase.client.rpc('moderation_denial', {
        p_user_id: '__moderation_selfcheck__',
        p_capability: 'post',
      });
      this.schemaPresent = !error;
      if (error) {
        this.logger.error(
          `[MODERATION_SELFCHECK] ✗ moderation_denial() is not callable (${error.code ?? '?'}: ${error.message}). ` +
            `Account restrictions are NOT enforced by the backend until migrations 114–116 are applied. ` +
            `Requests fail open.`,
        );
      } else {
        this.logger.log('[MODERATION_SELFCHECK] ✓ moderation schema present — account restrictions enforced.');
      }
    } catch (e) {
      this.schemaPresent = false;
      this.logger.error(`[MODERATION_SELFCHECK] crashed: ${(e as Error).message}`);
    }
  }

  get enforcementAvailable(): boolean | null {
    return this.schemaPresent;
  }

  /** Why `userId` may not exercise `capability`, or null when it may. */
  async denial(userId: string, capability: Capability): Promise<Denial | null> {
    const key = `${userId}\u0000${capability}`;
    const now = Date.now();
    const hit = this.cache.get(key);
    if (hit && hit.expiresAt > now) return hit.value;

    let value: Denial | null;
    try {
      const { data, error } = await this.supabase.client.rpc('moderation_denial', {
        p_user_id: userId,
        p_capability: capability,
      });
      if (error) {
        this.reportFailure(`${error.code ?? '?'}: ${error.message}`, userId, capability);
        return null;
      }
      value = (DENIALS as readonly string[]).includes(data as string) ? (data as Denial) : null;
    } catch (e) {
      this.reportFailure((e as Error).message, userId, capability);
      return null;
    }

    if (this.cache.size >= AccountStateService.MAX_ENTRIES) this.cache.clear();
    this.cache.set(key, { value, expiresAt: now + AccountStateService.TTL_MS });
    return value;
  }

  /** Forget everything cached about an account — called after every action. */
  invalidate(userId: string): void {
    const prefix = `${userId}\u0000`;
    for (const key of this.cache.keys()) {
      if (key.startsWith(prefix)) this.cache.delete(key);
    }
  }

  private reportFailure(detail: string, userId: string, capability: Capability): void {
    const now = Date.now();
    if (now - this.lastFailureLogAt < AccountStateService.FAILURE_LOG_INTERVAL_MS) return;
    this.lastFailureLogAt = now;
    this.logger.error(
      `[MODERATION][CHECK_UNAVAILABLE] could not check ${capability} for ${userId} — ${detail}. ` +
        `Allowing (fail-open). Further failures suppressed for 60s.`,
    );
  }
}
