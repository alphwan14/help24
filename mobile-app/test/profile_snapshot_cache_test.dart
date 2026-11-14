import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/profile_snapshot_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ProfileSnapshotCache.load(await SharedPreferences.getInstance());
    await ProfileSnapshotCache.clear();
  });

  test('setup facts survive into the next session through preferences', () async {
    ProfileSnapshotCache.rememberSetup(
      'u1',
      const ProfileSetupFacts(idVerified: true, hasPayout: false, payoutAvailable: true),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile_setup_v1_u1'), isNotNull);

    final facts = ProfileSnapshotCache.setup('u1');
    expect(facts?.idVerified, isTrue);
    expect(facts?.hasPayout, isFalse);
  });

  test('nothing is known for an account this phone has not seen', () {
    expect(ProfileSnapshotCache.setup('stranger'), isNull);
    expect(ProfileSnapshotCache.user('stranger'), isNull);
    expect(ProfileSnapshotCache.user(''), isNull);
  });

  test('signing out forgets every account', () async {
    ProfileSnapshotCache.rememberSetup('u1', const ProfileSetupFacts(idVerified: true));
    ProfileSnapshotCache.rememberRow('u1', {'id': 'u1', 'name': 'Amina'});
    await ProfileSnapshotCache.clear();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('profile_')), isEmpty);
    expect(ProfileSnapshotCache.setup('u1'), isNull);
  });
}
