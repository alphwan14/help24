import { Logger } from '@nestjs/common';
import { AccountStateService } from './account-state.service';
import { fakeSupabase } from './fake-supabase.testspec';

describe('AccountStateService', () => {
  let errors: jest.SpyInstance;

  beforeEach(() => {
    errors = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  });
  afterEach(() => jest.restoreAllMocks());

  it('asks moderation_denial and returns its answer', async () => {
    const { supabase, calls } = fakeSupabase(() => ({ data: 'suspended' }));
    const svc = new AccountStateService(supabase);
    await expect(svc.denial('u1', 'post')).resolves.toBe('suspended');
    expect(calls[0]).toMatchObject({ rpc: 'moderation_denial', args: { p_user_id: 'u1', p_capability: 'post' } });
  });

  it('caches per account and capability, and invalidation is per account', async () => {
    const { supabase, calls } = fakeSupabase(() => ({ data: null }));
    const svc = new AccountStateService(supabase);
    await svc.denial('u1', 'post');
    await svc.denial('u1', 'post');
    await svc.denial('u1', 'message');
    await svc.denial('u2', 'post');
    expect(calls).toHaveLength(3);
    svc.invalidate('u1');
    await svc.denial('u1', 'post');
    await svc.denial('u2', 'post');
    expect(calls).toHaveLength(4);
  });

  it('FAILS OPEN on a database error — and says so at ERROR', async () => {
    const { supabase } = fakeSupabase(() => ({ error: { code: '42883', message: 'function does not exist' } }));
    const svc = new AccountStateService(supabase);
    await expect(svc.denial('u1', 'hire')).resolves.toBeNull();
    expect(errors).toHaveBeenCalledWith(expect.stringContaining('fail-open'));
  });

  it('does not cache a failure, so recovery is immediate', async () => {
    let broken = true;
    const { supabase, calls } = fakeSupabase(() => (broken ? { error: { message: 'down' } } : { data: 'banned' }));
    const svc = new AccountStateService(supabase);
    await svc.denial('u1', 'hire');
    broken = false;
    await expect(svc.denial('u1', 'hire')).resolves.toBe('banned');
    expect(calls).toHaveLength(2);
  });

  it('treats an unrecognised answer as no restriction', async () => {
    const { supabase } = fakeSupabase(() => ({ data: 'something-new' }));
    await expect(new AccountStateService(supabase).denial('u1', 'post')).resolves.toBeNull();
  });

  it('reports at boot whether enforcement is available', async () => {
    const ok = new AccountStateService(fakeSupabase(() => ({ data: null })).supabase);
    await ok.onModuleInit();
    expect(ok.enforcementAvailable).toBe(true);

    const missing = new AccountStateService(fakeSupabase(() => ({ error: { message: 'missing' } })).supabase);
    await missing.onModuleInit();
    expect(missing.enforcementAvailable).toBe(false);
    expect(errors).toHaveBeenCalledWith(expect.stringContaining('NOT enforced'));
  });
});
