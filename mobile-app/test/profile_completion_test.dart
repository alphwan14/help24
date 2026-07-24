import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/profession.dart';
import 'package:help24/models/profile_completion.dart';
import 'package:help24/models/user_model.dart';
import 'package:help24/services/profession_registry.dart';

UserModel _user({
  String name = 'John Mwangi',
  String? phone,
  String photo = '',
  String bio = '',
  String profession = '',
}) =>
    UserModel(
      uid: 'u1',
      name: name,
      email: 'j@example.com',
      phone: phone,
      profileImage: photo,
      bio: bio,
      profession: profession,
    );

const _longBio =
    'Licensed electrician with eight years of experience across Nairobi.';

void main() {
  setUp(() => ProfessionRegistry.instance.resetForTest());

  group('ProfessionRegistry', () {
    test('resolves a stored key to the profession', () {
      final p = ProfessionRegistry.instance.resolve('electrician');
      expect(p?.name, 'Electrician');
    });

    test('resolves a stored DISPLAY NAME too (older rows)', () {
      expect(ProfessionRegistry.instance.resolve('Electrician')?.id, 'electrician');
    });

    test('legacy free text resolves to null but still displays verbatim', () {
      expect(ProfessionRegistry.instance.resolve('Electrical Works'), isNull);
      expect(ProfessionRegistry.instance.labelFor('Electrical Works'), 'Electrical Works');
      expect(ProfessionRegistry.instance.isConfirmed('Electrical Works'), isFalse);
    });

    test('empty in, empty out', () {
      expect(ProfessionRegistry.instance.labelFor(''), '');
      expect(ProfessionRegistry.instance.labelFor(null), '');
      expect(ProfessionRegistry.instance.isConfirmed(''), isFalse);
    });

    test('labelFor renders the canonical label, never the slug', () {
      expect(ProfessionRegistry.instance.labelFor('it-technician'), 'IT Technician');
      expect(ProfessionRegistry.instance.labelFor('salon-beauty'), 'Salon & Beauty');
    });

    test('"Other" is a real, confirmable answer', () {
      expect(ProfessionRegistry.instance.isConfirmed(Profession.otherId), isTrue);
    });

    test('server rows override the bundled list', () {
      ProfessionRegistry.instance.seedForTest(const [
        Profession(id: 'astronaut', name: 'Astronaut', sort: 1),
      ]);
      expect(ProfessionRegistry.instance.all.single.name, 'Astronaut');
      expect(ProfessionRegistry.instance.isConfirmed('astronaut'), isTrue);
    });
  });

  group('ProfileCompletion', () {
    test('a brand-new profile is not 0% — the name it signed up with counts', () {
      final c = ProfileCompletion.of(_user());
      expect(c.percent, greaterThan(0));
      expect(c.percent, lessThan(100));
      expect(c.isComplete, isFalse);
    });

    test('every active field satisfied → 100%', () {
      final c = ProfileCompletion.of(_user(
        phone: '254712345678',
        photo: 'https://cdn/x.png',
        bio: _longBio,
        profession: 'electrician',
      ));
      expect(c.percent, 100);
      expect(c.isComplete, isTrue);
      expect(c.nextStep, isNull);
    });

    test('coming-soon fields never block 100%', () {
      final complete = ProfileCompletion.of(_user(
        phone: '254712345678',
        photo: 'https://cdn/x.png',
        bio: _longBio,
        profession: 'electrician',
      ));
      expect(complete.comingSoon, isNotEmpty);
      expect(complete.percent, 100);
    });

    test('legacy free-text profession leaves the box unticked', () {
      final c = ProfileCompletion.of(_user(profession: 'Electrical Works'));
      final profession =
          c.items.firstWhere((i) => i.spec.key == 'profession');
      expect(profession.complete, isFalse);
    });

    test('a too-short bio does not count', () {
      final short = ProfileCompletion.of(_user(bio: 'Hi.'));
      expect(short.items.firstWhere((i) => i.spec.key == 'bio').complete, isFalse);
    });

    test('nextStep is the highest-weight missing field', () {
      // Photo (20) present, profession (25) and bio (25) missing → one of the
      // 25s, and profession comes first in registry order.
      final c = ProfileCompletion.of(_user(photo: 'https://cdn/x.png'));
      expect(c.nextStep?.key, 'profession');
    });

    test('the phone fallback covers a row that has not synced yet', () {
      final withFallback =
          ProfileCompletion.of(_user(), fallbackPhone: '254712345678');
      expect(
        withFallback.items.firstWhere((i) => i.spec.key == 'phone').complete,
        isTrue,
      );
    });

    test('null profile still evaluates (no crash on first paint)', () {
      expect(ProfileCompletion.of(null).percent, 0);
    });

    test('active weights sum to 100 so each weight reads as a percentage point',
        () {
      final active = ProfileCompletion.fields.where((f) => f.isActive);
      expect(active.fold<int>(0, (sum, f) => sum + f.weight), 100);
    });

    test('sectionItems only returns active fields of that section', () {
      final c = ProfileCompletion.of(_user());
      final personal = c.sectionItems(ProfileSection.personal);
      expect(personal.map((i) => i.spec.key), ['photo', 'name', 'phone']);
      expect(personal.every((i) => i.spec.isActive), isTrue);
    });

    test('field keys are unique (they are analytics/deep-link identifiers)', () {
      final keys = ProfileCompletion.fields.map((f) => f.key).toList();
      expect(keys.toSet().length, keys.length);
    });
  });
}
