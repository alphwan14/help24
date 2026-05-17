/// Full-format price for display (e.g. 1800, 2500). No K/M abbreviation.
/// Use with prefix: 'Kes.${formatPriceFull(price)}'
String formatPriceFull(double price) {
  return price.truncate().toString();
}

/// Price with thousand separators (e.g. 1000 -> "1,000"). Use for display.
String formatPriceWithCommas(double price) {
  final int v = price.truncate();
  if (v.abs() < 1000) return v.toString();
  final String s = v.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return v < 0 ? '-$buf' : buf.toString();
}

/// Display price as "KES 1,000" (exactly as stored, no division/parsing errors).
String formatPriceDisplay(double price) {
  return 'KES ${formatPriceWithCommas(price)}';
}

/// Normalize a pay string (e.g. "KES 1800", "Kes.2500") to full display format with commas.
/// Returns "KES 1,500" style so cards never show "Kes1" or "Kes2"; matches formatPriceDisplay.
String normalizePayDisplay(String pay) {
  if (pay.trim().isEmpty) return pay;
  final match = RegExp(r'[\d.,]+').firstMatch(pay);
  if (match == null) return pay;
  final numStr = match.group(0)!.replaceAll(',', '');
  final value = double.tryParse(numStr);
  if (value == null) return pay;
  return 'KES ${formatPriceWithCommas(value)}';
}
