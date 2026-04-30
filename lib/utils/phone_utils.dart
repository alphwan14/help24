/// Normalizes any Kenyan phone number to the canonical `254XXXXXXXXX` format.
///
/// Handles: `0758353999` → `254758353999`
///          `+254758353999` → `254758353999`
///          `254758353999` → `254758353999`
///
/// Returns null if the result is not a valid 12-digit `254XXXXXXXXX` string.
String? normalizeKenyanNumber(String raw) {
  // Strip spaces, dashes, parentheses, and leading +
  var phone = raw.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

  if (phone.startsWith('0') && phone.length == 10) {
    // 07XX... → 254XX...
    phone = '254${phone.substring(1)}';
  } else if (phone.startsWith('7') && phone.length == 9) {
    // 7XX... (missing country code) → 254XX...
    phone = '254$phone';
  }
  // Already starts with 254 — keep as-is.

  return _isValidKenyanNumber(phone) ? phone : null;
}

/// Returns true if [phone] matches `254XXXXXXXXX` (12 digits).
bool _isValidKenyanNumber(String phone) =>
    RegExp(r'^254\d{9}$').hasMatch(phone);

/// Validates and returns a canonical phone, or throws [ArgumentError].
String requireKenyanNumber(String raw) {
  final normalized = normalizeKenyanNumber(raw);
  if (normalized == null) {
    throw ArgumentError(
      'Invalid Kenyan phone number: "$raw". Expected format: 254XXXXXXXXX',
    );
  }
  return normalized;
}
