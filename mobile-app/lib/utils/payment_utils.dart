// Fee tiers mirror backend/src/mpesa/fee.ts exactly.
// Any change must be reflected in both files.
const List<_FeeTier> _feeTiers = [
  _FeeTier(max: 1000, fee: 20),
  _FeeTier(max: 5000, fee: 45),
  _FeeTier(max: 15000, fee: 95),
  _FeeTier(max: 30000, fee: 195),
  _FeeTier(max: 50000, fee: 295),
];

class _FeeTier {
  final int max;
  final int fee;
  const _FeeTier({required this.max, required this.fee});
}

/// Returns the platform fee in KES for the given [amount] (also in KES).
/// Matches backend calculateFee() in fee.ts.
double calculatePlatformFee(double amount) {
  if (amount <= 0) return 0;
  final amountInt = amount.round();
  for (final tier in _feeTiers) {
    if (amountInt <= tier.max) return tier.fee.toDouble();
  }
  return 295;
}

/// Returns the total the buyer pays (amount + platform fee).
double calculateTotal(double amount) => amount + calculatePlatformFee(amount);
