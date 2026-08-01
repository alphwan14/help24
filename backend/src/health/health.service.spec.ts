import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import { RedisService } from '../redis/redis.service';
import { SupabaseService } from '../supabase/supabase.service';
import { HealthService } from './health.service';

/** Minimal stand-in for the Supabase query builder chain used by the probe. */
function fakeSupabase(behaviour: {
  error?: { message: string };
  throws?: Error;
  delayMs?: number;
}): SupabaseService {
  return {
    client: {
      from: () => ({
        select: () => ({
          limit: () => ({
            abortSignal: async () => {
              if (behaviour.delayMs) {
                await new Promise((resolve) => setTimeout(resolve, behaviour.delayMs));
              }
              if (behaviour.throws) throw behaviour.throws;
              return { error: behaviour.error ?? null, data: [] };
            },
          }),
        }),
      }),
    },
  } as unknown as SupabaseService;
}

function fakeRedis(overrides: Partial<Record<string, unknown>> = {}): RedisService {
  return {
    isConfigured: true,
    status: 'ready',
    safeUrl: 'redis://redis:6379',
    degradedForMs: null,
    ping: async () => ({ ok: true, latencyMs: 2 }),
    ...overrides,
  } as unknown as RedisService;
}

function fakeFirebase(app: unknown): FirebaseAdminService {
  return { app } as unknown as FirebaseAdminService;
}

const READY_FIREBASE = {
  options: {
    projectId: 'help24',
    credential: { getAccessToken: async () => ({ access_token: 'x', expires_in: 3600 }) },
  },
};

describe('HealthService — database probe', () => {
  it('reports healthy on a successful query', async () => {
    const service = new HealthService(fakeSupabase({}), fakeRedis(), fakeFirebase(READY_FIREBASE));
    const result = await service.checkDatabase();
    expect(result.status).toBe('healthy');
    expect(result.latencyMs).not.toBeNull();
  });

  it('reports unavailable when the query returns an error', async () => {
    const service = new HealthService(
      fakeSupabase({ error: { message: 'relation "posts" does not exist' } }),
      fakeRedis(),
      fakeFirebase(READY_FIREBASE),
    );
    const result = await service.checkDatabase();
    expect(result.status).toBe('unavailable');
    expect(result.detail).toContain('does not exist');
  });

  it('reports unavailable rather than throwing when the client blows up', async () => {
    // A health check that can throw is the thing that makes an incident worse.
    const service = new HealthService(
      fakeSupabase({ throws: new Error('fetch failed') }),
      fakeRedis(),
      fakeFirebase(READY_FIREBASE),
    );
    await expect(service.checkDatabase()).resolves.toMatchObject({ status: 'unavailable' });
  });

  it('coalesces concurrent probes into a single query', async () => {
    // Without single-flight, the cheapest way to load the database would be to
    // repeatedly ask whether the database is loaded.
    let queries = 0;
    const counting = {
      client: {
        from: () => {
          queries += 1;
          return {
            select: () => ({
              limit: () => ({
                abortSignal: async () => {
                  await new Promise((resolve) => setTimeout(resolve, 20));
                  return { error: null, data: [] };
                },
              }),
            }),
          };
        },
      },
    } as unknown as SupabaseService;

    const service = new HealthService(counting, fakeRedis(), fakeFirebase(READY_FIREBASE));
    await Promise.all(Array.from({ length: 25 }, () => service.checkDatabase()));
    expect(queries).toBe(1);
  });
});

describe('HealthService — redis probe', () => {
  it('reports healthy on a fast PONG', async () => {
    const service = new HealthService(fakeSupabase({}), fakeRedis(), fakeFirebase(READY_FIREBASE));
    await expect(service.checkRedis()).resolves.toMatchObject({ status: 'healthy' });
  });

  it('reports DEGRADED — not unavailable — when Redis is simply not configured', async () => {
    // Running without Redis is a supported mode with weaker guarantees.
    // Calling it "healthy" would hide a production misconfiguration; calling
    // it "unavailable" would page someone for an intended dev state.
    const service = new HealthService(
      fakeSupabase({}),
      fakeRedis({ isConfigured: false, status: 'not_configured' }),
      fakeFirebase(READY_FIREBASE),
    );
    const result = await service.checkRedis();
    expect(result.status).toBe('degraded');
    expect(result.detail).toContain('per instance');
  });

  it('reports unavailable when a configured Redis fails to answer', async () => {
    const service = new HealthService(
      fakeSupabase({}),
      fakeRedis({
        status: 'reconnecting',
        ping: async () => ({ ok: false, latencyMs: 250, detail: 'timed out' }),
      }),
      fakeFirebase(READY_FIREBASE),
    );
    await expect(service.checkRedis()).resolves.toMatchObject({ status: 'unavailable' });
  });

  it('reports degraded when PING succeeds but is slow', async () => {
    // The rate limiter runs on every request, so a slow Redis is a tax on the
    // whole API even while it is technically "up".
    const service = new HealthService(
      fakeSupabase({}),
      fakeRedis({ ping: async () => ({ ok: true, latencyMs: 400 }) }),
      fakeFirebase(READY_FIREBASE),
    );
    const result = await service.checkRedis();
    expect(result.status).toBe('degraded');
    expect(result.detail).toContain('every request');
  });
});

describe('HealthService — firebase probe', () => {
  it('reports healthy when the credential mints a token', async () => {
    const service = new HealthService(fakeSupabase({}), fakeRedis(), fakeFirebase(READY_FIREBASE));
    await expect(service.checkFirebase()).resolves.toMatchObject({ status: 'healthy' });
  });

  it('reports unavailable when Firebase was never initialized', async () => {
    const service = new HealthService(fakeSupabase({}), fakeRedis(), fakeFirebase(null));
    const result = await service.checkFirebase();
    expect(result.status).toBe('unavailable');
    expect(result.detail).toContain('FIREBASE_PROJECT_ID');
  });

  it('reports degraded when initialized but the credential is rejected', async () => {
    // The case an "is the object non-null?" check misses entirely: three
    // environment variables parsed fine and pushes are still broken.
    const service = new HealthService(
      fakeSupabase({}),
      fakeRedis(),
      fakeFirebase({
        options: {
          projectId: 'help24',
          credential: {
            getAccessToken: async () => {
              throw new Error('invalid_grant: account not found');
            },
          },
        },
      }),
    );
    const result = await service.checkFirebase();
    expect(result.status).toBe('degraded');
    expect(result.detail).toContain('invalid_grant');
  });
});

describe('HealthService — snapshot', () => {
  it('is empty until warmed, then holds every dependency', async () => {
    const service = new HealthService(fakeSupabase({}), fakeRedis(), fakeFirebase(READY_FIREBASE));
    expect(service.getSnapshot().dependencies).toHaveLength(0);

    await service.onApplicationBootstrap();
    try {
      const { dependencies, snapshotAt } = service.getSnapshot();
      expect(dependencies.map((d) => d.name).sort()).toEqual(['database', 'firebase', 'redis']);
      expect(snapshotAt).not.toBeNull();
    } finally {
      await service.onModuleDestroy();
    }
  });

  it('reads the snapshot without performing I/O', async () => {
    // The liveness endpoint must be O(1): if it probed inline, a slow Supabase
    // would push /health past the app's 5s connectivity timeout and every
    // device would declare itself offline.
    let queries = 0;
    const counting = {
      client: {
        from: () => {
          queries += 1;
          return {
            select: () => ({ limit: () => ({ abortSignal: async () => ({ error: null, data: [] }) }) }),
          };
        },
      },
    } as unknown as SupabaseService;

    const service = new HealthService(counting, fakeRedis(), fakeFirebase(READY_FIREBASE));
    await service.onApplicationBootstrap();
    try {
      const afterWarm = queries;
      for (let i = 0; i < 50; i += 1) service.getSnapshot();
      expect(queries).toBe(afterWarm);
    } finally {
      await service.onModuleDestroy();
    }
  });
});
