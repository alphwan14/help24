import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { DisputesService } from './disputes.service';
import { DisputeStorageService } from './dispute-storage.service';

/**
 * Phase 3.3 Stage 1 — participant authorization + evidence storage guards.
 *
 * Locks in the security-critical invariants:
 *   1. assertParticipant() is the single gate — a non-participant is rejected.
 *   2. Only whitelisted MIME types become evidence (executables/archives/videos
 *      and unknown types are refused).
 *   3. A participant cannot register an object path issued for another dispute.
 */

const POST = {
  id: 'post-1',
  title: 'Fix the sink',
  author_user_id: 'client-1',
  selected_provider_id: 'provider-1',
};
const DISPUTE = { id: 'd1', status: 'reviewing', post_id: 'post-1' };

function supaMock(opts: { dispute?: unknown; post?: unknown } = {}) {
  const dispute = 'dispute' in opts ? opts.dispute : DISPUTE;
  const post = 'post' in opts ? opts.post : POST;
  return {
    client: {
      from(table: string) {
        const result =
          table === 'disputes'
            ? { data: dispute, error: dispute ? null : { message: 'not found' } }
            : table === 'posts'
              ? { data: post, error: post ? null : { message: 'not found' } }
              : { data: null, error: null };
        const chain: any = {
          select: () => chain,
          eq: () => chain,
          is: () => chain,
          order: () => chain,
          single: async () => result,
          maybeSingle: async () => result,
        };
        return chain;
      },
    },
  };
}

function build(opts: { dispute?: unknown; post?: unknown } = {}) {
  const supa = supaMock(opts);
  const notifications = { send: jest.fn(), sendMany: jest.fn() };
  const events = { emit: jest.fn() };
  const storage = {} as DisputeStorageService;
  const service = new DisputesService(
    supa as any,
    notifications as any,
    events as any,
    storage,
  );
  return { service, notifications };
}

describe('DisputesService.assertParticipant', () => {
  it('accepts the client (author) and reports role=client', async () => {
    const { service } = build();
    const { role } = await service.assertParticipant('d1', 'client-1');
    expect(role).toBe('client');
  });

  it('accepts the selected provider and reports role=provider', async () => {
    const { service } = build();
    const { role } = await service.assertParticipant('d1', 'provider-1');
    expect(role).toBe('provider');
  });

  it('rejects a stranger who is neither client nor provider', async () => {
    const { service } = build();
    await expect(service.assertParticipant('d1', 'random-user')).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('requires a user_id', async () => {
    const { service } = build();
    await expect(service.assertParticipant('d1', '')).rejects.toBeInstanceOf(BadRequestException);
  });
});

describe('DisputeStorageService MIME + path guards', () => {
  it('maps allowed image/pdf MIME types to evidence types', () => {
    expect(DisputeStorageService.evidenceTypeFor('image/jpeg')).toBe('image');
    expect(DisputeStorageService.evidenceTypeFor('image/png')).toBe('image');
    expect(DisputeStorageService.evidenceTypeFor('image/webp')).toBe('image');
    expect(DisputeStorageService.evidenceTypeFor('application/pdf')).toBe('document');
  });

  it('refuses executables, archives, videos and unknown types', () => {
    for (const bad of [
      'application/x-msdownload', // .exe
      'application/zip',
      'video/mp4',
      'application/octet-stream',
      'text/html',
      '',
    ]) {
      expect(() => DisputeStorageService.evidenceTypeFor(bad)).toThrow(BadRequestException);
    }
  });

  it('rejects an object path that belongs to a different dispute', () => {
    expect(() => DisputeStorageService.assertPathBelongs('d1', 'disputes/d2/abc.jpg')).toThrow(
      BadRequestException,
    );
    expect(() => DisputeStorageService.assertPathBelongs('d1', 'evil/d1/abc.jpg')).toThrow(
      BadRequestException,
    );
    // Correct prefix passes.
    expect(() => DisputeStorageService.assertPathBelongs('d1', 'disputes/d1/abc.jpg')).not.toThrow();
  });
});
