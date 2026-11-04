import { autoApproveDeadline, autoApproveEnabled, autoApproveHours, dueAction } from './auto-approval';
import { CompletionAutoApprovalService } from './completion-auto-approval.service';
import { JobsService } from './jobs.service';
import { DisputesService } from '../admin/disputes/disputes.service';
import { EVENT_TYPES } from '../events/event.types';

/**
 * Auto-approval (migration 134) and the race it would otherwise make likely.
 *
 * Owner decision 2026-11-04: 48 h window, reminders at 24 h and 44 h, and a
 * dispute at ANY point stops everything — no reminder, no approval, no payout.
 */

const H = 3_600_000;
const T0 = new Date('2026-11-04T10:00:00Z');
const at = (hours: number) => new Date(T0.getTime() + hours * H);

const clock = (over: Partial<Parameters<typeof dueAction>[0]> = {}) => ({
  created_at: T0.toISOString(),
  auto_approve_at: at(48).toISOString(),
  first_reminder_sent_at: null,
  final_reminder_sent_at: null,
  ...over,
});

describe('auto-approval policy', () => {
  it('defaults to 48 hours and refuses nonsense', () => {
    expect(autoApproveHours(undefined)).toBe(48);
    expect(autoApproveHours('24')).toBe(24);
    for (const bad of ['0', '-5', '6', 'abc', '100000']) expect(autoApproveHours(bad)).toBe(48);
    expect(autoApproveDeadline(T0, 48).toISOString()).toBe(at(48).toISOString());
  });

  it('is on unless switched off explicitly', () => {
    expect(autoApproveEnabled(undefined)).toBe(true);
    expect(autoApproveEnabled('FALSE')).toBe(false);
    expect(autoApproveEnabled('true')).toBe(true);
  });

  it('reminds at 24 h and 44 h, approves at 48 h', () => {
    expect(dueAction(clock(), at(23.9))).toBeNull();
    expect(dueAction(clock(), at(24))).toBe('first_reminder');
    expect(dueAction(clock({ first_reminder_sent_at: at(24).toISOString() }), at(43.9))).toBeNull();
    expect(dueAction(clock({ first_reminder_sent_at: at(24).toISOString() }), at(44))).toBe('final_reminder');
    const both = clock({ first_reminder_sent_at: at(24).toISOString(), final_reminder_sent_at: at(44).toISOString() });
    expect(dueAction(both, at(47.9))).toBeNull();
    expect(dueAction(both, at(48))).toBe('approve');
  });

  it('a 24 h window keeps the same shape: 12 h and 20 h', () => {
    const short = clock({ auto_approve_at: at(24).toISOString() });
    expect(dueAction(short, at(12))).toBe('first_reminder');
    expect(dueAction({ ...short, first_reminder_sent_at: at(12).toISOString() }, at(20))).toBe('final_reminder');
  });

  it('a sweep that was down approves an overdue job instead of sending stale reminders', () => {
    expect(dueAction(clock(), at(60))).toBe('approve');
    // Down through the first reminder: the final one supersedes it.
    expect(dueAction(clock(), at(45))).toBe('final_reminder');
    expect(dueAction(clock({ final_reminder_sent_at: at(45).toISOString() }), at(46))).toBeNull();
  });

  it('never acts on a completion from before migration 134', () => {
    expect(dueAction(clock({ auto_approve_at: null }), at(1000))).toBeNull();
  });
});

// ── A Supabase mock: each `from()` chain is recorded and answered by `reply`. ──

type Op = { method: string; args: unknown[] };
type Reply = (table: string, ops: Op[]) => { data: unknown; error: unknown };

function supabase(reply: Reply) {
  const calls: Array<{ table: string; ops: Op[] }> = [];
  const from = (table: string) => {
    const ops: Op[] = [];
    calls.push({ table, ops });
    const answer = () => Promise.resolve(reply(table, ops));
    const chain: any = new Proxy({}, {
      get(_t, prop: string) {
        if (prop === 'then') return (ok: any, bad: any) => answer().then(ok, bad);
        if (prop === 'maybeSingle' || prop === 'single') return () => answer();
        return (...args: unknown[]) => {
          ops.push({ method: prop, args });
          return chain;
        };
      },
    });
    return chain;
  };
  return { client: { from }, calls };
}
const isUpdate = (ops: Op[]) => ops.some((o) => o.method === 'update');
const updateOf = (ops: Op[]) => ops.find((o) => o.method === 'update')?.args[0] as Record<string, unknown>;

const POST = { id: 'p1', title: 'Fix the sink', author_user_id: 'client1', selected_provider_id: 'prov1' };
const ROW = {
  id: 'c1', post_id: 'p1', client_user_id: 'client1', provider_user_id: 'prov1',
  ...clock(),
};

function sweepHarness(opts: { rows?: unknown[]; claimWins?: boolean; approveWins?: boolean; post?: unknown } = {}) {
  const supa = supabase((table, ops) => {
    if (table === 'posts') return { data: opts.post === undefined ? POST : opts.post, error: null };
    if (isUpdate(ops)) return { data: opts.claimWins === false ? [] : [{ id: 'c1' }], error: null };
    return { data: opts.rows ?? [ROW], error: null };
  });
  const jobs = { approveCompletion: jest.fn().mockResolvedValue(opts.approveWins ?? true) };
  const notifications = { send: jest.fn().mockResolvedValue(undefined), sendMany: jest.fn().mockResolvedValue(undefined) };
  const service = new CompletionAutoApprovalService(supa as any, jobs as any, notifications as any);
  return { service, supa, jobs, notifications };
}

describe('CompletionAutoApprovalService.sweep', () => {
  it('reads only pending completions that have a deadline', async () => {
    const { service, supa } = sweepHarness({ rows: [] });
    await service.sweep(at(1));
    const list = supa.calls.find((c) => c.table === 'job_completions')!.ops;
    expect(list).toContainEqual({ method: 'eq', args: ['status', 'pending_approval'] });
    expect(list).toContainEqual({ method: 'not', args: ['auto_approve_at', 'is', null] });
  });

  it('claims the 24 h reminder before sending it, and only while still pending', async () => {
    const { service, supa, notifications } = sweepHarness();
    const res = await service.sweep(at(24));

    const claim = supa.calls.find((c) => c.table === 'job_completions' && isUpdate(c.ops))!.ops;
    expect(updateOf(claim)).toEqual({ first_reminder_sent_at: at(24).toISOString() });
    expect(claim).toContainEqual({ method: 'eq', args: ['status', 'pending_approval'] });
    expect(claim).toContainEqual({ method: 'is', args: ['first_reminder_sent_at', null] });
    expect(notifications.send).toHaveBeenCalledWith(expect.objectContaining({
      userId: 'client1',
      type: 'completion_requested',
      title: 'Please review the job',
      data: { post_id: 'p1', completion_id: 'c1' },
    }));
    expect(res).toEqual({ approved: 0, reminded: 1 });
  });

  it('a reminder another sweep already claimed is not sent twice', async () => {
    const { service, notifications } = sweepHarness({ claimWins: false });
    await service.sweep(at(24));
    expect(notifications.send).not.toHaveBeenCalled();
  });

  it('the 44 h reminder is the final warning', async () => {
    const { service, notifications } = sweepHarness({
      rows: [{ ...ROW, first_reminder_sent_at: at(24).toISOString() }],
    });
    await service.sweep(at(44));
    expect(notifications.send).toHaveBeenCalledWith(expect.objectContaining({
      title: 'Final reminder: 4 hours left',
      body: expect.stringContaining('open a dispute in the app before then'),
    }));
  });

  it('at 48 h approves as the system, through the same transition as the client', async () => {
    const { service, jobs, notifications } = sweepHarness();
    const res = await service.sweep(at(48));

    expect(jobs.approveCompletion).toHaveBeenCalledWith({
      completionId: 'c1', postId: 'p1', postTitle: 'Fix the sink',
      providerId: 'prov1', clientUserId: 'client1', by: 'system',
    });
    expect(notifications.sendMany).toHaveBeenCalledTimes(1);
    expect(res).toEqual({ approved: 1, reminded: 0 });
  });

  it('a completion disputed a moment before is not approved and nobody is told it was', async () => {
    const { service, notifications } = sweepHarness({ approveWins: false });
    const res = await service.sweep(at(48));
    expect(notifications.sendMany).not.toHaveBeenCalled();
    expect(res.approved).toBe(0);
  });

  it('never pays automatically when the listing no longer matches the completion', async () => {
    const { service, jobs } = sweepHarness({ post: { ...POST, selected_provider_id: 'someone-else' } });
    await service.sweep(at(48));
    expect(jobs.approveCompletion).not.toHaveBeenCalled();
  });
});

describe('JobsService.approveCompletion — one winner per completion', () => {
  function jobsHarness(moved: unknown[]) {
    const supa = supabase((table, ops) =>
      table === 'job_completions' && isUpdate(ops) ? { data: moved, error: null } : { data: null, error: null },
    );
    const events = { emit: jest.fn() };
    const service = new JobsService(supa as any, {} as any, events as any);
    const input = {
      completionId: 'c1', postId: 'p1', postTitle: 'Fix the sink',
      providerId: 'prov1', clientUserId: 'client1', by: 'system' as const,
    };
    return { service, supa, events, input };
  }

  it('moves the completion only while it is still pending', async () => {
    const { service, supa, input } = jobsHarness([{ id: 'c1' }]);
    await service.approveCompletion(input);
    const move = supa.calls.find((c) => c.table === 'job_completions')!.ops;
    expect(move).toContainEqual({ method: 'eq', args: ['status', 'pending_approval'] });
    expect(updateOf(move)).toMatchObject({ status: 'approved', approved_by: 'system' });
  });

  it('the winner marks the post completed (never over a dispute) and emits job.approved', async () => {
    const { service, supa, events, input } = jobsHarness([{ id: 'c1' }]);
    expect(await service.approveCompletion(input)).toBe(true);
    const post = supa.calls.find((c) => c.table === 'posts')!.ops;
    expect(post).toContainEqual({ method: 'neq', args: ['status', 'disputed'] });
    expect(events.emit).toHaveBeenCalledWith(expect.objectContaining({
      type: EVENT_TYPES.JOB_APPROVED,
      payload: expect.objectContaining({ post_id: 'p1', approved_by: 'system' }),
    }));
  });

  it('the loser — a dispute got there first — writes nothing else and emits nothing', async () => {
    const { service, supa, events, input } = jobsHarness([]);
    expect(await service.approveCompletion(input)).toBe(false);
    expect(supa.calls.some((c) => c.table === 'posts')).toBe(false);
    expect(events.emit).not.toHaveBeenCalled();
  });
});

describe('DisputesService.freezeForDispute — never over a payout already under way', () => {
  function disputesHarness(frozenRows: unknown[]) {
    const supa = supabase((table, ops) =>
      table === 'transactions' && isUpdate(ops) ? { data: frozenRows, error: null } : { data: null, error: null },
    );
    const events = { emit: jest.fn() };
    const service = new DisputesService(supa as any, {} as any, events as any, {} as any);
    return { service, supa, events };
  }

  it('freezes only a payment still paid (or already disputed)', async () => {
    const { service, supa, events } = disputesHarness([{ id: 'tx1' }]);
    expect(await (service as any).freezeForDispute('p1', 'tx1')).toBe(true);
    const tx = supa.calls.find((c) => c.table === 'transactions')!.ops;
    expect(tx).toContainEqual({ method: 'in', args: ['status', ['paid', 'disputed']] });
    expect(supa.calls.some((c) => c.table === 'escrow')).toBe(true);
    expect(events.emit).toHaveBeenCalledWith(expect.objectContaining({ type: EVENT_TYPES.ESCROW_DISPUTED }));
  });

  it('a payout that claimed the payment first keeps it: no escrow freeze, no frozen event', async () => {
    const { service, supa, events } = disputesHarness([]);
    expect(await (service as any).freezeForDispute('p1', 'tx1')).toBe(false);
    expect(supa.calls.some((c) => c.table === 'escrow')).toBe(false);
    expect(events.emit).not.toHaveBeenCalled();
    // The completion is still stopped from being approved.
    const completion = supa.calls.find((c) => c.table === 'job_completions')!.ops;
    expect(updateOf(completion)).toMatchObject({ status: 'disputed' });
  });
});
