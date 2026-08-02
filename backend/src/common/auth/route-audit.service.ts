import { Inject, Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { GUARDS_METADATA, METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { RequestMethod } from '@nestjs/common';
import { DiscoveryService } from '@nestjs/core';
import { AUTH_SPEC_KEY, AuthSpec } from './auth.decorator';
import { AuthConfig } from './auth.config';
import { AUTH_CONFIG } from './auth.tokens';

/**
 * Walks every registered route at boot and reports its authentication posture.
 *
 * WHY THIS EXISTS
 * ---------------
 * `/admin/events` shipped to production carrying `@RateLimit('admin:api')` and
 * no guard whatsoever. `GET /admin/events` listed every event in the system
 * with its payload; `POST /admin/events/replay` re-ran arbitrary event handlers,
 * including the one that releases an M-Pesa payout. Every other admin
 * controller had `@UseGuards(AdminAuthGuard)`, so the omission was a single
 * missing line in a file that otherwise looked exactly like its neighbours —
 * invisible to review, and invisible at runtime because the endpoint worked
 * perfectly.
 *
 * No amount of care prevents that class of mistake; only a machine that reads
 * every route on every boot does. This is that machine.
 *
 * WHAT IT CHECKS
 * --------------
 *   1. Every route declares a scheme. An undeclared route is one nobody
 *      classified, which is how endpoints end up unprotected by default.
 *   2. A route declaring `@AdminAuth()` really is behind AdminAuthGuard. The
 *      decorator is a DECLARATION; the guard is the ENFORCEMENT. When they
 *      disagree, the declaration is a lie and the route is open.
 *   3. Nothing under `/admin` is quietly non-admin. A path prefix carries an
 *      expectation, and `@Public()` there must be a deliberate, stated choice
 *      (invite acceptance and session restore legitimately are).
 *
 * WHEN IT FAILS THE BOOT
 * ----------------------
 * Findings are loud errors in `off`/`monitor` and FATAL in `enforce`. That
 * asymmetry is the point: during migration a warning must not block a deploy,
 * but nobody should be able to switch enforcement on while the route topology
 * still contains a hole — which would produce a system that looks locked down
 * and is not.
 */
@Injectable()
export class RouteAuditService implements OnApplicationBootstrap {
  private readonly logger = new Logger('AuthRouteAudit');

  constructor(
    private readonly discovery: DiscoveryService,
    @Inject(AUTH_CONFIG) private readonly config: AuthConfig,
  ) {}

  onApplicationBootstrap(): void {
    const routes = this.collect();
    const findings = audit(routes);

    this.report(routes, findings);

    if (findings.length > 0 && this.config.mode === 'enforce') {
      throw new Error(
        `[Auth] Route audit found ${findings.length} problem(s) and ` +
          `AUTH_ENFORCEMENT=enforce. Refusing to start: enforcement must not be ` +
          `switched on over an incomplete auth topology. Fix the routes listed above, ` +
          `or set AUTH_ENFORCEMENT=monitor while they are addressed.`,
      );
    }
  }

  /** Every controller route, with the scheme it declares and the guards on it. */
  collect(): RouteRecord[] {
    const records: RouteRecord[] = [];

    for (const wrapper of this.discovery.getControllers()) {
      const { instance, metatype } = wrapper;
      if (!instance || !metatype) continue;

      const controllerPath = normalisePath(
        Reflect.getMetadata(PATH_METADATA, metatype) as string | string[] | undefined,
      );
      const classSpec = Reflect.getMetadata(AUTH_SPEC_KEY, metatype) as AuthSpec | undefined;
      const classGuards = guardNames(Reflect.getMetadata(GUARDS_METADATA, metatype));

      const prototype = Object.getPrototypeOf(instance) as object;
      for (const name of Object.getOwnPropertyNames(prototype)) {
        if (name === 'constructor') continue;
        const handler = (prototype as Record<string, unknown>)[name];
        if (typeof handler !== 'function') continue;

        const methodPath = Reflect.getMetadata(PATH_METADATA, handler) as string | undefined;
        if (methodPath === undefined) continue; // not a route handler

        const verb = Reflect.getMetadata(METHOD_METADATA, handler) as RequestMethod | undefined;
        const methodSpec = Reflect.getMetadata(AUTH_SPEC_KEY, handler) as AuthSpec | undefined;
        const methodGuards = guardNames(Reflect.getMetadata(GUARDS_METADATA, handler));

        records.push({
          controller: metatype.name,
          handler: name,
          method: verbName(verb),
          path: joinPath(controllerPath, methodPath),
          spec: methodSpec ?? classSpec,
          declaredAt: methodSpec ? 'method' : classSpec ? 'class' : 'none',
          guards: [...classGuards, ...methodGuards],
        });
      }
    }

    return records.sort((a, b) => a.path.localeCompare(b.path) || a.method.localeCompare(b.method));
  }

  private report(routes: RouteRecord[], findings: Finding[]): void {
    const counts = { firebase: 0, admin: 0, public: 0, undeclared: 0 };
    for (const route of routes) {
      if (!route.spec) counts.undeclared++;
      else counts[route.spec.scheme]++;
    }

    this.logger.log(
      `[AUTH][ROUTES] ${routes.length} routes — firebase=${counts.firebase} ` +
        `admin=${counts.admin} public=${counts.public} undeclared=${counts.undeclared} ` +
        `(mode=${this.config.mode})`,
    );

    // The public surface is printed in full, every boot. It is the list most
    // worth re-reading after any change, and the reasons are why `@Public`
    // requires one.
    for (const route of routes.filter((r) => r.spec?.scheme === 'public')) {
      this.logger.log(
        `[AUTH][ROUTES]   PUBLIC  ${route.method.padEnd(6)} ${route.path} — ${route.spec?.reason}`,
      );
    }

    for (const finding of findings) {
      this.logger.error(`[AUTH][ROUTES]   ✗ ${finding.severity} ${finding.route}: ${finding.message}`);
    }

    if (findings.length === 0) {
      this.logger.log('[AUTH][ROUTES] Every route declares a scheme and every admin route is guarded.');
    }
  }
}

export interface RouteRecord {
  readonly controller: string;
  readonly handler: string;
  readonly method: string;
  readonly path: string;
  readonly spec?: AuthSpec;
  readonly declaredAt: 'method' | 'class' | 'none';
  readonly guards: readonly string[];
}

export interface Finding {
  readonly severity: 'UNDECLARED' | 'UNGUARDED_ADMIN' | 'ADMIN_PATH_NOT_ADMIN';
  readonly route: string;
  readonly message: string;
}

/**
 * The audit rules, as a pure function of the collected routes.
 *
 * Separated from the service so the whole check is unit-testable against
 * synthetic route tables — including the exact `/admin/events` shape that
 * motivated it, which is asserted in route-audit.spec.ts.
 */
export function audit(routes: readonly RouteRecord[]): Finding[] {
  const findings: Finding[] = [];

  for (const route of routes) {
    const label = `${route.method} ${route.path} (${route.controller}.${route.handler})`;

    if (!route.spec) {
      findings.push({
        severity: 'UNDECLARED',
        route: label,
        message:
          'declares no auth scheme. Add @Auth(...), @Public(\'reason\') or @AdminAuth().',
      });
      continue;
    }

    if (route.spec.scheme === 'admin' && !route.guards.includes('AdminAuthGuard')) {
      findings.push({
        severity: 'UNGUARDED_ADMIN',
        route: label,
        message:
          '@AdminAuth() is declared but AdminAuthGuard is NOT applied — the route is OPEN. ' +
          'Add @UseGuards(AdminAuthGuard) to the controller.',
      });
      continue;
    }

    if (
      route.path.startsWith('/admin') &&
      route.spec.scheme !== 'admin' &&
      route.spec.scheme !== 'public'
    ) {
      findings.push({
        severity: 'ADMIN_PATH_NOT_ADMIN',
        route: label,
        message:
          `is under /admin but declares scheme "${route.spec.scheme}". Admin paths must use ` +
          '@AdminAuth(), or @Public() with a reason if genuinely unauthenticated.',
      });
    }
  }

  return findings;
}

function guardNames(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((guard) => {
      if (typeof guard === 'function') return guard.name;
      const ctor = (guard as { constructor?: { name?: string } })?.constructor;
      return ctor?.name ?? '';
    })
    .filter(Boolean);
}

function normalisePath(value: string | string[] | undefined): string {
  if (Array.isArray(value)) return value[0] ?? '';
  return value ?? '';
}

function joinPath(controllerPath: string, methodPath: string): string {
  const segments = [controllerPath, methodPath]
    .map((s) => s.replace(/^\/+|\/+$/g, ''))
    .filter((s) => s !== '');
  return `/${segments.join('/')}`;
}

function verbName(method: RequestMethod | undefined): string {
  switch (method) {
    case RequestMethod.GET: return 'GET';
    case RequestMethod.POST: return 'POST';
    case RequestMethod.PUT: return 'PUT';
    case RequestMethod.DELETE: return 'DELETE';
    case RequestMethod.PATCH: return 'PATCH';
    case RequestMethod.OPTIONS: return 'OPTIONS';
    case RequestMethod.HEAD: return 'HEAD';
    case RequestMethod.ALL: return 'ALL';
    default: return 'GET';
  }
}
