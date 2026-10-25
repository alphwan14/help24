import {
  ForbiddenException,
  NotFoundException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAuthService } from './admin-auth.service';

/**
 * restoreSession is the backend half of the admin gate. These tests pin that it
 * asks the SAME question as the dashboard middleware — credential → link →
 * person → role — and that nothing else, above all a matching email, can stand
 * in for the link. Every denial must also leave admin_users untouched: a token
 * minted on the way to a 403 would still be a working bearer.
 */

type Rows = Record<string, Array<Record<string, unknown>>>;
type Failures = Partial<Record<string, string>>;

const SUBJECT = '0b5c8d2e-4f1a-4c3b-9d7e-1a2b3c4d5e6f';
const HELP24_ID = 'FirebaseUidAbcdefghijklmnop12';
const DASHBOARD_EMAIL = 'staff.login@example.com';

/** The PostgREST chains restoreSession and reissueTokenForAdmin use, over in-memory rows. */
function fakeSupabase(rows: Rows, opts: { user?: { id?: string; email?: string } | null; fail?: Failures } = {}) {
  const updates: Array<{ table: string; patch: Record<string, unknown>; id: unknown }> = [];
  const lookups: string[] = [];

  const client = {
    auth: {
      getUser: async (_jwt: string) =>
        opts.user
          ? { data: { user: opts.user }, error: null }
          : { data: { user: null }, error: { message: 'invalid JWT' } },
    },
    from(table: string) {
      const filters: Array<[string, unknown]> = [];
      const builder = {
        select: (_cols: string) => builder,
        eq: (col: string, val: unknown) => {
          filters.push([col, val]);
          return builder;
        },
        maybeSingle: async () => {
          lookups.push(`${table}?${filters.map(([c, v]) => `${c}=${String(v)}`).join('&')}`);
          if (opts.fail?.[table]) return { data: null, error: { message: opts.fail[table] } };
          const hit = (rows[table] ?? []).find((r) => filters.every(([c, v]) => r[c] === v));
          return { data: hit ?? null, error: null };
        },
        update: (patch: Record<string, unknown>) => ({
          eq: async (_col: string, id: unknown) => {
            updates.push({ table, patch, id });
            return { error: null };
          },
        }),
      };
      return builder;
    },
  };

  return { service: { client } as unknown as SupabaseService, updates, lookups };
}

function makeService(supabase: SupabaseService) {
  return new AdminAuthService(supabase, { get: () => undefined } as unknown as ConfigService);
}

/** A linked admin whose dashboard login uses a different address from their app account. */
function linkedAdminRows(overrides: Partial<Rows> = {}): Rows {
  return {
    user_auth_identities: [{ provider: 'supabase', subject: SUBJECT, help24_user_id: HELP24_ID }],
    users: [{ id: HELP24_ID, email: 'app.account@example.org', role: 'admin' }],
    admin_users: [{ id: 'adm-1', email: DASHBOARD_EMAIL, name: 'Staff', role: 'super_admin', active: true }],
    ...overrides,
  };
}

const user = { id: SUBJECT, email: DASHBOARD_EMAIL };

describe('AdminAuthService.restoreSession — the backend admin gate', () => {
  it('grants a linked admin even when their dashboard email has no users row', async () => {
    const fake = fakeSupabase(linkedAdminRows(), { user });
    const result = await makeService(fake.service).restoreSession('jwt');

    expect(result).toMatchObject({ email: DASHBOARD_EMAIL, role: 'super_admin' });
    expect(result.token).toEqual(expect.any(String));
    expect(fake.updates).toHaveLength(1); // the rotated token hash
    expect(fake.lookups[0]).toBe(`user_auth_identities?provider=supabase&subject=${SUBJECT}`);
    expect(fake.lookups[1]).toBe(`users?id=${HELP24_ID}`);
  });

  it('denies an UNLINKED login even if its email matches an admin users row', async () => {
    // The old email gate would have granted this. The link is the only proof.
    const rows = linkedAdminRows({
      user_auth_identities: [],
      users: [{ id: HELP24_ID, email: DASHBOARD_EMAIL, role: 'admin' }],
    });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
    expect(fake.lookups.some((l) => l.startsWith('users?email'))).toBe(false);
  });

  it('denies a login linked to someone who is not an admin', async () => {
    const rows = linkedAdminRows({ users: [{ id: HELP24_ID, email: 'x@example.org', role: 'user' }] });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
  });

  it('denies a link that points at a person who no longer exists', async () => {
    const fake = fakeSupabase(linkedAdminRows({ users: [] }), { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
  });

  it('only matches the supabase provider — a firebase link with the same subject is not a dashboard link', async () => {
    const rows = linkedAdminRows({
      user_auth_identities: [{ provider: 'firebase', subject: SUBJECT, help24_user_id: HELP24_ID }],
    });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('refuses an unverifiable session without touching the database', async () => {
    const fake = fakeSupabase(linkedAdminRows(), { user: null });

    await expect(makeService(fake.service).restoreSession('forged')).rejects.toBeInstanceOf(UnauthorizedException);
    expect(fake.lookups).toHaveLength(0);
    expect(fake.updates).toHaveLength(0);
  });

  it('refuses a verified session that carries no email', async () => {
    const fake = fakeSupabase(linkedAdminRows(), { user: { id: SUBJECT } });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it.each(['user_auth_identities', 'users'])(
    'a failed %s lookup is a 503 and mints nothing — never mistaken for "not an admin"',
    async (table) => {
      const fake = fakeSupabase(linkedAdminRows(), { user, fail: { [table]: 'connection reset' } });

      await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(
        ServiceUnavailableException,
      );
      expect(fake.updates).toHaveLength(0);
    },
  );

  it('a linked admin with an INACTIVE arbitration record is refused', async () => {
    const rows = linkedAdminRows({
      admin_users: [{ id: 'adm-1', email: DASHBOARD_EMAIL, name: 'Staff', role: 'super_admin', active: false }],
    });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
  });

  it('a linked admin with NO arbitration record is a 404, not a grant', async () => {
    const fake = fakeSupabase(linkedAdminRows({ admin_users: [] }), { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(NotFoundException);
    expect(fake.updates).toHaveLength(0);
  });
});
