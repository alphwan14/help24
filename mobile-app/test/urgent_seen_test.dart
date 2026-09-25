import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/urgent_seen_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE URGENT COUNT MEANS "NOT SEEN", NOT "OPEN".
///
/// WHAT WENT WRONG
/// ---------------
/// Discover's `Urgent · N` counted every emergency whose window was still open.
/// That is a true fact, drawn in a shape that means something else: a red count
/// says *N things you have not dealt with*. So the number never moved — open
/// the list, read the request, come back, still `Urgent · 1`.
///
/// A badge that does not respond to being looked at teaches people to stop
/// looking, which is the one outcome an emergency surface cannot afford.
/// Reported from the device, and correctly.
///
/// The entry point itself is unaffected: `Urgent` stays in the header whether
/// or not anything is new, because the screen behind it is still worth
/// reaching. What decays is the COUNT.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = UrgentSeenStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store.debugReset();
    await store.ensureLoaded();
  });

  group('the count decays on being looked at', () {
    test('everything open is unseen to begin with', () {
      expect(store.unseenCount(['a', 'b', 'c']), 3);
    });

    test('seeing the list takes the count to zero', () async {
      await store.markSeen(['a', 'b', 'c']);
      expect(store.unseenCount(['a', 'b', 'c']), 0);
    });

    test('a NEW emergency still counts after the others were seen', () async {
      await store.markSeen(['a', 'b']);
      // 'c' arrived afterwards. This is the case the whole change exists for:
      // the badge has to be able to come back.
      expect(store.unseenCount(['a', 'b', 'c']), 1);
    });
  });

  group('the set stays bounded', () {
    test('ids whose window closed are forgotten', () async {
      await store.markSeen(['a', 'b', 'c']);
      expect(store.debugSeen, {'a', 'b', 'c'});

      // 'a' and 'b' expired; only 'c' is still open, and 'd' is new.
      await store.markSeen(['c', 'd']);
      expect(store.debugSeen, {'c', 'd'},
          reason: 'a seen id that is no longer open can never be counted '
              'again, so keeping it would only grow the set forever');
    });

    test('an id that expires and is re-posted counts as new', () async {
      await store.markSeen(['a']);
      // 'a' closed. The set is pruned the next time anything is seen.
      await store.markSeen(['b']);
      expect(store.unseenCount(['a']), 1);
    });
  });

  group('persistence', () {
    test('a seen set survives a restart', () async {
      await store.markSeen(['a', 'b']);
      // Simulate a cold start against the same SharedPreferences.
      store.debugReset();
      await store.ensureLoaded();
      expect(store.unseenCount(['a', 'b']), 0);
    });
  });

  group('session ownership', () {
    test('signing out forgets what the previous account had seen', () async {
      await store.markSeen(['a', 'b']);
      store.resetForSignOut();
      expect(store.unseenCount(['a', 'b']), 2,
          reason: 'the next person to use this device has not seen anything');
    });

    test('resetForSignOut does not throw and does not await', () {
      // The SessionScoped contract: sign-out can never be blocked by cleanup.
      expect(store.resetForSignOut, returnsNormally);
    });
  });

  group('it notifies, so the chip can move', () {
    test('marking seen tells listeners', () async {
      var notified = 0;
      void listener() => notified++;
      store.addListener(listener);
      addTearDown(() => store.removeListener(listener));

      await store.markSeen(['a']);
      expect(notified, greaterThan(0));

      // Marking the same set again changes nothing, so it must not churn
      // every listener on every rebuild of the urgent list.
      final settled = notified;
      await store.markSeen(['a']);
      expect(notified, settled);
    });
  });
}
