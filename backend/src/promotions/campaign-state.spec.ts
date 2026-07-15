import {
  CAMPAIGN_STATUSES,
  CampaignStatus,
  TERMINAL_STATUSES,
  assertTransition,
  canTransition,
  daysRemaining,
  isCampaignStatus,
  isTerminal,
  shiftedEndOnResume,
} from './campaign-state';

/**
 * Business Promotion campaign state machine — pure-function tests. Every legal
 * edge is asserted, terminal states are proven dead ends, and the resume-shift
 * arithmetic (owners never lose purchased days) is covered.
 */

describe('campaign state machine — legal transitions', () => {
  const LEGAL: Array<[CampaignStatus, CampaignStatus]> = [
    ['draft', 'awaiting_payment'],
    ['draft', 'expired'],
    ['draft', 'cancelled'],
    ['awaiting_payment', 'pending_review'], // payment success (moderated)
    ['awaiting_payment', 'active'],         // payment success + auto_approve
    ['awaiting_payment', 'expired'],        // payment TTL lapsed
    ['awaiting_payment', 'cancelled'],
    ['pending_review', 'active'],           // admin approval
    ['pending_review', 'rejected'],         // moderation
    ['pending_review', 'cancelled'],
    ['active', 'paused'],
    ['active', 'completed'],
    ['active', 'cancelled'],
    ['paused', 'active'],                   // resume
    ['paused', 'completed'],
    ['paused', 'cancelled'],
  ];

  it.each(LEGAL)('%s → %s is allowed', (from, to) => {
    expect(canTransition(from, to)).toBe(true);
    expect(() => assertTransition(from, to)).not.toThrow();
  });

  it('exactly the legal edges exist — nothing more', () => {
    const allowedCount = CAMPAIGN_STATUSES.reduce(
      (n, from) =>
        n + CAMPAIGN_STATUSES.filter((to) => canTransition(from, to)).length,
      0,
    );
    expect(allowedCount).toBe(LEGAL.length);
  });
});

describe('campaign state machine — illegal transitions', () => {
  it('terminal states allow no exits (structurally dead)', () => {
    for (const terminal of TERMINAL_STATUSES) {
      expect(isTerminal(terminal)).toBe(true);
      for (const to of CAMPAIGN_STATUSES) {
        expect(canTransition(terminal, to)).toBe(false);
      }
    }
  });

  it('rejected → active can never happen (paid-but-rejected must stay rejected)', () => {
    expect(() => assertTransition('rejected', 'active')).toThrow(/Illegal campaign transition/);
  });

  it('cannot skip payment: draft → active and draft → pending_review are illegal', () => {
    expect(canTransition('draft', 'active')).toBe(false);
    expect(canTransition('draft', 'pending_review')).toBe(false);
  });

  it('cannot re-enter the funnel: active → awaiting_payment is illegal', () => {
    expect(canTransition('active', 'awaiting_payment')).toBe(false);
  });

  it('self-transitions are illegal (idempotency handled by callers, not the machine)', () => {
    for (const s of CAMPAIGN_STATUSES) {
      expect(canTransition(s, s)).toBe(false);
    }
  });

  it('non-active states cannot pause', () => {
    for (const s of CAMPAIGN_STATUSES.filter((x) => x !== 'active')) {
      expect(canTransition(s, 'paused')).toBe(false);
    }
  });
});

describe('isCampaignStatus', () => {
  it('accepts every known status and rejects junk', () => {
    for (const s of CAMPAIGN_STATUSES) expect(isCampaignStatus(s)).toBe(true);
    expect(isCampaignStatus('live')).toBe(false);
    expect(isCampaignStatus('')).toBe(false);
  });
});

describe('shiftedEndOnResume — purchased days are never lost', () => {
  const DAY = 24 * 60 * 60 * 1000;

  it('appends exactly the pause duration to ends_at', () => {
    const endsAt = new Date('2026-07-20T12:00:00Z');
    const pausedAt = new Date('2026-07-15T12:00:00Z');
    const now = new Date('2026-07-17T12:00:00Z'); // paused 2 days
    expect(shiftedEndOnResume(endsAt, pausedAt, now).getTime()).toBe(endsAt.getTime() + 2 * DAY);
  });

  it('clock skew (now before paused_at) never SHORTENS the campaign', () => {
    const endsAt = new Date('2026-07-20T12:00:00Z');
    const pausedAt = new Date('2026-07-15T12:00:00Z');
    const now = new Date('2026-07-15T11:59:00Z');
    expect(shiftedEndOnResume(endsAt, pausedAt, now).getTime()).toBe(endsAt.getTime());
  });
});

describe('daysRemaining', () => {
  const now = new Date('2026-07-15T12:00:00Z');

  it('null ends_at → 0 (not yet activated)', () => {
    expect(daysRemaining(null, now)).toBe(0);
  });

  it('past ends_at → 0, never negative', () => {
    expect(daysRemaining(new Date('2026-07-10T12:00:00Z'), now)).toBe(0);
  });

  it('partial days round UP (the owner still has "1 day left" at T-6h)', () => {
    expect(daysRemaining(new Date('2026-07-15T18:00:00Z'), now)).toBe(1);
    expect(daysRemaining(new Date('2026-07-18T12:00:00Z'), now)).toBe(3);
    expect(daysRemaining(new Date('2026-07-18T13:00:00Z'), now)).toBe(4);
  });
});
