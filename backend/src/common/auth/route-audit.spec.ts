import { audit, RouteRecord } from './route-audit.service';
import { AuthSpec } from './auth.decorator';

function route(overrides: Partial<RouteRecord> = {}): RouteRecord {
  return {
    controller: 'SomeController',
    handler: 'someHandler',
    method: 'GET',
    path: '/some/path',
    declaredAt: 'class',
    guards: [],
    ...overrides,
  };
}

const firebase: AuthSpec = { scheme: 'firebase', bindings: [] };
const admin: AuthSpec = { scheme: 'admin', bindings: [] };
const publicSpec: AuthSpec = { scheme: 'public', bindings: [], reason: 'because' };

describe('route audit', () => {
  it('passes a correctly declared route table', () => {
    expect(
      audit([
        route({ path: '/feed', spec: publicSpec }),
        route({ path: '/jobs/approve', method: 'POST', spec: firebase }),
        route({ path: '/admin/disputes', spec: admin, guards: ['AdminAuthGuard'] }),
      ]),
    ).toEqual([]);
  });

  it('flags a route that declares no scheme', () => {
    const findings = audit([route({ path: '/new/thing', spec: undefined })]);
    expect(findings).toHaveLength(1);
    expect(findings[0].severity).toBe('UNDECLARED');
  });

  describe('the /admin/events regression', () => {
    // THIS IS THE TEST THAT PAYS FOR THE WHOLE AUDIT.
    //
    // EventsAdminController shipped to production with @RateLimit('admin:api')
    // and no @UseGuards(AdminAuthGuard). GET /admin/events returned the entire
    // event log with payloads; POST /admin/events/replay re-ran arbitrary event
    // handlers, including the one that initiates an M-Pesa B2C payout. Every
    // sibling controller was guarded, so the omission was one missing line in a
    // file that looked exactly like its neighbours — and nothing failed at
    // runtime, because the endpoint worked perfectly.
    it('catches @AdminAuth() declared without AdminAuthGuard applied', () => {
      const findings = audit([
        route({
          controller: 'EventsAdminController',
          handler: 'replay',
          method: 'POST',
          path: '/admin/events/replay',
          spec: admin,
          guards: [], // ← the bug, exactly as it shipped
        }),
      ]);

      expect(findings).toHaveLength(1);
      expect(findings[0].severity).toBe('UNGUARDED_ADMIN');
      expect(findings[0].message).toMatch(/the route is OPEN/);
    });

    it('accepts the same route once the guard is applied', () => {
      expect(
        audit([
          route({
            controller: 'EventsAdminController',
            method: 'POST',
            path: '/admin/events/replay',
            spec: admin,
            guards: ['AdminAuthGuard'],
          }),
        ]),
      ).toEqual([]);
    });

    it('would ALSO have caught it as undeclared, before anyone added @AdminAuth', () => {
      // Two independent nets: forgetting the guard is caught by the first rule,
      // forgetting the declaration by this one. The bug had to pass both.
      const findings = audit([
        route({ path: '/admin/events', spec: undefined, guards: [] }),
      ]);
      expect(findings[0].severity).toBe('UNDECLARED');
    });
  });

  it('rejects a firebase-scheme route under /admin', () => {
    // The /admin prefix carries an expectation. A Firebase token is not an
    // admin credential, and a route that accepts one under this prefix is
    // almost certainly a mistake.
    const findings = audit([route({ path: '/admin/secret', spec: firebase })]);
    expect(findings).toHaveLength(1);
    expect(findings[0].severity).toBe('ADMIN_PATH_NOT_ADMIN');
  });

  it('allows a deliberately public route under /admin', () => {
    // Invite acceptance and session restore are the bootstrap paradox: they are
    // how an admin OBTAINS a token, so they cannot require one.
    expect(audit([route({ path: '/admin/accept-invite', method: 'POST', spec: publicSpec })])).toEqual([]);
  });

  it('reports every problem, not just the first', () => {
    const findings = audit([
      route({ path: '/a', spec: undefined }),
      route({ path: '/admin/b', spec: admin, guards: [] }),
      route({ path: '/admin/c', spec: firebase }),
    ]);
    expect(findings.map((f) => f.severity)).toEqual([
      'UNDECLARED',
      'UNGUARDED_ADMIN',
      'ADMIN_PATH_NOT_ADMIN',
    ]);
  });
});
