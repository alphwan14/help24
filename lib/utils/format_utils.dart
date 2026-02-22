/// Full-format price for display (e.g. 1800, 2500). No K/M abbreviation.
/// Use with prefix: 'Kes.${formatPriceFull(price)}'
String formatPriceFull(double price) {
  return price.truncate().toString();
}

/// Normalize a pay string (e.g. "KES 1800", "Kes.2500") to "Kes.XXXX" full format.
/// If the string contains a number, formats it as Kes.&lt;full&gt;; otherwise returns [pay].
String normalizePayDisplay(String pay) {
  if (pay.trim().isEmpty) return pay;
  final match = RegExp(r'[\d.,]+').firstMatch(pay);
  if (match == null) return pay;
  final numStr = match.group(0)!.replaceAll(',', '');
  final value = double.tryParse(numStr);
  if (value == null) return pay;
  return 'Kes.${formatPriceFull(value)}';
}
