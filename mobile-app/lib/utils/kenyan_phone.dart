import 'package:flutter/services.dart';

/// Kenyan mobile numbers, modelled properly.
///
/// THE PROBLEM THIS SOLVES
/// -----------------------
/// The old phone step showed a field whose `prefixText` was a decorative
/// "+254 " while the field itself still accepted `+254…`, `254…`, `07…` and
/// `7…`. So the screen said `+254` and the user, reading it as a label rather
/// than a value, typed `0712345678` underneath — producing `+2540712345678`.
/// Others typed `254712345678` and got `+254254712345678`. Validation was a
/// single `length < 12` check, which happily accepted both.
///
/// The fix is to make the country code STRUCTURAL, not decorative: `+254`
/// lives outside the editable region, the field holds ONLY the 9-digit
/// national number, and every paste/keyboard path is funnelled through
/// [nationalDigitsFrom] so `0712…`, `254712…` and `+254 712…` all collapse to
/// the same nine digits.
///
/// WHAT COUNTS AS VALID (Kenya, Communications Authority allocations)
///   * National significant number: 9 digits.
///   * Mobile prefixes: 7XX (Safaricom, Airtel, Telkom) and 1XX (the newer
///     011x/010x ranges Safaricom and Airtel now issue).
///   * So: `7XXXXXXXX` or `1XXXXXXXX` — nothing else is a mobile line, and an
///     SMS code to a landline or shortcode will never arrive.
class KenyanPhone {
  KenyanPhone._();

  /// Kenya, +254. Displayed beside the field, never inside it.
  static const String dialCode = '+254';
  static const String countryName = 'Kenya';
  static const String flagEmoji = '🇰🇪';

  /// A Kenyan national significant number is exactly 9 digits.
  static const int nationalLength = 9;

  /// Mobile prefixes in service. First digit of the national number.
  static const Set<String> mobileLeadingDigits = {'7', '1'};

  /// Reduce ANY user input to the national 9-digit form, discarding whichever
  /// country-code shape they typed or pasted.
  ///
  /// `0712 345 678` → `712345678`
  /// `+254 712 345 678` → `712345678`
  /// `254712345678` → `712345678`
  /// `712345678` → `712345678`
  ///
  /// Never throws and never over-trims: the result is capped at 9 digits so a
  /// long paste cannot smuggle extra characters past the length rule.
  static String nationalDigitsFrom(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');

    // Strip the country code in whichever form it arrived. Order matters:
    // `254` must be tested before the leading `0`, because `2540712…` is a
    // real thing users produce by typing 0 under a +254 prefix.
    if (digits.startsWith('254')) {
      digits = digits.substring(3);
    } else if (digits.startsWith('00254')) {
      digits = digits.substring(5);
    }
    // A national trunk 0 is not part of the international form.
    while (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    // Handles the `2540712…` double-prefix case above, where stripping `254`
    // exposes a trunk zero that then exposes the real number.
    if (digits.startsWith('254') && digits.length > nationalLength) {
      digits = digits.substring(3);
    }

    if (digits.length > nationalLength) {
      digits = digits.substring(0, nationalLength);
    }
    return digits;
  }

  /// True when [nationalDigits] is a complete, dialable Kenyan mobile number.
  static bool isValidNational(String nationalDigits) {
    if (nationalDigits.length != nationalLength) return false;
    return mobileLeadingDigits.contains(nationalDigits[0]);
  }

  /// The E.164 number to hand to the identity provider: `+254712345678`.
  /// Returns null unless the input is a complete valid mobile number, so a
  /// half-typed number can never be sent for verification.
  static String? toE164(String raw) {
    final national = nationalDigitsFrom(raw);
    if (!isValidNational(national)) return null;
    return '$dialCode$national';
  }

  /// Progressive display formatting: `712345678` → `712 345 678`.
  /// Applied as the user types, so the number is readable at every length.
  static String formatNational(String nationalDigits) {
    final d = nationalDigits;
    if (d.length <= 3) return d;
    if (d.length <= 6) return '${d.substring(0, 3)} ${d.substring(3)}';
    return '${d.substring(0, 3)} ${d.substring(3, 6)} ${d.substring(6)}';
  }

  /// Full display form for confirmations and the OTP screen header:
  /// `+254 712 345 678`.
  static String formatE164ForDisplay(String e164) {
    final national = nationalDigitsFrom(e164);
    if (national.isEmpty) return e164;
    return '$dialCode ${formatNational(national)}';
  }

  /// Inline validation while typing. Returns null when there is nothing worth
  /// saying yet — the field stays calm until the user has committed enough
  /// input for an error to be fair.
  ///
  /// This is the "banking app" behaviour: complain about a bad PREFIX
  /// immediately (the user is on the wrong track and every further keystroke
  /// is wasted), but stay silent about LENGTH until they stop typing.
  static String? liveError(String nationalDigits) {
    if (nationalDigits.isEmpty) return null;
    if (!mobileLeadingDigits.contains(nationalDigits[0])) {
      return 'Kenyan mobile numbers start with 7 or 1.';
    }
    return null;
  }

  /// Validation for submit time, when silence is no longer acceptable.
  static String? submitError(String nationalDigits) {
    if (nationalDigits.isEmpty) return 'Enter your phone number.';
    if (!mobileLeadingDigits.contains(nationalDigits[0])) {
      return 'Kenyan mobile numbers start with 7 or 1.';
    }
    if (nationalDigits.length < nationalLength) {
      final missing = nationalLength - nationalDigits.length;
      return missing == 1
          ? 'One more digit to go.'
          : 'That number is too short — $missing digits to go.';
    }
    return null;
  }

  /// `+254 712 •••  •78`-style masking for confirmation screens where the
  /// number is shown but should not be fully readable over a shoulder.
  static String maskE164(String e164) {
    final national = nationalDigitsFrom(e164);
    if (national.length != nationalLength) return e164;
    return '$dialCode ${national.substring(0, 3)} ••• ${national.substring(6)}';
  }
}

/// Keeps a phone field holding ONLY a formatted Kenyan national number, no
/// matter what the user types, pastes, or auto-fills.
///
/// Doing this in a formatter rather than an `onChanged` handler is what makes
/// the field feel native: the illegal state never renders for a frame, the
/// caret lands where the user expects after a paste, and the hardware keyboard
/// path behaves the same as the on-screen one.
class KenyanPhoneInputFormatter extends TextInputFormatter {
  const KenyanPhoneInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final national = KenyanPhone.nationalDigitsFrom(newValue.text);
    final formatted = KenyanPhone.formatNational(national);

    // Preserve the caret's logical position: count the digits before it in the
    // new raw text, then find where that many digits sit in the formatted
    // string. Without this, typing mid-number throws the caret to the end.
    final rawBeforeCaret = newValue.text.substring(0, newValue.selection.end.clamp(0, newValue.text.length));
    final digitsBeforeCaret = KenyanPhone.nationalDigitsFrom(rawBeforeCaret).length;

    var offset = formatted.length;
    var seen = 0;
    for (var i = 0; i < formatted.length; i++) {
      if (seen >= digitsBeforeCaret) {
        offset = i;
        break;
      }
      if (formatted[i] != ' ') seen++;
    }
    if (seen < digitsBeforeCaret) offset = formatted.length;

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset.clamp(0, formatted.length)),
    );
  }
}
