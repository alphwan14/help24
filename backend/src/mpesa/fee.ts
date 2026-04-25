// Fee tiers are mirrored in lib/utils/payment_utils.dart.
// Any change here must be reflected there.
const FEE_TIERS: Array<{ max: number; fee: number }> = [
  { max: 1_000,  fee: 20  },
  { max: 5_000,  fee: 45  },
  { max: 15_000, fee: 95  },
  { max: 30_000, fee: 195 },
  { max: 50_000, fee: 295 },
];

export function calculateFee(amount: number): number {
  if (amount < 100) {
    throw new RangeError(`Amount must be at least 100 KES (received ${amount})`);
  }
  for (const tier of FEE_TIERS) {
    if (amount <= tier.max) return tier.fee;
  }
  return 295;
}

export function calculateTotal(amount: number): number {
  return amount + calculateFee(amount);
}
