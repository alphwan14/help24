import {
  BadRequestException,
  ConflictException,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminIdentityLinksService } from './admin-identity-links.service';

const LOGIN = '0b5c8d2e-4f1a-4c3b-9d7e-1a2b3c4d5e6f';

/** Records every rpc / from() call; answers rpc by function name. */
function fake(rpcAnswer: Record<string, { data?: unknown; error?: { message: string } }>, people: Array<Record<string, unknown>> = [], links: string[] = []) {
  const calls: Array<{ rpc?: string; args?: unknown; table?: string; or?: string }> = [];
  const client = {
    rpc: async (fn: string, args: unknown) => {
      calls.push({ rpc: fn, args });
      return { data: null, error: null, ...rpcAnswer[fn] };
    },
    from(table: string) {
      const call: { table: string; or?: string } = { table };
      calls.push(call);
      const builder = {
        select: () => builder,
        or: (expr: string) => { call.or = expr; return builder; },
        order: () => builder,
        eq: () => builder,
        limit: async () => ({ data: people, error: null }),
        in: async () => ({ data: links.map((id) => ({ help24_user_id: id })), error: null }),
      };
      return builder;
    },
  };
  return { service: new AdminIdentityLinksService({ client } as unknown as SupabaseService), calls };
}

describe('AdminIdentityLinksService.link', () => {
  it('links, records who decided, and says whether the person can sign in yet', async () => {
    const { service, calls } = fake({ admin_link_dashboard_login: { data: { outcome: 'linked', login_email: 'staff@example.com', person_role: 'admin' } } });

    await expect(service.link(LOGIN, 'FirebaseUid123', 'owner@example.com')).resolves.toEqual({
      login_email: 'staff@example.com',
      person_role: 'admin',
      can_sign_in: true,
    });
    expect(calls[0]).toEqual({
      rpc: 'admin_link_dashboard_login',
      args: { p_auth_subject: LOGIN, p_help24_user_id: 'FirebaseUid123', p_linked_by: 'owner@example.com' },
    });
  });

  it('a link to a person who is not an admin succeeds but is reported as not able to sign in', async () => {
    const { service } = fake({ admin_link_dashboard_login: { data: { outcome: 'linked', login_email: 'x@example.com', person_role: 'user' } } });
    await expect(service.link(LOGIN, 'uid', 'owner@example.com')).resolves.toMatchObject({ can_sign_in: false });
  });

  it.each([
    ['no_login', NotFoundException],
    ['no_person', NotFoundException],
    ['login_already_linked', ConflictException],
    ['person_already_has_login', ConflictException],
    ['linked_by_required', BadRequestException],
    ['something_new', ServiceUnavailableException],
  ])('outcome %s becomes %p', async (outcome, kind) => {
    const { service } = fake({ admin_link_dashboard_login: { data: { outcome } } });
    await expect(service.link(LOGIN, 'uid', 'owner@example.com')).rejects.toBeInstanceOf(kind);
  });

  it('a database error is a 503, never a link', async () => {
    const { service } = fake({ admin_link_dashboard_login: { error: { message: 'connection reset' } } });
    await expect(service.link(LOGIN, 'uid', 'owner@example.com')).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('refuses a login id that is not a Supabase Auth UUID without touching the database', async () => {
    const { service, calls } = fake({});
    // A Firebase UID in the login slot is the classic mix-up auth-identity.ts guards against.
    await expect(service.link('FirebaseUidAbcdefghijklmnop12', 'uid', 'owner@example.com')).rejects.toBeInstanceOf(BadRequestException);
    expect(calls).toHaveLength(0);
  });
});

describe('AdminIdentityLinksService.searchPeople', () => {
  it('a query too short to mean anything returns nothing and reads nothing', async () => {
    const { service, calls } = fake({});
    await expect(service.searchPeople(' a ')).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
  });

  it('strips characters that would change the PostgREST filter or the LIKE pattern', async () => {
    const { service, calls } = fake({}, []);
    await service.searchPeople('ojars),role.eq.admin%_*"');
    const or = calls.find((c) => c.table === 'users')?.or ?? '';
    // Exactly three clauses, each a quoted substring match on the sanitized text.
    expect(or).toBe(
      ['name', 'email', 'phone_number'].map((col) => `${col}.ilike."%ojars role.eq.admin%"`).join(','),
    );
  });

  it('a dotted email is searched as one quoted value', async () => {
    const { service, calls } = fake({}, []);
    await service.searchPeople('john.doe@example.com');
    expect(calls.find((c) => c.table === 'users')?.or).toContain('email.ilike."%john.doe@example.com%"');
  });

  it('flags people who already have a dashboard login', async () => {
    const { service } = fake({}, [
      { id: 'p1', name: 'Has login', email: 'a@x.org', phone_number: null, role: 'admin' },
      { id: 'p2', name: 'No login', email: 'b@x.org', phone_number: '+254700000000', role: 'user' },
    ], ['p1']);
    const res = await service.searchPeople('login');
    expect(res.map((p) => [p.id, p.has_dashboard_login])).toEqual([['p1', true], ['p2', false]]);
  });
});
