import {
  ADVANCE_MIN_JOB_KES,
  advanceAmountFor,
  advanceEligibility,
  advanceEnabled,
  advanceInFlight,
  advancePaidOut,
  canRelease,
  heldJobAmount,
  isMissingTable,
  releaseRefusal,
} from './advance';
import { calculateFee } from './fee';

describe('Materials Advance rules', () => {
  it('is off unless MATERIALS_ADVANCE_ENABLED is exactly true', () => {
    expect(advanceEnabled(undefined)).toBe(false);
    expect(advanceEnabled('')).toBe(false);
    expect(advanceEnabled('false')).toBe(false);
    expect(advanceEnabled('1')).toBe(false);
    expect(advanceEnabled(' TRUE ')).toBe(true);
  });

  it('is 40% of the job, rounded down to the shilling', () => {
    expect(advanceAmountFor(10_000)).toBe(4_000);
    expect(advanceAmountFor(12_345)).toBe(4_938); // 4,938.0
    expect(advanceAmountFor(10_001)).toBe(4_000); // 4,000.4 rounds down
    expect(advanceAmountFor(50_000)).toBe(20_000);
  });

  it('needs the switch, a job of KES 10,000 or more, and a verified provider', () => {
    const base = { enabled: true, jobAmount: ADVANCE_MIN_JOB_KES, providerIdVerified: true };
    expect(advanceEligibility(base)).toEqual({ eligible: true, reason: null });
    expect(advanceEligibility({ ...base, enabled: false })).toEqual({ eligible: false, reason: 'disabled' });
    expect(advanceEligibility({ ...base, jobAmount: 9_999 })).toEqual({ eligible: false, reason: 'too_small' });
    expect(advanceEligibility({ ...base, providerIdVerified: false })).toEqual({ eligible: false, reason: 'provider_not_verified' });
  });

  it('subtracts an advance from what is held only once M-Pesa confirmed it', () => {
    const row = (status: string) => ({ status: status as never, amount: 4_000 });
    expect(advancePaidOut(null)).toBe(0);
    expect(advancePaidOut(row('held'))).toBe(0);
    expect(advancePaidOut(row('sending'))).toBe(0);
    expect(advancePaidOut(row('cancelled'))).toBe(0);
    expect(advancePaidOut(row('frozen'))).toBe(0);
    expect(advancePaidOut(row('paid_out'))).toBe(4_000);
    expect(heldJobAmount(10_000, row('paid_out'))).toBe(6_000);
    expect(heldJobAmount(10_000, row('held'))).toBe(10_000);
    expect(advanceInFlight(row('sending'))).toBe(true);
    expect(advanceInFlight(row('paid_out'))).toBe(false);
  });

  it('a failed job after the advance refunds the held 60% plus the fee', () => {
    const job = 10_000;
    const fee = calculateFee(job); // 500
    const paidOut = { status: 'paid_out' as const, amount: advanceAmountFor(job) };
    const totalPaid = job + fee;
    expect(totalPaid - advancePaidOut(paidOut)).toBe(heldJobAmount(job, paidOut) + fee); // 6,500
  });

  it('the one fee covers collection, BOTH payouts and still leaves Help24 a profit', () => {
    // Owner tariff table (2026-11-10): combined M-Pesa cost of one collection
    // plus ONE payout of the whole job. An advance adds a second payout.
    // Worst case assumed here: that second payout costs as much as the whole
    // collection-plus-payout again (real B2C is quoted at KES 5 to 13).
    const oneWay: Array<[number, number]> = [[10_000, 104], [20_000, 158], [50_000, 255]];
    for (const [job, cost] of oneWay) {
      const fee = calculateFee(job);
      const worstCase = cost * 2;
      expect(fee - worstCase).toBeGreaterThan(250); // 10k: 292, 20k: 684, 50k: 490
      expect(advanceAmountFor(job) + (job - advanceAmountFor(job))).toBe(job); // the fundi still gets 100%
    }
  });

  it('releases only a held advance on a confirmed, undisputed payment', () => {
    const held = { status: 'held' as const };
    expect(canRelease({ row: held, txStatus: 'paid', activeDispute: false })).toEqual({ ok: true, reason: null });
    expect(canRelease({ row: null, txStatus: 'paid', activeDispute: false })).toEqual({ ok: false, reason: 'no_advance' });
    expect(canRelease({ row: held, txStatus: 'pending', activeDispute: false })).toEqual({ ok: false, reason: 'payment_not_confirmed' });
    expect(canRelease({ row: held, txStatus: 'payout_pending', activeDispute: false })).toEqual({ ok: false, reason: 'payment_not_confirmed' });
    expect(canRelease({ row: held, txStatus: 'disputed', activeDispute: true })).toEqual({ ok: false, reason: 'disputed' });
    expect(canRelease({ row: { status: 'paid_out' }, txStatus: 'paid', activeDispute: false })).toEqual({ ok: false, reason: 'not_held' });
  });

  it('explains every refusal in plain copy', () => {
    for (const r of ['no_advance', 'not_held', 'payment_not_confirmed', 'disputed'] as const) {
      const text = releaseRefusal(r);
      expect(text.length).toBeGreaterThan(10);
      expect(text).not.toMatch(/—/);
    }
  });

  it('treats only a missing materials_advances table as "no advance"', () => {
    expect(isMissingTable({ code: '42P01' })).toBe(true);
    expect(isMissingTable({ code: 'PGRST205', message: "Could not find the table 'public.materials_advances'" })).toBe(true);
    expect(isMissingTable({ message: 'relation "public.materials_advances" does not exist' })).toBe(true);
    expect(isMissingTable({ code: '42703', message: 'column materials_advances.amount does not exist' })).toBe(false);
    expect(isMissingTable({ message: 'fetch failed' })).toBe(false);
    expect(isMissingTable(null)).toBe(false);
  });
});
