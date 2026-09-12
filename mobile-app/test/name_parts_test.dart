import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/name_validator.dart';

/// The signup form asks for a first name and a last name; the database holds
/// ONE `name`.
///
/// THE PROPERTY BEING DEFENDED
/// ---------------------------
/// Splitting the form must not split the data. Every test below exists to
/// prove that [NameValidator.checkParts] is the same validator as
/// [NameValidator.check] wearing two input boxes: the same names are accepted,
/// the same handles are rejected, and the value that comes out the far end is
/// byte-identical to what the single field would have produced. If that ever
/// stops being true, accounts created before and after this change stop
/// agreeing on what a Help24 name is.
void main() {
  group('the stored value is unchanged by the split', () {
    test('two fields normalize to exactly what one field produced', () {
      for (final pair in const [
        ['john', 'mwangi'],
        ['  MARY ', ' WANJIKU '],
        ['jean-pierre', "o'brien"],
        ['ludwig', 'van beethoven'],
        ['ann', 'mcdonald'],
      ]) {
        final parts = NameValidator.checkParts(pair[0], pair[1]);
        final single = NameValidator.check('${pair[0]} ${pair[1]}');
        expect(parts.ok, isTrue, reason: '${pair[0]} ${pair[1]}');
        expect(single.ok, isTrue, reason: '${pair[0]} ${pair[1]}');
        expect(parts.normalized, single.normalized);
      }
    });

    test('capitalization still lands where it should', () {
      expect(NameValidator.checkParts('john', 'MWANGI').normalized,
          'John Mwangi');
      expect(NameValidator.checkParts('ann', 'mcdonald').normalized,
          'Ann McDonald');
      expect(NameValidator.checkParts('ludwig', 'van beethoven').normalized,
          'Ludwig van Beethoven');
    });
  });

  group('a rejection points at the field that caused it', () {
    test('an empty first name blames the first name', () {
      final r = NameValidator.checkParts('', 'Mwangi');
      expect(r.ok, isFalse);
      expect(r.firstError, isNotNull);
      expect(r.lastError, isNull);
      expect(r.firstError, contains('first name'));
    });

    test('an empty last name blames the last name', () {
      final r = NameValidator.checkParts('John', '');
      expect(r.ok, isFalse);
      expect(r.lastError, isNotNull);
      expect(r.firstError, isNull);
      expect(r.lastError, contains('last name'));
    });

    test('digits and symbols are named as such, per field', () {
      expect(NameValidator.checkParts('J0hn', 'Mwangi').firstError,
          contains('letters only'));
      expect(NameValidator.checkParts('John', 'Mw@ngi').lastError,
          contains('letters only'));
    });

    test('a single initial is not a name', () {
      // The single-field validator called this "enter your first and last
      // name"; with two boxes the true complaint is about one of them.
      final r = NameValidator.checkParts('John', 'M');
      expect(r.ok, isFalse);
      expect(r.lastError, isNotNull);
    });

    test('a handle is a whole-name judgement, not a field one', () {
      final r = NameValidator.checkParts('Money', 'Maker');
      expect(r.ok, isFalse);
      // Neither half is individually wrong — "Money" is a legal word and
      // "Maker" is a real surname. Only the pair reads as a handle, so the
      // error belongs to the pair.
      expect(r.firstError, isNull);
      expect(r.lastError, isNull);
      expect(r.error, isNotNull);
    });
  });

  group('real names survive', () {
    test('names that merely contain a vanity word are accepted', () {
      // The rule that matters most: false positives are worse than false
      // negatives. Rejecting Martin King to catch KingBoss is a bug.
      for (final pair in const [
        ['Martin', 'King'],
        ['Grace', 'Wanjiru'],
        ['Kingsley', 'Omondi'],
        ['Bosco', 'Kimani'],
      ]) {
        expect(NameValidator.checkParts(pair[0], pair[1]).ok, isTrue,
            reason: '${pair[0]} ${pair[1]}');
      }
    });

    test('a multi-word surname is one field, not two names', () {
      final r = NameValidator.checkParts('Maria', 'de la Cruz');
      expect(r.ok, isTrue);
      expect(r.normalized, 'Maria de la Cruz');
    });
  });

  test('message() surfaces one sentence, first field first', () {
    final r = NameValidator.checkParts('', '');
    expect(r.message, r.firstError);
    expect(r.message, isNotNull);
  });

  test('an accepted name reports no message at all', () {
    final r = NameValidator.checkParts('John', 'Mwangi');
    expect(r.ok, isTrue);
    expect(r.message, isNull);
    expect(r.normalized, 'John Mwangi');
  });
}
