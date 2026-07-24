import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/name_validator.dart';

void main() {
  group('NameValidator — accepts genuine names', () {
    const genuine = [
      'John Mwangi',
      'Grace Wanjiku Njoroge',
      'Jean-Pierre Dubois',
      "O'Brien Kelly",
      'Ali Hassan',
      'Mary Anne Smith',
      'José García',
      'Ludwig van Beethoven',
      'Peter McDonald',
      'Anne Marie De Souza',
    ];

    for (final name in genuine) {
      test('"$name"', () {
        final r = NameValidator.check(name);
        expect(r.ok, isTrue, reason: r.error);
        expect(r.normalized, isNotEmpty);
      });
    }
  });

  group('NameValidator — rejects abuse', () {
    const rejected = {
      '': 'empty',
      '   ': 'whitespace only',
      'A': 'too short',
      'John': 'single word',
      '12345': 'digits only',
      'John254': 'digits inside',
      'CoolBoy254': 'handle with digits',
      'KingBoss': 'glued vanity handle',
      'MoneyMaker': 'glued vanity handle',
      'King Boss': 'all-vanity words',
      'Cool Boy': 'all-vanity words',
      'Mr Boss': 'title + vanity',
      '😀 😀': 'emoji',
      'John 😀': 'emoji in surname',
      '@john doe': 'symbol',
      'john_doe smith': 'underscore',
      'Aaaa Bbbb': 'repeated characters',
      'Test User': 'placeholder words',
      'admin support': 'system words',
      'A B C D E F': 'too many words',
    };

    rejected.forEach((name, why) {
      test('"$name" — $why', () {
        final r = NameValidator.check(name);
        expect(r.ok, isFalse, reason: 'expected rejection ($why)');
        expect(r.error, isNotNull);
        expect(r.error, isNotEmpty);
      });
    });
  });

  group('NameValidator — never rejects a real name that merely contains a '
      'vanity word', () {
    const safe = ['Martin King', 'Kingsley Omondi', 'Prince Otieno', 'Bosco Kamau'];
    for (final name in safe) {
      test('"$name"', () {
        expect(NameValidator.check(name).ok, isTrue);
      });
    }
  });

  group('NameValidator.normalize', () {
    const cases = {
      'john  mwangi': 'John Mwangi',
      'JOHN MWANGI': 'John Mwangi',
      '  grace   wanjiku  ': 'Grace Wanjiku',
      'jean-pierre dubois': 'Jean-Pierre Dubois',
      "o'brien kelly": "O'Brien Kelly",
      'peter mcdonald': 'Peter McDonald',
      'ludwig van beethoven': 'Ludwig van Beethoven',
    };

    cases.forEach((input, expected) {
      test('"$input" → "$expected"', () {
        expect(NameValidator.normalize(input), expected);
      });
    });

    test('check() returns the normalized form', () {
      expect(NameValidator.check('  jOHN   mwangi ').normalized, 'John Mwangi');
    });
  });

  group('NameChangePolicy', () {
    final now = DateTime(2026, 7, 24);

    test('first change is always allowed', () {
      expect(NameChangePolicy.canChange(null, now: now), isTrue);
      expect(NameChangePolicy.daysRemaining(null, now: now), 0);
    });

    test('blocked inside the 30-day window', () {
      final changed = now.subtract(const Duration(days: 5));
      expect(NameChangePolicy.canChange(changed, now: now), isFalse);
      expect(NameChangePolicy.daysRemaining(changed, now: now), 25);
      expect(
        NameChangePolicy.restrictionMessage(changed, now: now),
        contains('25 days'),
      );
    });

    test('allowed once the window elapses', () {
      final changed = now.subtract(const Duration(days: 30));
      expect(NameChangePolicy.canChange(changed, now: now), isTrue);
      expect(NameChangePolicy.daysRemaining(changed, now: now), 0);
    });

    test('singular copy on the final day', () {
      final changed = now.subtract(const Duration(days: 29));
      expect(NameChangePolicy.daysRemaining(changed, now: now), 1);
      expect(
        NameChangePolicy.restrictionMessage(changed, now: now),
        contains('tomorrow'),
      );
    });
  });
}
