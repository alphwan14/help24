import {
  ConflictException,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAuthService } from './admin-auth.service';
import { AdminIdentityLinksService } from './admin-identity-links.service';
import { AdminInvitesService } from './admin-invites.service';

/**
 * Invitations that name their person (migration 122). These pin that the
 * super admin's choice is what links the login — never an email match — and
 * that a link or promotion that fails leaves the invitation UNCONSUMED, so the
 * invitee can retry instead of being left half-provisioned.
 */

type Row = Record<string, unknown>;
const AUTH_ID = '0b5c8d2e-4f1a-4c3b-9d7e-1a2b3c4d5e6f';
const PERSON = 'FirebaseUidAbcdefghijklmnop12';

/** In-memory PostgREST chains: eq / in / lt filters, select / update / insert. */
function fakeDb(tables: Record<string, Row[]>, failures: Record<string, boolean> = {}) {
  const log: Array<{ table: string; op: string; patch?: Row }> = [];
  const from = (table: string) => {
    const filters: Array<[string, string, unknown]> = [];
    let op = 'select';
    let patch: Row | undefined;
    const match = (r: Row) =>
      filters.every(([kind, col, v]) =>
        kind === 'eq' ? r[col] === v : kind === 'in' ? (v as unknown[]).includes(r[col]) : kind === 'lt' ? String(r[col]) < String(v) : true,
      );
    const exec = async () => {
      log.push({ table, op, patch });
      if (failures[`${table}.${op}`]) return { data: null, error: { message: 'boom' } };
      const rows = (tables[table] ??= []);
      if (op === 'update') {
        rows.filter(match).forEach((r) => Object.assign(r, patch));
        return { data: null, error: null };
      }
      if (op === 'insert') {
        rows.push({ ...patch });
        return { data: null, error: null };
      }
      return { data: rows.filter(match), error: null };
    };
    const b: Record<string, unknown> = {
      select: () => b,
      eq: (c: string, v: unknown) => (filters.push(['eq', c, v]), b),
      in: (c: string, v: unknown) => (filters.push(['in', c, v]), b),
      lt: (c: string, v: unknown) => (filters.push(['lt', c, v]), b),
      update: (p: Row) => ((op = 'update'), (patch = p), b),
      insert: (p: Row) => ((op = 'insert'), (patch = p), exec()),
      maybeSingle: async () => {
        const r = await exec();
        return { data: (r.data as Row[] | null)?.[0] ?? null, error: r.error };
      },
      then: (res: (v: unknown) => unknown, rej: (e: unknown) => unknown) => exec().then(res, rej),
    };
    return b;
  };
  const client = {
    from,
    auth: { admin: { createUser: async () => ({ data: { user: { id: AUTH_ID } }, error: null }) } },
  };
  return { supabase: { client } as unknown as SupabaseService, log, tables };
}

function make(tables: Record<string, Row[]>, opts: { failures?: Record<string, boolean>; link?: jest.Mock } = {}) {
  const db = fakeDb(tables, opts.failures);
  const auth = { createOrRotateAdmin: jest.fn(async () => ({ token: 'bearer-once' })) } as unknown as AdminAuthService;
  const link = opts.link ?? jest.fn(async () => ({ login_email: 'staff@example.com', person_role: 'admin', can_sign_in: true }));
  const links = { link } as unknown as AdminIdentityLinksService;
  const service = new AdminInvitesService(db.supabase, auth, { get: () => undefined } as unknown as ConfigService, links);
  return { service, db, link, auth };
}

const future = new Date(Date.now() + 86_400_000).toISOString();
const invite = (extra: Row = {}): Row => ({
  id: 'inv-1', email: 'staff@example.com', role: 'support_agent', token: 'tok-123456789',
  status: 'pending', expires_at: future, help24_user_id: PERSON, created_by: 'adm-owner', ...extra,
});
const owner = { id: 'adm-owner', email: 'owner@example.com', active: true };

describe('createInvite — an invitation names its person', () => {
  it('stores the chosen person on the invitation', async () => {
    const { service, db } = make({ users: [{ id: PERSON, role: 'user' }], admin_users: [owner] });
    await service.createInvite({ email: 'Staff@Example.com', role: 'support_agent', createdBy: 'adm-owner', help24UserId: PERSON });
    expect(db.tables.admin_invites[0]).toMatchObject({ email: 'staff@example.com', help24_user_id: PERSON, status: 'pending' });
  });

  it('refuses a person who does not exist', async () => {
    const { service } = make({ users: [] });
    await expect(
      service.createInvite({ email: 'a@b.co', role: 'support_agent', createdBy: 'x', help24UserId: PERSON }),
    ).rejects.toBeInstanceOf(NotFoundException);
  });

  it('refuses a person who already has a dashboard login', async () => {
    const { service, db } = make({
      users: [{ id: PERSON }],
      user_auth_identities: [{ provider: 'supabase', subject: 'other-login', help24_user_id: PERSON }],
    });
    await expect(
      service.createInvite({ email: 'a@b.co', role: 'support_agent', createdBy: 'x', help24UserId: PERSON }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(db.tables.admin_invites ?? []).toHaveLength(0);
  });
});

describe('acceptInvite — the chosen person is linked and promoted', () => {
  const accept = (service: AdminInvitesService) => service.acceptInvite({ token: 'tok-123456789', name: 'New Staff', password: 'Long-enough-1' });

  it('links the new login to the chosen person, recording the inviter, then promotes them by id', async () => {
    const { service, db, link } = make({ admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON, role: 'user' }] });
    await expect(accept(service)).resolves.toMatchObject({ email: 'staff@example.com', token: 'bearer-once' });

    expect(link).toHaveBeenCalledWith(AUTH_ID, PERSON, 'owner@example.com (invite)');
    expect(db.tables.users[0].role).toBe('admin');
    expect(db.tables.admin_invites[0].status).toBe('completed');
  });

  it('never looks the person up by email when the invitation names them', async () => {
    const { service, db } = make({ admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON, role: 'user' }] });
    await accept(service);
    const usersUpdates = db.log.filter((l) => l.table === 'users' && l.op === 'update');
    expect(usersUpdates).toHaveLength(1);
  });

  it('a retry where the login is already linked to the SAME person does not link twice', async () => {
    const { service, link } = make({
      admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON }],
      user_auth_identities: [{ provider: 'supabase', subject: AUTH_ID, help24_user_id: PERSON }],
    });
    await accept(service);
    expect(link).not.toHaveBeenCalled();
  });

  it('a login already linked to SOMEONE ELSE fails the acceptance and leaves the invitation usable', async () => {
    const { service, db } = make({
      admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON }],
      user_auth_identities: [{ provider: 'supabase', subject: AUTH_ID, help24_user_id: 'another-person' }],
    });
    await expect(accept(service)).rejects.toBeInstanceOf(ConflictException);
    expect(db.tables.admin_invites[0].status).toBe('pending');
  });

  it('a person who gained a login in the meantime fails the acceptance and leaves the invitation usable', async () => {
    const link = jest.fn(async () => { throw new ConflictException('person_already_has_login'); });
    const { service, db } = make({ admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON }] }, { link });
    await expect(accept(service)).rejects.toBeInstanceOf(ConflictException);
    expect(db.tables.admin_invites[0].status).toBe('pending');
  });

  it('a promotion that fails is a 503 and leaves the invitation usable — never half an admin', async () => {
    const { service, db } = make(
      { admin_invites: [invite()], admin_users: [owner], users: [{ id: PERSON, role: 'user' }] },
      { failures: { 'users.update': true } },
    );
    await expect(accept(service)).rejects.toBeInstanceOf(ServiceUnavailableException);
    expect(db.tables.admin_invites[0].status).toBe('pending');
  });

  it('an invitation from before migration 122 links nothing and promotes by email, as before', async () => {
    const { service, link, db } = make({
      admin_invites: [invite({ help24_user_id: null })], admin_users: [owner],
      users: [{ id: PERSON, email: 'staff@example.com', role: 'user' }],
    });
    await accept(service);
    expect(link).not.toHaveBeenCalled();
    expect(db.tables.users[0].role).toBe('admin');
  });
});
