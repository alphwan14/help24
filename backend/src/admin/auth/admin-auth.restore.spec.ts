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

/** The PostgREST chains restoreSession, reissueTokenForAdmin and authenticate use, over in-memory rows. */
function fakeSupabase(
  rows: Rows,
  opts: { user?: { id?: string; email?: string } | null; fail?: Failures; missing?: string[] } = {},
) {
  const updates: Array<{ table: string; patch: Record<string, unknown>; id: unknown }> = [];
  const inserts: Array<{ table: string; row: Record<string, unknown> }> = [];
  const deletes: Array<{ table: string; filter: string }> = [];
  const lookups: string[] = [];
  const missing = (table: string) =>
    opts.missing?.includes(table) ? { code: 'PGRST205', message: `Could not find the table 'public.${table}'` } : null;

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
          const absent = missing(table);
          if (absent) return { data: null, error: absent };
          if (opts.fail?.[table]) return { data: null, error: { message: opts.fail[table] } };
          const hit = (rows[table] ?? []).find((r) => filters.every(([c, v]) => r[c] === v));
          return { data: hit ?? null, error: null };
        },
        update: (patch: Record<string, unknown>) => ({
          eq: async (_col: string, id: unknown) => {
            updates.push({ table, patch, id });
            const row = (rows[table] ?? []).find((r) => r.id === id);
            if (row) Object.assign(row, patch);
            return { error: null };
          },
        }),
        insert: async (row: Record<string, unknown>) => {
          const absent = missing(table);
          if (absent) return { error: absent };
          inserts.push({ table, row });
          (rows[table] ??= []).push({ ...row });
          return { error: null };
        },
        delete: () => {
          const settle = (filter: string) => {
            const absent = missing(table);
            if (!absent) deletes.push({ table, filter });
            return Promise.resolve({ error: absent });
          };
          return {
            eq: (col: string, val: unknown) => settle(`${col}=${String(val)}`),
            lt: (col: string, val: unknown) => settle(`${col}<${String(val)}`),
          };
        },
      };
      return builder;
    },
  };

  return { service: { client } as unknown as SupabaseService, updates, inserts, deletes, lookups };
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
    expect(fake.inserts).toHaveLength(0);
    expect(fake.lookups.some((l) => l.startsWith('users?email'))).toBe(false);
  });

  it('denies a login linked to someone who is not an admin', async () => {
    const rows = linkedAdminRows({ users: [{ id: HELP24_ID, email: 'x@example.org', role: 'user' }] });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
    expect(fake.inserts).toHaveLength(0);
  });

  it('denies a link that points at a person who no longer exists', async () => {
    const fake = fakeSupabase(linkedAdminRows({ users: [] }), { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
    expect(fake.inserts).toHaveLength(0);
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
    expect(fake.inserts).toHaveLength(0);
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
      expect(fake.inserts).toHaveLength(0);
    expect(fake.inserts).toHaveLength(0);
    },
  );

  it('a linked admin with an INACTIVE arbitration record is refused', async () => {
    const rows = linkedAdminRows({
      admin_users: [{ id: 'adm-1', email: DASHBOARD_EMAIL, name: 'Staff', role: 'super_admin', active: false }],
    });
    const fake = fakeSupabase(rows, { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(ForbiddenException);
    expect(fake.updates).toHaveLength(0);
    expect(fake.inserts).toHaveLength(0);
  });

  it('a linked admin with NO arbitration record is a 404, not a grant', async () => {
    const fake = fakeSupabase(linkedAdminRows({ admin_users: [] }), { user });

    await expect(makeService(fake.service).restoreSession('jwt')).rejects.toBeInstanceOf(NotFoundException);
    expect(fake.updates).toHaveLength(0);
    expect(fake.inserts).toHaveLength(0);
  });
});

/**
 * Migration 133: one console key per sign-in. The bug it ends: every restore
 * overwrote the admin's single key, so a phone and a laptop retired each
 * other's and the one left behind got "Invalid admin token." on every call.
 */
describe('AdminAuthService — a console key per sign-in (migration 133)', () => {
  const hash = (t: string) => AdminAuthService.hashToken(t);
  const withSessions = () => linkedAdminRows({ admin_sessions: [] });

  it('a restore records its own key and retires the admin row key nobody should hold', async () => {
    const fake = fakeSupabase(withSessions(), { user });
    const before = Date.now();
    const { token } = await makeService(fake.service).restoreSession('jwt');

    expect(fake.inserts).toHaveLength(1);
    const row = fake.inserts[0].row;
    expect(row).toMatchObject({ token_hash: hash(token), admin_id: 'adm-1' });
    const ttl = new Date(row.expires_at as string).getTime() - before;
    expect(ttl).toBeGreaterThan(11.9 * 3600_000);
    expect(ttl).toBeLessThanOrEqual(12 * 3600_000 + 1000);

    expect(fake.updates).toHaveLength(1);
    expect(fake.updates[0].patch.token_hash).not.toBe(hash(token));
    expect(fake.updates[0].patch.token_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('two devices restoring both keep working', async () => {
    const fake = fakeSupabase(withSessions(), { user });
    const service = makeService(fake.service);
    const phone = await service.restoreSession('jwt');
    const laptop = await service.restoreSession('jwt');

    expect(phone.token).not.toBe(laptop.token);
    await expect(service.authenticate(phone.token)).resolves.toMatchObject({ ok: true, admin: { id: 'adm-1' } });
    await expect(service.authenticate(laptop.token)).resolves.toMatchObject({ ok: true, admin: { id: 'adm-1' } });
  });

  it('the admin row is read fresh on every request — a disabled admin\'s key stops at once', async () => {
    const rows = withSessions();
    const fake = fakeSupabase(rows, { user });
    const service = makeService(fake.service);
    const { token } = await service.restoreSession('jwt');

    rows.admin_users[0].active = false;
    await expect(service.authenticate(token)).resolves.toMatchObject({ ok: false, reason: 'inactive' });
  });

  it('an expired key is unknown, not an error', async () => {
    const rows = withSessions();
    rows.admin_sessions.push({
      token_hash: hash('old-key'),
      admin_id: 'adm-1',
      expires_at: new Date(Date.now() - 1000).toISOString(),
    });
    const fake = fakeSupabase(rows);

    await expect(makeService(fake.service).authenticate('old-key')).resolves.toMatchObject({
      ok: false,
      reason: 'not_found',
    });
  });

  it('a failed key lookup is a backend error, never a bad token', async () => {
    const fake = fakeSupabase(withSessions(), { fail: { admin_sessions: 'connection reset' } });

    await expect(makeService(fake.service).authenticate('any')).resolves.toMatchObject({
      ok: false,
      reason: 'db_error',
    });
  });

  it('the admin row key still works — an invitation just accepted holds one', async () => {
    const rows = withSessions();
    rows.admin_users[0].token_hash = hash('invite-key');
    const fake = fakeSupabase(rows);

    await expect(makeService(fake.service).authenticate('invite-key')).resolves.toMatchObject({
      ok: true,
      admin: { email: DASHBOARD_EMAIL },
    });
  });

  it('before 133 is applied it falls back to the single rotating key', async () => {
    const fake = fakeSupabase(linkedAdminRows(), { user, missing: ['admin_sessions'] });
    const service = makeService(fake.service);
    const first = await service.restoreSession('jwt');

    expect(fake.inserts).toHaveLength(0);
    expect(fake.updates[0].patch.token_hash).toBe(hash(first.token));
    await expect(service.authenticate(first.token)).resolves.toMatchObject({ ok: true });

    const second = await service.restoreSession('jwt');
    await expect(service.authenticate(second.token)).resolves.toMatchObject({ ok: true });
    await expect(service.authenticate(first.token)).resolves.toMatchObject({ ok: false, reason: 'not_found' });
  });

  it('disabling an admin removes their keys, so re-enabling them revives no device', async () => {
    const rows = withSessions();
    rows.admin_users.push({ id: 'adm-2', email: 'agent@example.com', name: 'Agent', role: 'support_agent', active: true });
    const fake = fakeSupabase(rows);

    await makeService(fake.service).deactivateAdmin('adm-2', 'adm-1');
    expect(fake.updates).toEqual([{ table: 'admin_users', patch: { active: false }, id: 'adm-2' }]);
    expect(fake.deletes).toEqual([{ table: 'admin_sessions', filter: 'admin_id=adm-2' }]);
  });
});

describe('AdminAuthService.reactivateAdmin', () => {
  it('turns a deactivated admin back on, and nothing else', async () => {
    const rows = linkedAdminRows();
    rows.admin_users[0].active = false;
    const fake = fakeSupabase(rows);

    await expect(makeService(fake.service).reactivateAdmin('adm-1')).resolves.toEqual({ id: 'adm-1', active: true });
    expect(fake.updates).toEqual([{ table: 'admin_users', patch: { active: true }, id: 'adm-1' }]);
    expect(fake.inserts).toHaveLength(0);
  });

  it('an admin who is already active is left alone', async () => {
    const fake = fakeSupabase(linkedAdminRows());

    await makeService(fake.service).reactivateAdmin('adm-1');
    expect(fake.updates).toHaveLength(0);
  });

  it('an unknown id is a 404', async () => {
    const fake = fakeSupabase(linkedAdminRows());

    await expect(makeService(fake.service).reactivateAdmin('adm-x')).rejects.toBeInstanceOf(NotFoundException);
  });

  it('a reactivated admin still has to sign in again — keys deleted on deactivation stay gone', async () => {
    const rows = linkedAdminRows({ admin_sessions: [] });
    rows.admin_users[0].role = 'support_agent'; // past the last-super-admin guard
    const fake = fakeSupabase(rows, { user });
    const service = makeService(fake.service);
    const { token } = await service.restoreSession('jwt');

    rows.admin_users.push({ id: 'adm-2', email: 'other@example.com', name: 'O', role: 'super_admin', active: true });
    await service.deactivateAdmin('adm-1', 'adm-2');
    rows.admin_sessions = rows.admin_sessions.filter((s) => s.admin_id !== 'adm-1'); // the fake's delete only records
    await service.reactivateAdmin('adm-1');

    await expect(service.authenticate(token)).resolves.toMatchObject({ ok: false, reason: 'not_found' });
  });
});
