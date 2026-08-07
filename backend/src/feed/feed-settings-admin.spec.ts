import { BadRequestException, ConflictException } from '@nestjs/common';
import { FeedSettingsAdminController } from './feed-settings-admin.controller';
import { FeedSettingsService, FEED_SETTINGS_KEYS } from './feed-settings.service';
import { DEFAULT_FEED_CONFIG } from './ranking/defaults';

/**
 * The ranking write surface.
 *
 * These tests pin the properties that make writing to `feed_settings` through
 * an API safer than the hand-written SQL it replaces: the key allowlist, the
 * reset lever, and the fact that the reader's type guard still stands behind
 * every write.
 */

type Row = { key: string; value: Record<string, unknown>; updated_at: string };

/**
 * Stand-in for the PostgREST chains this service uses, including the
 * `updated_at` guard the merge depends on.
 *
 * `onBeforeUpdate` simulates a racing writer landing between the service's read
 * and its write — the interleaving optimistic concurrency exists to catch.
 */
function fakeSupabase(
  initial: Row[] = [],
  hooks: { onBeforeUpdate?: (rows: Row[]) => void } = {},
) {
  let rows = initial.map((r) => ({ ...r }));
  const calls = { inserts: [] as Row[], updates: [] as Row[], deletes: [] as string[] };

  const client = {
    from(table: string) {
      if (table !== 'feed_settings') throw new Error(`unexpected table ${table}`);
      return {
        select: (_cols?: string) => {
          const chain = {
            eq: (_col: string, key: string) => ({
              maybeSingle: async () => ({
                data: rows.find((r) => r.key === key) ?? null,
                error: null,
              }),
            }),
            then: undefined as unknown,
          };
          // `select('key, value')` with no filter is awaited directly.
          return Object.assign(
            Promise.resolve({ data: rows.map((r) => ({ ...r })), error: null }),
            chain,
          );
        },
        insert: async (row: Row) => {
          if (rows.some((r) => r.key === row.key)) return { error: { message: 'duplicate key' } };
          calls.inserts.push(row);
          rows.push({ ...row });
          return { error: null };
        },
        update: (patch: { value: Record<string, unknown>; updated_at: string }) => ({
          eq: (_c1: string, key: string) => ({
            eq: (_c2: string, guardUpdatedAt: string) => ({
              select: async () => {
                hooks.onBeforeUpdate?.(rows);
                const idx = rows.findIndex(
                  (r) => r.key === key && r.updated_at === guardUpdatedAt,
                );
                if (idx === -1) return { data: [], error: null }; // guard lost the race
                rows[idx] = { key, value: patch.value, updated_at: patch.updated_at };
                calls.updates.push({ ...rows[idx] });
                return { data: [{ key }], error: null };
              },
            }),
          }),
        }),
        delete: () => ({
          eq: async (_col: string, key: string) => {
            calls.deletes.push(key);
            rows = rows.filter((r) => r.key !== key);
            return { error: null };
          },
        }),
      };
    },
  };

  return { supabase: { client } as never, calls, current: () => rows };
}

const AT = '2026-08-07T12:00:00.000Z';

function build(initial: Row[] = [], hooks: { onBeforeUpdate?: (rows: Row[]) => void } = {}) {
  const fake = fakeSupabase(initial, hooks);
  const service = new FeedSettingsService(fake.supabase);
  return { controller: new FeedSettingsAdminController(service), service, ...fake };
}

/** A stored `weights` document shaped like the real one: complete. */
function storedWeights(overrides: Record<string, number> = {}): Row {
  return {
    key: 'weights',
    value: { ...DEFAULT_FEED_CONFIG.weights, ...overrides },
    updated_at: AT,
  };
}

describe('FeedSettingsAdminController — key allowlist', () => {
  it.each(['weight', 'timeOfDay', 'WEIGHTS', '', 'drop table'])(
    'rejects the unknown key %p rather than writing a row nothing reads',
    async (key) => {
      const { controller, calls } = build();
      await expect(controller.updateSettings(key, { distance: 10 })).rejects.toThrow(
        BadRequestException,
      );
      expect(calls.inserts).toEqual([]);
      expect(calls.updates).toEqual([]);
    },
  );

  it('accepts every key the reader actually consumes', () => {
    const { service } = build();
    for (const key of FEED_SETTINGS_KEYS) {
      expect(service.isSettingsKey(key)).toBe(true);
    }
  });

  it('accepts time_of_day, the one key whose table name differs from the config field', async () => {
    // `feed_settings.time_of_day` maps to `FeedConfig.timeOfDay`. Rejecting the
    // snake_case form here would make the one genuinely confusing key unusable,
    // and field validation must resolve the same mapping to find `baseline`.
    const { controller, calls } = build();
    await controller.updateSettings('time_of_day', { baseline: 0.4 });
    expect(calls.inserts.map((u) => u.key)).toEqual(['time_of_day']);
  });

  it.each([null, 'a string', 42, ['an', 'array']])(
    'rejects the non-object body %p',
    async (value) => {
      const { controller, calls } = build();
      await expect(
        controller.updateSettings('weights', value as unknown as Record<string, unknown>),
      ).rejects.toThrow(BadRequestException);
      expect(calls.inserts).toEqual([]);
      expect(calls.updates).toEqual([]);
    },
  );
});

describe('FeedSettingsAdminController — writes', () => {
  it('creates the document when no row exists yet', async () => {
    const { controller, calls } = build();

    const result = await controller.updateSettings('weights', { distance: 99 });

    expect(calls.inserts).toHaveLength(1);
    expect(result.effective.weights.distance).toBe(99);
  });

  it('MERGES into the stored document — the other fourteen weights survive', async () => {
    // The defect this test exists for: production stores FULL documents, so a
    // replacing write of one field would drop the rest to compiled defaults.
    const { controller, current } = build([storedWeights({ profession: 41, distance: 30 })]);

    const result = await controller.updateSettings('weights', { distance: 35 });

    expect(result.effective.weights.distance).toBe(35);
    expect(result.effective.weights.profession).toBe(41); // pinned, non-default, survived
    expect(Object.keys(current()[0].value).sort()).toEqual(
      Object.keys(DEFAULT_FEED_CONFIG.weights).sort(),
    );
  });

  it('is idempotent — replaying the same PATCH yields the same document', async () => {
    const { controller, current } = build([storedWeights()]);

    await controller.updateSettings('weights', { distance: 35 });
    const afterFirst = JSON.stringify(current()[0].value);

    const second = await controller.updateSettings('weights', { distance: 35 });

    expect(JSON.stringify(current()[0].value)).toBe(afterFirst);
    expect(second.effective.weights.distance).toBe(35);
  });

  it('drops a wrong-typed value at read time — the reader guard still stands', async () => {
    const { controller } = build();

    const result = await controller.updateSettings('weights', {
      distance: 'very far' as unknown as number,
    });

    expect(result.effective.weights.distance).toBe(DEFAULT_FEED_CONFIG.weights.distance);
  });

  it('invalidates the cache, so the next read reflects the write immediately', async () => {
    const { controller, service } = build([storedWeights()]);

    await service.config(); // warm the 60s cache
    await controller.updateSettings('weights', { distance: 77 });

    expect((await service.config()).weights.distance).toBe(77);
  });
});

describe('FeedSettingsAdminController — field validation', () => {
  it('rejects a field the reader would silently ignore', async () => {
    // Storing it would leave an admin certain they changed something that does
    // nothing — forever, and with no error to look up.
    const { controller, calls } = build([storedWeights()]);

    await expect(controller.updateSettings('weights', { distanse: 35 })).rejects.toThrow(
      /Unknown field/,
    );
    expect(calls.updates).toEqual([]);
  });

  it('names the valid fields so the typo is self-correcting', async () => {
    const { controller } = build([storedWeights()]);
    await expect(controller.updateSettings('weights', { distanse: 35 })).rejects.toThrow(
      /profession/,
    );
  });

  it('allows the open nested maps, which are legitimate document fields', async () => {
    const { controller } = build();
    await expect(
      controller.updateSettings('behaviour', { eventWeights: { hire: 9 } }),
    ).resolves.toBeDefined();
    await expect(
      controller.updateSettings('trust', { tierScores: { top_rated: 0.7 } }),
    ).resolves.toBeDefined();
  });
});

describe('FeedSettingsAdminController — concurrency', () => {
  it('409s rather than silently discarding a concurrent edit', async () => {
    // Another admin writes between this request's read and its write.
    const { controller, calls } = build([storedWeights()], {
      onBeforeUpdate: (rows) => {
        rows[0].updated_at = '2026-08-07T12:00:05.000Z';
        rows[0].value = { ...rows[0].value, profession: 99 };
      },
    });

    await expect(controller.updateSettings('weights', { distance: 35 })).rejects.toThrow(
      ConflictException,
    );
    expect(calls.updates).toEqual([]);
  });

  it('leaves the racing writer’s value intact', async () => {
    const { controller, current } = build([storedWeights()], {
      onBeforeUpdate: (rows) => {
        rows[0].updated_at = '2026-08-07T12:00:05.000Z';
        rows[0].value = { ...rows[0].value, profession: 99 };
      },
    });

    await expect(controller.updateSettings('weights', { distance: 35 })).rejects.toThrow();
    expect(current()[0].value.profession).toBe(99);
    expect(current()[0].value.distance).toBe(DEFAULT_FEED_CONFIG.weights.distance);
  });
});

describe('FeedSettingsAdminController — reset is the rollback lever', () => {
  it('deletes the override and restores the compiled default', async () => {
    const { controller, calls, current } = build([{ key: 'weights', value: { distance: 99 }, updated_at: AT }]);

    expect((await controller.getSettings()).effective.weights.distance).toBe(99);

    const result = await controller.resetSettings('weights');

    expect(calls.deletes).toEqual(['weights']);
    expect(current()).toEqual([]);
    expect(result.effective.weights.distance).toBe(DEFAULT_FEED_CONFIG.weights.distance);
  });

  it('refuses to reset an unknown key', async () => {
    const { controller, calls } = build();
    await expect(controller.resetSettings('nope')).rejects.toThrow(BadRequestException);
    expect(calls.deletes).toEqual([]);
  });
});

describe('FeedSettingsAdminController — the read surface', () => {
  it('separates what is pinned in the table from what is merely the default', async () => {
    // The merged document alone cannot express this distinction, and it is the
    // one thing someone about to retune needs to know.
    const { controller } = build([{ key: 'weights', value: { distance: 42 }, updated_at: AT }]);

    const view = await controller.getSettings();

    expect(view.overridden_keys).toEqual(['weights']);
    expect(view.stored).toEqual({ weights: { distance: 42 } });
    expect(view.effective.weights.distance).toBe(42);
    expect(view.defaults.weights.distance).toBe(DEFAULT_FEED_CONFIG.weights.distance);
    expect(view.available_keys).toEqual([...FEED_SETTINGS_KEYS]);
  });

  it('reports no overrides on a table running purely on defaults', async () => {
    const { controller } = build();
    const view = await controller.getSettings();

    expect(view.overridden_keys).toEqual([]);
    expect(view.effective).toEqual(DEFAULT_FEED_CONFIG);
  });
});
