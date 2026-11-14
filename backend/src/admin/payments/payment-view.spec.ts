import { PaymentFacts, availableActions, buildTimeline } from './payment-view';

/** A paid job whose provider marked it done and the client has not answered. */
function facts(over: Partial<PaymentFacts> = {}): PaymentFacts {
  return {
    tx: { id: 't-1', status: 'paid', amount: 2500, total_paid: 2545, mpesa_receipt: 'QK12ABC34', failure_reason: null, created_at: '2026-11-01T09:00:00Z' },
    attempts: [{ id: 't-1', status: 'paid', total_paid: 2545, failure_reason: null, created_at: '2026-11-01T09:00:00Z' }],
    post: { id: 'p-1', title: 'Fix the sink', status: 'assigned', created_at: '2026-11-01T08:00:00Z', author_user_id: 'u-client', selected_provider_id: 'u-pro' },
    escrow: { status: 'locked', released_at: null, created_at: '2026-11-01T09:00:05Z' },
    completion: { id: 'c-1', status: 'pending_approval', created_at: '2026-11-02T10:00:00Z', reviewed_at: null, auto_approve_at: '2026-11-04T10:00:00Z', approved_by: null },
    disputes: [],
    decisions: [],
    advance: null,
    payoutEvents: [],
    adminActions: [],
    ...over,
  };
}

const ids = (f: PaymentFacts, role: 'support_agent' | 'senior_admin' | 'super_admin' = 'senior_admin') =>
  availableActions(f, role).map((a) => a.id);

describe('availableActions', () => {
  it('a paid job waiting for the client: approve it now, or open a dispute', () => {
    expect(ids(facts())).toEqual(['approve_completion', 'open_dispute']);
  });

  it('approved but the payout never arrived (paid + locked): retry the payout', () => {
    const f = facts({ completion: { ...facts().completion!, status: 'approved', approved_by: 'client', reviewed_at: '2026-11-03T10:00:00Z' } });
    expect(ids(f)).toEqual(['retry_payout', 'open_dispute']);
  });

  it('a payout with no answer from M-Pesa: check with M-Pesa, never retry', () => {
    const f = facts({ tx: { ...facts().tx, status: 'payout_pending' }, escrow: { status: 'payout_pending', released_at: null, created_at: null } });
    expect(ids(f)).toEqual(['check_mpesa', 'open_dispute']);
  });

  it('an open dispute freezes everything: no payout, no approval, no second dispute', () => {
    const f = facts({ disputes: [{ id: 'd-1', status: 'escalated', raised_by_role: 'client', opened_by_admin_id: null, created_at: '2026-11-03T00:00:00Z', escalated_at: null, resolved_at: null }] });
    expect(ids(f)).toEqual([]);
  });

  it('a closed dispute no longer blocks', () => {
    const f = facts({ disputes: [{ id: 'd-1', status: 'resolved_release', raised_by_role: 'client', opened_by_admin_id: null, created_at: '2026-11-03T00:00:00Z', escalated_at: null, resolved_at: '2026-11-04T00:00:00Z' }] });
    expect(ids(f)).toContain('approve_completion');
  });

  it('a payment that is complete offers nothing', () => {
    const f = facts({ tx: { ...facts().tx, status: 'released' }, escrow: { status: 'released', released_at: '2026-11-05T00:00:00Z', created_at: null } });
    expect(ids(f)).toEqual([]);
  });

  it('a hire never paid for can be cancelled, but not once any attempt was paid', () => {
    const unpaid = facts({
      tx: { ...facts().tx, status: 'failed' },
      attempts: [{ id: 't-1', status: 'failed', total_paid: null, failure_reason: 'Request cancelled by user', created_at: '2026-11-01T09:00:00Z' }],
      escrow: null,
      completion: null,
    });
    expect(ids(unpaid)).toEqual(['cancel_hire']);

    const laterPaid = facts({
      ...unpaid,
      attempts: [...unpaid.attempts, { id: 't-2', status: 'paid', total_paid: 2545, failure_reason: null, created_at: '2026-11-01T10:00:00Z' }],
    });
    expect(ids(laterPaid)).toEqual([]);
  });

  it('a support agent sees money actions but may only open a dispute', () => {
    const acts = availableActions(facts(), 'support_agent');
    expect(acts.find((a) => a.id === 'approve_completion')).toMatchObject({ allowed: false, blocked_reason: 'A senior admin takes this action.' });
    expect(acts.find((a) => a.id === 'open_dispute')).toMatchObject({ allowed: true, blocked_reason: null });
  });
});

describe('buildTimeline', () => {
  it('tells the story in order, with who did each admin action', () => {
    const f = facts({
      completion: { ...facts().completion!, status: 'approved', approved_by: 'admin', reviewed_at: '2026-11-03T10:00:00Z' },
      payoutEvents: [
        { event_type: 'payout_failed', occurred_at: '2026-11-03T10:01:00Z', reason: 'Receiver not registered', metadata: { result_code: 2001 } },
      ],
      adminActions: [
        { action_type: 'completion_approved', admin_email: 'senior@help24.test', admin_role: 'senior_admin', reason: 'Client confirmed by phone', created_at: '2026-11-03T09:59:59Z' },
      ],
    });
    const t = buildTimeline(f);
    expect(t.map((e) => e.title)).toEqual([
      'Request posted',
      'This payment: KES 2,545 paid',
      'Money held by Help24',
      'Provider marked the job as done',
      'Admin approved the finished work',
      'Work approved by Help24',
      'M-Pesa refused the payout',
    ]);
    expect(t.find((e) => e.title === 'Admin approved the finished work')).toMatchObject({ by: 'senior@help24.test (senior_admin)', detail: 'Client confirmed by phone' });
    expect(t.find((e) => e.title === 'M-Pesa refused the payout')).toMatchObject({ tone: 'bad', detail: 'Receiver not registered (M-Pesa code 2001)' });
  });

  it('names a dispute Help24 opened for a party', () => {
    const f = facts({ disputes: [{ id: 'd-1', status: 'open', raised_by_role: 'provider', opened_by_admin_id: 'a-1', created_at: '2026-11-03T00:00:00Z', escalated_at: null, resolved_at: null }] });
    expect(buildTimeline(f).map((e) => e.title)).toContain('Dispute opened by Help24 for the provider');
  });
});
