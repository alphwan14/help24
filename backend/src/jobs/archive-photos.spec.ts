import { Logger } from '@nestjs/common';
import { EventsService } from '../events/events.service';
import { Call, fakeSupabase } from '../moderation/fake-supabase.testspec';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from './jobs.service';
import { postPhotoPaths } from './post-photos';

/**
 * Deleting a post takes its photos and their feed thumbnails with it
 * (audit 2026-10-29, D20: the archived post's photo was still served).
 */
const ORIGIN = 'https://ref.supabase.test';
const PUB = `${ORIGIN}/storage/v1/object/public/post-images`;

describe('postPhotoPaths', () => {
  it('returns each post photo and its thumbnail', () => {
    expect(postPhotoPaths([`${PUB}/posts/a1.jpg`, `${PUB}/posts/b2.PNG`], ORIGIN)).toEqual([
      'posts/a1.jpg', 'posts/a1.thumb.jpg', 'posts/b2.PNG', 'posts/b2.thumb.jpg',
    ]);
  });

  it('never returns anything outside posts/ in this project\'s post-images bucket', () => {
    expect(postPhotoPaths([
      'https://elsewhere.test/storage/v1/object/public/post-images/posts/a.jpg',
      `${ORIGIN}/storage/v1/object/public/profiles/u1/avatar.jpg`,
      `${PUB}/avatars/u1.jpg`,
      `${PUB}/posts/../avatars/u1.jpg`,
      `${PUB}/posts/notes.txt`,
      '',
    ], ORIGIN)).toEqual([]);
  });

  it('does not invent a thumbnail of a thumbnail, and drops a query string', () => {
    expect(postPhotoPaths([`${PUB}/posts/a1.thumb.jpg`, `${PUB}/posts/c3.webp?t=1`], ORIGIN)).toEqual([
      'posts/a1.thumb.jpg', 'posts/c3.webp', 'posts/c3.thumb.jpg',
    ]);
  });
});

function build(opts: {
  images?: string[];
  openReport?: boolean;
  sharedWithLivePost?: string[];
  reportsError?: boolean;
  storageError?: string;
} = {}) {
  const fake = fakeSupabase((call: Call) => {
    if (call.table === 'posts') {
      return { data: { id: 'post-1', author_user_id: 'u1', selected_provider_id: null, status: 'open', archived_at: null } };
    }
    if (call.table === 'user_reports') {
      return opts.reportsError ? { error: { message: 'down' } } : { data: opts.openReport ? [{ id: 'r1' }] : [] };
    }
    if (call.table === 'post_images') {
      const sharedQuery = call.ops.some(([op]) => op === 'neq');
      if (sharedQuery) return { data: (opts.sharedWithLivePost ?? []).map((image_url) => ({ image_url })) };
      return { data: (opts.images ?? []).map((image_url) => ({ image_url })) };
    }
    return { data: null };
  });
  if (opts.storageError) fake.storageErrors.remove = opts.storageError;
  const service = new JobsService(
    fake.supabase,
    { send: jest.fn() } as unknown as NotificationsService,
    { emit: jest.fn().mockResolvedValue(undefined) } as unknown as EventsService,
  );
  const archived = () => fake.calls.some((c) => c.table === 'posts' && c.ops.some(([op]) => op === 'update'));
  return { service, removed: fake.removed, archived };
}

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('JobsService.archivePost removes the post\'s photos', () => {
  it('removes every photo and its thumbnail after archiving', async () => {
    const { service, removed, archived } = build({ images: [`${PUB}/posts/a1.jpg`, `${PUB}/posts/b2.png`] });
    await expect(service.archivePost('post-1', 'u1')).resolves.toMatchObject({ archived: true });
    expect(archived()).toBe(true);
    expect(removed).toEqual([
      { bucket: 'post-images', path: 'posts/a1.jpg' },
      { bucket: 'post-images', path: 'posts/a1.thumb.jpg' },
      { bucket: 'post-images', path: 'posts/b2.png' },
      { bucket: 'post-images', path: 'posts/b2.thumb.jpg' },
    ]);
  });

  it('keeps the photos while the post has an open report, for the reviewers', async () => {
    const { service, removed, archived } = build({ images: [`${PUB}/posts/a1.jpg`], openReport: true });
    await service.archivePost('post-1', 'u1');
    expect(archived()).toBe(true);
    expect(removed).toEqual([]);
  });

  it('keeps a photo another live post still shows', async () => {
    const { service, removed } = build({
      images: [`${PUB}/posts/a1.jpg`, `${PUB}/posts/b2.jpg`],
      sharedWithLivePost: [`${PUB}/posts/a1.jpg`],
    });
    await service.archivePost('post-1', 'u1');
    expect(removed.map((r) => r.path)).toEqual(['posts/b2.jpg', 'posts/b2.thumb.jpg']);
  });

  it('keeps everything when it cannot tell (a read fails)', async () => {
    const { service, removed, archived } = build({ images: [`${PUB}/posts/a1.jpg`], reportsError: true });
    await service.archivePost('post-1', 'u1');
    expect(archived()).toBe(true);
    expect(removed).toEqual([]);
  });

  it('a storage failure never fails the delete', async () => {
    const { service, archived } = build({ images: [`${PUB}/posts/a1.jpg`], storageError: 'Storage unavailable' });
    await expect(service.archivePost('post-1', 'u1')).resolves.toMatchObject({ archived: true });
    expect(archived()).toBe(true);
  });

  it('a post with no photos needs nothing removed', async () => {
    const { service, removed } = build({ images: [] });
    await service.archivePost('post-1', 'u1');
    expect(removed).toEqual([]);
  });
});
