import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/phone_utils.dart';

void main() {
  group('normalizeKenyanNumber', () {
    test('accepts the three common Kenyan formats', () {
      expect(normalizeKenyanNumber('0712345678'), '254712345678');
      expect(normalizeKenyanNumber('+254712345678'), '254712345678');
      expect(normalizeKenyanNumber('254712345678'), '254712345678');
      expect(normalizeKenyanNumber('712345678'), '254712345678');
    });

    test('rejects garbage', () {
      expect(normalizeKenyanNumber(''), isNull);
      expect(normalizeKenyanNumber('12345'), isNull);
      expect(normalizeKenyanNumber('notaphone'), isNull);
    });
  });

  group('maskPhone (profile Payment Settings subtitle)', () {
    test('masks the middle, keeps prefix and suffix', () {
      expect(maskPhone('254712345678'), '254••••••678');
    });

    test('short values are returned unchanged rather than nonsensically masked', () {
      expect(maskPhone('12345'), '12345');
      expect(maskPhone(''), '');
    });
  });
}
