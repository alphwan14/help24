import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/kenyan_phone.dart';

void main() {
  group('nationalDigitsFrom — every shape a real user types', () {
    test('local form with trunk zero', () {
      expect(KenyanPhone.nationalDigitsFrom('0712345678'), '712345678');
    });

    test('full international with plus', () {
      expect(KenyanPhone.nationalDigitsFrom('+254712345678'), '712345678');
    });

    test('international without plus', () {
      expect(KenyanPhone.nationalDigitsFrom('254712345678'), '712345678');
    });

    test('bare national number', () {
      expect(KenyanPhone.nationalDigitsFrom('712345678'), '712345678');
    });

    test('spaced and punctuated input', () {
      expect(KenyanPhone.nationalDigitsFrom('+254 712-345 678'), '712345678');
      expect(KenyanPhone.nationalDigitsFrom('(0712) 345 678'), '712345678');
    });

    test('00 international prefix', () {
      expect(KenyanPhone.nationalDigitsFrom('00254712345678'), '712345678');
    });

    /// THE regression this class was built for: the old field rendered "+254"
    /// as decoration, so users typed their whole local number underneath it
    /// and produced +2540712345678. Both double-prefix shapes must collapse.
    test('double country code, the original bug', () {
      expect(KenyanPhone.nationalDigitsFrom('2540712345678'), '712345678');
      expect(KenyanPhone.nationalDigitsFrom('+2540712345678'), '712345678');
      expect(KenyanPhone.nationalDigitsFrom('254254712345678'), '712345678');
    });

    test('letters are discarded, never accepted', () {
      expect(KenyanPhone.nationalDigitsFrom('07abc12345678'), '712345678');
    });

    test('overlong input is capped at nine digits', () {
      expect(KenyanPhone.nationalDigitsFrom('7123456789999').length, 9);
    });

    test('empty and junk input yield empty, not a crash', () {
      expect(KenyanPhone.nationalDigitsFrom(''), '');
      expect(KenyanPhone.nationalDigitsFrom('abc'), '');
      expect(KenyanPhone.nationalDigitsFrom('+'), '');
      expect(KenyanPhone.nationalDigitsFrom('000000'), '');
    });
  });

  group('isValidNational', () {
    test('accepts both live mobile ranges', () {
      expect(KenyanPhone.isValidNational('712345678'), isTrue); // Safaricom
      expect(KenyanPhone.isValidNational('733123456'), isTrue); // Airtel
      expect(KenyanPhone.isValidNational('110123456'), isTrue); // newer 01x
    });

    test('rejects non-mobile prefixes', () {
      expect(KenyanPhone.isValidNational('201234567'), isFalse); // landline
      expect(KenyanPhone.isValidNational('412345678'), isFalse);
    });

    test('rejects wrong lengths', () {
      expect(KenyanPhone.isValidNational('71234567'), isFalse); // 8
      expect(KenyanPhone.isValidNational('7123456789'), isFalse); // 10
      expect(KenyanPhone.isValidNational(''), isFalse);
    });
  });

  group('toE164 — what actually reaches the identity provider', () {
    test('produces canonical E.164 from every input shape', () {
      const expected = '+254712345678';
      for (final input in [
        '0712345678',
        '712345678',
        '254712345678',
        '+254712345678',
        '+254 712 345 678',
        '2540712345678',
      ]) {
        expect(KenyanPhone.toE164(input), expected, reason: 'input: $input');
      }
    });

    test('refuses incomplete numbers so they can never be submitted', () {
      expect(KenyanPhone.toE164('0712'), isNull);
      expect(KenyanPhone.toE164('71234567'), isNull);
    });

    test('refuses non-mobile prefixes', () {
      expect(KenyanPhone.toE164('0201234567'), isNull);
    });
  });

  group('formatting', () {
    test('groups progressively while typing', () {
      expect(KenyanPhone.formatNational('7'), '7');
      expect(KenyanPhone.formatNational('712'), '712');
      expect(KenyanPhone.formatNational('7123'), '712 3');
      expect(KenyanPhone.formatNational('712345'), '712 345');
      expect(KenyanPhone.formatNational('712345678'), '712 345 678');
    });

    test('display form carries the dial code', () {
      expect(
        KenyanPhone.formatE164ForDisplay('+254712345678'),
        '+254 712 345 678',
      );
    });

    test('masking hides the middle', () {
      expect(KenyanPhone.maskE164('+254712345678'), '+254 712 ••• 678');
    });
  });

  group('validation messaging', () {
    test('stays silent on an empty field', () {
      expect(KenyanPhone.liveError(''), isNull);
    });

    test('flags a bad prefix immediately — further typing is wasted', () {
      expect(KenyanPhone.liveError('2'), isNotNull);
      expect(KenyanPhone.liveError('4'), isNotNull);
    });

    test('does NOT nag about length while typing', () {
      expect(KenyanPhone.liveError('712'), isNull);
      expect(KenyanPhone.liveError('71234'), isNull);
    });

    test('complains about length only at submit time', () {
      expect(KenyanPhone.submitError('712'), isNotNull);
      expect(KenyanPhone.submitError(''), isNotNull);
      expect(KenyanPhone.submitError('712345678'), isNull);
    });

    test('no user-facing message names a vendor or protocol', () {
      final messages = [
        KenyanPhone.liveError('2'),
        KenyanPhone.submitError(''),
        KenyanPhone.submitError('712'),
        KenyanPhone.submitError('71234567'),
      ].whereType<String>();
      for (final m in messages) {
        expect(
          m.toLowerCase(),
          isNot(anyOf(
            contains('firebase'),
            contains('e.164'),
            contains('recaptcha'),
            contains('provider'),
          )),
          reason: 'leaky copy: $m',
        );
      }
    });
  });
}
