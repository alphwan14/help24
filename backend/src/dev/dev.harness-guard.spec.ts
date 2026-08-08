import 'reflect-metadata';
import { ForbiddenException, Logger } from '@nestjs/common';

import { DevController } from './dev.controller';
import { DevService } from './dev.service';
import { AUTH_SPEC_KEY, type AuthSpec } from '../common/auth/auth.decorator';

/**
 * The dev harness was reachable UNAUTHENTICATED on the production deploy.
 *
 * Two independent controls were supposed to stop it and both were off:
 *   1. `guardDev()` keyed on `MPESA_ENV !== 'production'`, and production runs
 *      `MPESA_ENV=sandbox` because the Daraja cutover has not happened.
 *   2. `@Auth()` ran in MONITOR mode, because `AUTH_ENFORCE_ONLY=/promotions`
 *      narrows enforcement to that one prefix.
 *
 * Evidence: `POST /dev/test-fcm` → 200 with `authWouldDeny:"absent"` and
 * `enforcing=false` (requestId 1f81cc3d-4e2b-441f-a9cb-274fe214e5bd,
 * 2026-08-08T07:41:14Z, ua="curl/8.21.0"). These routes wipe transactions and
 * inject arbitrary canonical events.
 *
 * These tests pin BOTH layers so neither can silently regress.
 */
describe('dev harness — production exposure regression (§C2)', () => {
  const ORIGINAL_ENV = { ...process.env };

  afterEach(() => {
    process.env = { ...ORIGINAL_ENV };
    jest.restoreAllMocks();
  });

  // ── Layer 1: the environment guard ────────────────────────────────────────

  describe('guardDev is default-closed and independent of MPESA_ENV', () => {
    /** Build a service whose collaborators would throw if ever reached. */
    function service(): DevService {
      const unreachable = new Proxy(
        {},
        {
          get() {
            throw new Error('guardDev let the call through — collaborator was reached');
          },
        },
      );
      return new DevService(
        unreachable as never,
        unreachable as never,
        unreachable as never,
        unreachable as never,
      );
    }

    beforeEach(() => {
      jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
      jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    });

    it('THE BUG: MPESA_ENV=sandbox no longer opens the harness', async () => {
      process.env.MPESA_ENV = 'sandbox';
      delete process.env.DEV_ROUTES_ENABLED;
      await expect(service().testFcm('any-uid')).rejects.toBeInstanceOf(ForbiddenException);
    });

    it('refuses when DEV_ROUTES_ENABLED is unset (default-closed)', async () => {
      delete process.env.DEV_ROUTES_ENABLED;
      await expect(service().resetState('post-1')).rejects.toBeInstanceOf(ForbiddenException);
    });

    it.each(['false', '', 'TRUE', '1', 'yes'])(
      'refuses for DEV_ROUTES_ENABLED=%p — only the exact string "true" opens it',
      async (value) => {
        process.env.DEV_ROUTES_ENABLED = value;
        await expect(service().testFcm('any-uid')).rejects.toBeInstanceOf(ForbiddenException);
      },
    );

    it('refuses trigger-event too — every entry point is guarded', async () => {
      delete process.env.DEV_ROUTES_ENABLED;
      await expect(
        service().triggerEvent('payment.success', 'post-1', {}),
      ).rejects.toBeInstanceOf(ForbiddenException);
    });

    it('MPESA_ENV=production alone does not matter either way', async () => {
      // The two settings are now genuinely unrelated, which was the point.
      process.env.MPESA_ENV = 'production';
      delete process.env.DEV_ROUTES_ENABLED;
      await expect(service().testFcm('any-uid')).rejects.toBeInstanceOf(ForbiddenException);
    });
  });

  // ── Layer 2: the auth declaration ─────────────────────────────────────────

  describe('the controller is declared @AuthCritical', () => {
    it('carries an auth spec with critical:true, so monitor mode cannot let it through', () => {
      const spec = Reflect.getMetadata(AUTH_SPEC_KEY, DevController) as AuthSpec | undefined;

      expect(spec).toBeDefined();
      expect(spec!.scheme).toBe('firebase');
      // The whole finding in one assertion: a plain @Auth route degrades to
      // monitor behaviour under AUTH_ENFORCE_ONLY, which is how an anonymous
      // curl reached this controller in production.
      expect(spec!.critical).toBe(true);
    });
  });
});
