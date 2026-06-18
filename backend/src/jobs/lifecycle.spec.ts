import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { JobsService } from './jobs.service';

/**
 * Phase 2 — participant-scoping for the Job Lifecycle Detail endpoint.
 *
 * getLifecycle must only return data to the post's client (author) or selected
 * provider, and must aggregate the canonical tables without throwing when the
 * optional lifecycle rows (tx / escrow / completion / dispute) are absent.
 */

/** Chainable Supabase mock: each from(table) resolves single()/maybeSingle()/await to a configured row. */
function makeSupabase(rows: Record<string, any>) {
  const builder = (table: string): any => {
    const terminalValue = { data: rows[table] ?? null, error: null };
    const b: any = {};
    for (const m of ['select', 'eq', 'order', 'limit']) b[m] = () => b;
    b.single = () => Promise.resolve(terminalValue);
    b.maybeSingle = () => Promise.resolve(terminalValue);
    // Awaiting the builder directly (e.g. dispute_decisions list) resolves to an array.
    b.then = (resolve: (v: any) => any) => resolve({ data: rows[table] ?? [], error: null });
    return b;
  };
  return { client: { from: builder } };
}

function service(rows: Record<string, any>) {
  const supa = makeSupabase(rows);
  return new JobsService(supa as any, {} as any, {} as any);
}

const POST = {
  id: 'p1', title: 'Fix sink', price: 1500, status: 'assigned',
  author_user_id: 'client1', selected_provider_id: 'prov1', created_at: '2026-06-10T08:00:00Z',
};

describe('JobsService.getLifecycle participant scoping', () => {
  it('rejects a non-participant with ForbiddenException', async () => {
    const svc = service({ posts: POST });
    await expect(svc.getLifecycle('p1', 'stranger')).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('throws NotFound for a missing post', async () => {
    const svc = service({ posts: null });
    await expect(svc.getLifecycle('nope', 'client1')).rejects.toBeInstanceOf(NotFoundException);
  });

  it('returns an aggregate for the client with viewer_role and a derived timeline', async () => {
    const svc = service({ posts: POST });
    const res = await svc.getLifecycle('p1', 'client1');
    expect(res.viewer_role).toBe('client');
    expect(res.post.id).toBe('p1');
    expect(res.payment).toBeNull();
    expect(res.dispute).toBeNull();
    // Timeline always contains at least the post-created event.
    expect(res.timeline.some((t) => t.type === 'post_created')).toBe(true);
  });

  it('returns an aggregate for the selected provider', async () => {
    const svc = service({ posts: POST });
    const res = await svc.getLifecycle('p1', 'prov1');
    expect(res.viewer_role).toBe('provider');
  });
});
