import { Logger } from '@nestjs/common';
import { EventsService } from '../events/events.service';
import { Call, fakeSupabase } from '../moderation/fake-supabase.testspec';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from './jobs.service';

/**
 * Work that needs an ID check or a Care check (migration 135) goes only to a
 * provider who holds the FULL check when they are selected. selectProvider
 * writes with the service role, which the database trusts, so the backend has
 * to refuse it itself.
 */
function build(opts: { category: string; tier: string | null; meets?: boolean; tierError?: boolean; meetsError?: boolean }) {
  const { supabase, calls } = fakeSupabase((call: Call) => {
    if (call.table === 'posts') {
      return { data: { id: 'post-1', title: 'Evening sitter', category: opts.category, author_user_id: 'u_client', status: 'open', archived_by: null } };
    }
    if (call.table === 'applications') return { data: { id: 'app-1' } };
    if (call.rpc === 'vetting_tier_for_category') return opts.tierError ? { error: { message: 'down' } } : { data: opts.tier };
    if (call.rpc === 'provider_meets_vetting') return opts.meetsError ? { error: { message: 'down' } } : { data: opts.meets ?? false };
    return { data: null };
  });
  const service = new JobsService(
    supabase,
    { send: jest.fn() } as unknown as NotificationsService,
    { emit: jest.fn().mockResolvedValue(undefined) } as unknown as EventsService,
  );
  const postUpdate = () => calls.find((c) => c.table === 'posts' && c.ops.some(([op]) => op === 'update'));
  const meetsCall = () => calls.find((c) => c.rpc === 'provider_meets_vetting');
  return { service, postUpdate, meetsCall };
}

const dto = { post_id: 'post-1', provider_id: 'u_provider', client_user_id: 'u_client' };

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('JobsService.selectProvider — provider vetting', () => {
  it('refuses a provider without the Care check for care work, and writes nothing', async () => {
    const { service, postUpdate, meetsCall } = build({ category: 'Babysitting', tier: 'care', meets: false });
    await expect(service.selectProvider(dto)).rejects.toMatchObject({ status: 409 });
    await expect(service.selectProvider(dto)).rejects.toThrow(/Care check/);
    expect(postUpdate()).toBeUndefined();
    // A pending certificate is not enough to be hired.
    expect(meetsCall()?.args).toEqual({ p_user_id: 'u_provider', p_tier: 'care', p_allow_pending: false });
  });

  it('refuses a provider without an ID check for ID-check work', async () => {
    const { service, postUpdate } = build({ category: 'Tutoring', tier: 'id', meets: false });
    await expect(service.selectProvider(dto)).rejects.toThrow(/verified their ID/);
    expect(postUpdate()).toBeUndefined();
  });

  it('hires a provider who holds the check', async () => {
    const { service, postUpdate } = build({ category: 'Babysitting', tier: 'care', meets: true });
    await expect(service.selectProvider(dto)).resolves.toMatchObject({ provider_id: 'u_provider' });
    expect(postUpdate()).toBeDefined();
  });

  it('asks nothing more for work that needs no check', async () => {
    const { service, postUpdate, meetsCall } = build({ category: 'Plumbing', tier: null });
    await expect(service.selectProvider(dto)).resolves.toMatchObject({ provider_id: 'u_provider' });
    expect(meetsCall()).toBeUndefined();
    expect(postUpdate()).toBeDefined();
  });

  it('fails closed when the check cannot be read', async () => {
    for (const opts of [{ tierError: true }, { meetsError: true }]) {
      const { service, postUpdate } = build({ category: 'Babysitting', tier: 'care', meets: true, ...opts });
      await expect(service.selectProvider(dto)).rejects.toMatchObject({ status: 503 });
      expect(postUpdate()).toBeUndefined();
    }
  });
});
