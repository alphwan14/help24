/**
 * A chainable stand-in for the Supabase client, for the moderation specs.
 *
 * Named `*.testspec.ts` on purpose: tsconfig.build.json excludes `**\/*spec.ts`
 * (so this never ships in dist) while Jest only runs `*.spec.ts` (so it is not
 * mistaken for a suite).
 *
 * Every `from(table)` / `rpc(fn, args)` records a Call; every chained method
 * (`select`, `eq`, `in`, `order`, …) is recorded on it; awaiting the chain asks
 * the resolver what that call returns. Specs assert on the recorded calls.
 */
export interface Call {
  table?: string;
  rpc?: string;
  args?: Record<string, unknown>;
  ops: Array<[string, unknown[]]>;
}

export interface Answer {
  data?: unknown;
  error?: { code?: string; message?: string } | null;
  count?: number | null;
}

export type Resolver = (call: Call) => Answer;

export function fakeSupabase(resolve: Resolver = () => ({ data: null })) {
  const calls: Call[] = [];
  /** Every object a signed download link was minted for, with its bucket. */
  const signed: Array<{ bucket: string; path: string }> = [];
  /** Objects that do not exist: signing one fails the way Storage does. */
  const missing = new Set<string>();

  const chain = (call: Call): unknown => {
    const proxy: unknown = new Proxy(
      {},
      {
        get(_target, prop) {
          if (prop === 'then') {
            const answer = resolve(call);
            const result = { data: answer.data ?? null, error: answer.error ?? null, count: answer.count ?? null };
            return (onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) =>
              Promise.resolve(result).then(onFulfilled, onRejected);
          }
          return (...args: unknown[]) => {
            call.ops.push([String(prop), args]);
            return proxy;
          };
        },
      },
    );
    return proxy;
  };

  const client = {
    from(table: string) {
      const call: Call = { table, ops: [] };
      calls.push(call);
      return chain(call);
    },
    rpc(fn: string, args: Record<string, unknown>) {
      const call: Call = { rpc: fn, args, ops: [] };
      calls.push(call);
      return chain(call);
    },
    storage: {
      from: (bucket: string) => ({
        createSignedUploadUrl: async (path: string) => ({ data: { signedUrl: `https://upload.test/${path}`, token: 'tok' }, error: null }),
        createSignedUrl: async (path: string) => {
          if (missing.has(`${bucket}/${path}`)) return { data: null, error: { message: 'Object not found' } };
          signed.push({ bucket, path });
          return { data: { signedUrl: `https://view.test/${path}` }, error: null };
        },
      }),
    },
  };

  return { supabase: { client, url: 'https://ref.supabase.test' } as never, calls, signed, missing };
}

/** The arguments of the first recorded op with this name on a call. */
export function opArgs(call: Call | undefined, name: string): unknown[] | undefined {
  return call?.ops.find(([op]) => op === name)?.[1];
}
