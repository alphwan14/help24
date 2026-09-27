import { Logger } from '@nestjs/common';
import { EventsService } from '../events/events.service';
import { Call, fakeSupabase } from '../moderation/fake-supabase.testspec';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from './jobs.service';

/**
 * A listing Trust & Safety hid cannot be booked. The database guard (migration
 * 116) refuses direct writes to a moderated post, but selectProvider writes
 * with the service role, so the backend has to refuse it itself.
 */
function build(post: Record<string, unknown>) {
  const { supabase, calls } = fakeSupabase((call: Call) => {
    if (call.table === 'posts') return { data: post };
    if (call.table === 'applications') return { data: { id: 'app-1' } };
    return { data: null };
  });
  const events = { emit: jest.fn().mockResolvedValue(undefined) };
  const service = new JobsService(
    supabase,
    { send: jest.fn() } as unknown as NotificationsService,
    events as unknown as EventsService,
  );
  const postUpdate = () => calls.find((c) => c.table === 'posts' && c.ops.some(([op]) => op === 'update'));
  return { service, postUpdate };
}

const dto = { post_id: 'post-1', provider_id: 'u_provider', client_user_id: 'u_client' };

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('JobsService.selectProvider — moderated listings', () => {
  it('refuses to book a listing hidden by moderation, and writes nothing', async () => {
    const { service, postUpdate } = build({
      id: 'post-1', title: 'Plumbing', author_user_id: 'u_client', status: 'open', archived_by: 'moderation',
    });
    await expect(service.selectProvider(dto)).rejects.toMatchObject({ status: 409 });
    expect(postUpdate()).toBeUndefined();
  });

  it('18: an ordinary open listing still books exactly as before', async () => {
    const { service, postUpdate } = build({
      id: 'post-1', title: 'Plumbing', author_user_id: 'u_client', status: 'open', archived_by: null,
    });
    await expect(service.selectProvider(dto)).resolves.toMatchObject({ post_id: 'post-1', provider_id: 'u_provider' });
    expect(postUpdate()?.ops.find(([op]) => op === 'update')?.[1][0]).toEqual({
      selected_provider_id: 'u_provider',
      status: 'assigned',
    });
  });
});
