import { calculateFee, calculateTotal, FEE_MAX_KES, FEE_MIN_KES } from './fee';

/**
 * THE GOLDEN TABLE. mobile-app/test/payment_utils_test.dart holds the same
 * rows: the app shows the fee, this file charges it, and the two must agree
 * to the shilling or the M-Pesa prompt contradicts the screen before it.
 * [job, fee] in whole KES.
 */
const GOLDEN: Array<[number, number]> = [
  [100, 30], // floor
  [300, 30],
  [599, 30],
  [600, 30], // 5% meets the floor
  [610, 31], // 30.5 rounds up
  [1_000, 50],
  [1_010, 51], // 50.5 rounds up
  [1_234, 62], // 61.7
  [2_500, 125],
  [5_000, 250],
  [10_000, 500],
  [19_990, 1_000], // 999.5 rounds up to the cap
  [20_000, 1_000], // 5% meets the cap
  [50_000, 1_000], // capped
  [150_000, 1_000],
];

describe('calculateFee: 5% of the job, minimum KES 30, maximum KES 1,000', () => {
  it.each(GOLDEN)('KES %i pays a fee of KES %i', (job, fee) => {
    expect(calculateFee(job)).toBe(fee);
    expect(calculateTotal(job)).toBe(job + fee);
  });

  it('never charges less than the floor or more than the cap', () => {
    for (let job = 100; job <= 60_000; job += 7) {
      const fee = calculateFee(job);
      if (fee < FEE_MIN_KES || fee > FEE_MAX_KES) throw new Error(`KES ${job} -> fee ${fee}`);
    }
  });

  it('never makes a dearer job cheaper in total (no cliff at any price)', () => {
    let last = 0;
    let firstCliff: number | null = null;
    for (let job = 100; job <= 60_000 && firstCliff === null; job += 1) {
      const total = calculateTotal(job);
      if (total <= last) firstCliff = job;
      last = total;
    }
    expect(firstCliff).toBeNull();
  });

  it('covers the M-Pesa cost of every job in the owner tariff table (2026-11-10)', () => {
    // [job, combined in + out cost] from the tariff table; jobs below KES 1,000
    // are held to the KES 1,000 cost, which is the most they can cost.
    const costs: Array<[number, number]> = [
      [100, 23], [300, 23], [500, 23], [1_000, 23], [2_500, 41],
      [5_000, 62], [10_000, 104], [20_000, 158], [50_000, 255],
    ];
    for (const [job, cost] of costs) expect(calculateFee(job)).toBeGreaterThan(cost);
  });

  it('refuses a job below the minimum payment', () => {
    expect(() => calculateFee(99)).toThrow(RangeError);
  });
});
