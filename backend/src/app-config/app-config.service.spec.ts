import { SupabaseService } from '../supabase/supabase.service';
import { AppConfigService } from './app-config.service';
import { DEFAULT_CLIENT_CONFIG } from './client-config';

/**
 * The property under test throughout: a client can never be handed a broken
 * config. Every failure mode — missing table, outage, junk rows, junk values —
 * must resolve to a complete, valid document.
 */

type Row = { key: string; value: unknown };

/** Supabase stand-in for `from('app_settings').select('key, value')`. */
function fakeSupabase(behaviour: { rows?: Row[]; error?: { message: string } }): SupabaseService {
  return {
    client: {
      from: (table: string) => {
        expect(table).toBe('app_settings');
        return {
          select: async () => ({
            data: behaviour.rows ?? null,
            error: behaviour.error ?? null,
          }),
        };
      },
    },
  } as unknown as SupabaseService;
}

/** Records upserts so the admin path can be asserted without a database. */
function fakeUpsertSupabase(sink: { table?: string; payload?: unknown; error?: string }) {
  return {
    client: {
      from: (table: string) => {
        sink.table = table;
        return {
          select: async () => ({ data: [], error: null }),
          upsert: async (payload: unknown) => {
            sink.payload = payload;
            return { error: sink.error ? { message: sink.error } : null };
          },
        };
      },
    },
  } as unknown as SupabaseService;
}

describe('AppConfigService — safety floor', () => {
  it('serves compiled defaults when the table is empty', async () => {
    const service = new AppConfigService(fakeSupabase({ rows: [] }));
    const { config } = await service.clientConfig();
    expect(config).toEqual(DEFAULT_CLIENT_CONFIG);
  });

  it('serves compiled defaults when the table does not exist yet', async () => {
    // This is the state the world is in between deploying this code and
    // applying the migration — it must be a non-event.
    const service = new AppConfigService(
      fakeSupabase({ error: { message: 'relation "app_settings" does not exist' } }),
    );
    const { config } = await service.clientConfig();
    expect(config).toEqual(DEFAULT_CLIENT_CONFIG);
  });

  it('every kill switch defaults to enabled — config trouble never disables commerce', async () => {
    const service = new AppConfigService(fakeSupabase({ error: { message: 'timeout' } }));
    const { config } = await service.clientConfig();
    expect(config.ops.kill_switches).toEqual({
      payments: true,
      promotions: true,
      posting: true,
      applications: true,
    });
    expect(config.ops.maintenance.active).toBe(false);
  });

  it('pins the last good config through an outage rather than flapping to defaults', async () => {
    let failing = false;
    const supabase = {
      client: {
        from: () => ({
          select: async () =>
            failing
              ? { data: null, error: { message: 'connection reset' } }
              : {
                  data: [{ key: 'ops.maintenance', value: { active: true, message: 'Back at 6pm' } }],
                  error: null,
                },
        }),
      },
    } as unknown as SupabaseService;

    const service = new AppConfigService(supabase);
    const first = await service.clientConfig();
    expect(first.config.ops.maintenance.active).toBe(true);

    // Natural TTL expiry, then the database goes away.
    failing = true;
    const realNow = Date.now;
    jest.spyOn(Date, 'now').mockImplementation(() => realNow() + 120_000);
    try {
      const second = await service.clientConfig();
      expect(second.config.ops.maintenance.message).toBe('Back at 6pm');
      expect(second.version).toBe(first.version);
    } finally {
      jest.restoreAllMocks();
    }
  });

  it('keeps the last good config across an explicit invalidate + failed refetch', async () => {
    // The incident sequence this guards: an operator flips a switch, the write
    // invalidates the cache, and the very next read hits a blip. Serving
    // defaults here would silently re-enable everything they just disabled.
    let failing = false;
    const supabase = {
      client: {
        from: () => ({
          select: async () =>
            failing
              ? { data: null, error: { message: 'connection reset' } }
              : {
                  data: [{ key: 'ops.kill_switches', value: { payments: false } }],
                  error: null,
                },
        }),
      },
    } as unknown as SupabaseService;

    const service = new AppConfigService(supabase);
    await service.clientConfig();

    failing = true;
    service.invalidate();
    const after = await service.clientConfig();

    expect(after.config.ops.kill_switches.payments).toBe(false);
  });
});

describe('AppConfigService — per-key type guards', () => {
  it('applies a well-typed override', async () => {
    const service = new AppConfigService(
      fakeSupabase({ rows: [{ key: 'ops.kill_switches', value: { payments: false } }] }),
    );
    const { config } = await service.clientConfig();
    expect(config.ops.kill_switches.payments).toBe(false);
    // Siblings keep their defaults — a partial document is legal.
    expect(config.ops.kill_switches.posting).toBe(true);
  });

  it('ignores a wrong-typed value and keeps that one default', async () => {
    const service = new AppConfigService(
      fakeSupabase({
        rows: [{ key: 'ops.kill_switches', value: { payments: 'false', promotions: false } }],
      }),
    );
    const { config } = await service.clientConfig();
    expect(config.ops.kill_switches.payments).toBe(true); // string rejected
    expect(config.ops.kill_switches.promotions).toBe(false); // boolean accepted
  });

  it('ignores unknown keys inside a known document', async () => {
    const service = new AppConfigService(
      fakeSupabase({ rows: [{ key: 'ops.maintenance', value: { active: true, nonsense: 1 } }] }),
    );
    const { config } = await service.clientConfig();
    expect(config.ops.maintenance.active).toBe(true);
    expect((config.ops.maintenance as unknown as Record<string, unknown>).nonsense).toBeUndefined();
  });

  it('ignores non-finite numbers', async () => {
    const service = new AppConfigService(
      fakeSupabase({ rows: [{ key: 'tuning.payments', value: { poll_budget: Number.NaN } }] }),
    );
    const { config } = await service.clientConfig();
    expect(config.tuning.payments.poll_budget).toBe(24);
  });

  it('ignores rows whose value is not an object', async () => {
    const service = new AppConfigService(
      fakeSupabase({
        rows: [
          { key: 'ops.kill_switches', value: 'disabled' },
          { key: 'ops.maintenance', value: null },
          { key: 'tuning.listings', value: [1, 2, 3] },
        ],
      }),
    );
    const { config } = await service.clientConfig();
    expect(config).toEqual(DEFAULT_CLIENT_CONFIG);
  });

  it('never projects a key outside the client contract', async () => {
    const service = new AppConfigService(
      fakeSupabase({
        rows: [
          { key: 'server.secrets', value: { daraja_key: 'leak-me' } },
          { key: 'ops.kill_switches', value: { posting: false } },
        ],
      }),
    );
    const { config } = await service.clientConfig();
    expect(JSON.stringify(config)).not.toContain('leak-me');
    expect(config.ops.kill_switches.posting).toBe(false);
  });
});

describe('AppConfigService — tuning clamps', () => {
  it('clamps a poll interval of zero to a workable floor', async () => {
    const service = new AppConfigService(
      fakeSupabase({
        rows: [{ key: 'tuning.payments', value: { poll_interval_seconds: 0, poll_budget: 0 } }],
      }),
    );
    const { config } = await service.clientConfig();
    // A zero interval would spin the client's timer; a zero budget would expire
    // the payment instantly. Both are well-typed nonsense, so the guard alone
    // is not enough.
    expect(config.tuning.payments.poll_interval_seconds).toBe(2);
    expect(config.tuning.payments.poll_budget).toBe(6);
  });

  it('clamps absurdly large values to a ceiling', async () => {
    const service = new AppConfigService(
      fakeSupabase({
        rows: [
          { key: 'tuning.payments', value: { poll_interval_seconds: 9999, poll_budget: 9999 } },
          { key: 'tuning.listings', value: { urgent_window_minutes: 100000 } },
        ],
      }),
    );
    const { config } = await service.clientConfig();
    expect(config.tuning.payments.poll_interval_seconds).toBe(60);
    expect(config.tuning.payments.poll_budget).toBe(120);
    expect(config.tuning.listings.urgent_window_minutes).toBe(1440);
  });

  it('rounds fractional values', async () => {
    const service = new AppConfigService(
      fakeSupabase({ rows: [{ key: 'tuning.listings', value: { urgent_window_minutes: 90.7 } }] }),
    );
    const { config } = await service.clientConfig();
    expect(config.tuning.listings.urgent_window_minutes).toBe(91);
  });
});

describe('AppConfigService — versioning', () => {
  it('is deterministic for identical config', async () => {
    const a = new AppConfigService(fakeSupabase({ rows: [] }));
    const b = new AppConfigService(fakeSupabase({ rows: [] }));
    expect((await a.clientConfig()).version).toBe((await b.clientConfig()).version);
  });

  it('changes when any value changes', async () => {
    const before = new AppConfigService(fakeSupabase({ rows: [] }));
    const after = new AppConfigService(
      fakeSupabase({ rows: [{ key: 'ops.kill_switches', value: { payments: false } }] }),
    );
    expect((await before.clientConfig()).version).not.toBe((await after.clientConfig()).version);
  });

  it('is stable across repeated reads (no timestamp in the hash)', async () => {
    const service = new AppConfigService(fakeSupabase({ rows: [] }));
    const first = await service.clientConfig();
    service.invalidate();
    const second = await service.clientConfig();
    expect(second.version).toBe(first.version);
  });
});

describe('AppConfigService — caching', () => {
  it('serves from cache within the TTL', async () => {
    let queries = 0;
    const supabase = {
      client: {
        from: () => ({
          select: async () => {
            queries++;
            return { data: [], error: null };
          },
        }),
      },
    } as unknown as SupabaseService;

    const service = new AppConfigService(supabase);
    await service.clientConfig();
    await service.clientConfig();
    await service.clientConfig();
    expect(queries).toBe(1);

    service.invalidate();
    await service.clientConfig();
    expect(queries).toBe(2);
  });
});

describe('AppConfigService — admin writes', () => {
  it('upserts the document and drops the cache', async () => {
    const sink: { table?: string; payload?: unknown } = {};
    const service = new AppConfigService(fakeUpsertSupabase(sink));
    await service.clientConfig(); // populate cache
    await service.adminUpdate('ops.maintenance', { active: true, message: 'Upgrading' });

    expect(sink.table).toBe('app_settings');
    expect(sink.payload).toMatchObject({ key: 'ops.maintenance', value: { active: true } });
  });

  it('surfaces a write failure rather than silently succeeding', async () => {
    const service = new AppConfigService(
      fakeUpsertSupabase({ error: 'relation "app_settings" does not exist' }),
    );
    await expect(service.adminUpdate('ops.maintenance', { active: true })).rejects.toThrow(
      /app_settings/,
    );
  });

  it('recognises exactly the contract keys', () => {
    const service = new AppConfigService(fakeSupabase({ rows: [] }));
    expect(service.isClientKey('ops.kill_switches')).toBe(true);
    expect(service.isClientKey('tuning.listings')).toBe(true);
    expect(service.isClientKey('feed.weights')).toBe(false);
    expect(service.isClientKey('')).toBe(false);
  });
});
