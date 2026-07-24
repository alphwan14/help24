import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/models/user_model.dart';
import 'package:help24/services/profession_registry.dart';
import 'package:help24/widgets/provider_gate.dart';

void main() {
  setUp(() => ProfessionRegistry.instance.resetForTest());

  group('Application carries the applicant profession', () {
    test('parsed from the users join', () {
      final app = Application.fromJson({
        'id': 'a1',
        'post_id': 'p1',
        'applicant_user_id': 'u1',
        'message': 'hi',
        'proposed_price': 0,
        'created_at': '2026-07-24T10:00:00Z',
        'users': {
          'name': 'John Mwangi',
          'profile_image': 'https://cdn/x.png',
          'profession': 'electrician',
        },
      });
      expect(app.applicantProfession, 'electrician');
      expect(ProfessionRegistry.instance.labelFor(app.applicantProfession),
          'Electrician');
    });

    test('absent profession degrades to empty, never a crash', () {
      final app = Application.fromJson({
        'id': 'a1',
        'applicant_user_id': 'u1',
        'message': '',
        'proposed_price': 0,
        'created_at': '2026-07-24T10:00:00Z',
        'users': {'name': 'John Mwangi'},
      });
      expect(app.applicantProfession, '');
    });

    test('no users join at all still parses', () {
      final app = Application.fromJson({
        'id': 'a1',
        'applicant_user_id': 'u1',
        'message': '',
        'proposed_price': 0,
        'created_at': '2026-07-24T10:00:00Z',
      });
      expect(app.applicantProfession, '');
    });

    test('survives the offline cache round-trip', () {
      final original = Application(
        id: 'a1',
        postId: 'p1',
        applicantName: 'John Mwangi',
        applicantAvatarUrl: 'https://cdn/x.png',
        applicantProfession: 'plumber',
        applicantUserId: 'u1',
        message: 'hi',
        proposedPrice: 500,
        timestamp: DateTime.utc(2026, 7, 24),
      );
      final restored = Application.fromJson(original.toCacheMap());
      expect(restored.applicantProfession, 'plumber');
      expect(restored.applicantName, 'John Mwangi');
    });
  });

  group('ProviderReadiness — the become-a-provider gate', () {
    UserModel user({String profession = '', String? phone}) => UserModel(
          uid: 'u1',
          name: 'John Mwangi',
          email: 'j@example.com',
          phone: phone,
          profession: profession,
        );

    test('a browsing user is not provider-ready and is missing both steps', () {
      final r = ProviderReadiness.of(user());
      expect(r.isReady, isFalse);
      expect(r.missing, [ProviderRequirement.profession, ProviderRequirement.phone]);
    });

    test('confirmed profession + phone → ready', () {
      final r = ProviderReadiness.of(
          user(profession: 'electrician', phone: '254712345678'));
      expect(r.isReady, isTrue);
      expect(r.missing, isEmpty);
    });

    test('legacy free-text profession does NOT satisfy the gate', () {
      final r = ProviderReadiness.of(
          user(profession: 'Electrical Works', phone: '254712345678'));
      expect(r.missing, [ProviderRequirement.profession]);
    });

    test('"Other" is a legitimate answer and satisfies the gate', () {
      final r =
          ProviderReadiness.of(user(profession: 'other', phone: '254712345678'));
      expect(r.isReady, isTrue);
    });

    test('phone missing on the row falls back to the auth session number', () {
      final r = ProviderReadiness.of(
        user(profession: 'plumber'),
        fallbackPhone: '254712345678',
      );
      expect(r.isReady, isTrue);
    });

    test('a null profile is not treated as ready', () {
      expect(ProviderReadiness.of(null).isReady, isFalse);
    });
  });
}
