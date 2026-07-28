import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/feature_errors.dart';

/// Regression suite: ONE FEATURE'S FAILURE IS NEVER ANOTHER FEATURE'S.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// `AppProvider` held ONE `String? _error` that five features wrote and four
/// read: the Discover feed, the Jobs tab, post/job creation, post deletion and
/// chat creation. A single slot with many owners fails in two directions, and
/// Help24 had both:
///
///   * CONTAMINATION — `createPost` fails and sets the slot; Discover's feed is
///     empty (a new account, or filters matching nothing), so the feed renders
///     `ErrorRetryView` with a POSTING message above a Retry button that
///     reloads the feed. Wrong feature, wrong message, wrong remedy.
///
///   * ERASURE — every loader cleared the slot on entry. `loadPosts` and
///     `loadJobs` run concurrently under one `Future.wait`, so whichever
///     started second wiped the other's error before anything rendered it. And
///     any feed reload destroyed the message from a failed post creation before
///     `PostScreen` could read it, which is why a failed post could surface as
///     the generic fallback string instead of the real reason.
///
/// The tests below are written as those two scenarios, not as map mechanics.
void main() {
  group('contamination is impossible', () {
    test("a posting failure never appears as Discover's", () {
      final errors = FeatureErrors();

      // createPost fails.
      errors.set(AppFeature.posting, 'Could not save. Please try again.');

      // Discover renders. It must see nothing.
      expect(errors[AppFeature.discover], isNull);
      expect(errors[AppFeature.jobs], isNull);
      expect(errors[AppFeature.messages], isNull);
      expect(errors[AppFeature.posting], 'Could not save. Please try again.');
    });

    test('a chat-list failure never appears as a feed failure', () {
      final errors = FeatureErrors();

      errors.set(AppFeature.messages, "Couldn't load your chats.");

      expect(errors[AppFeature.discover], isNull);
      expect(errors[AppFeature.jobs], isNull);
    });

    test('every feature can fail at once, each with its own message', () {
      final errors = FeatureErrors();

      for (final feature in AppFeature.values) {
        errors.set(feature, 'failure in ${feature.name}');
      }

      for (final feature in AppFeature.values) {
        expect(errors[feature], 'failure in ${feature.name}');
      }
      expect(errors.failing.toSet(), AppFeature.values.toSet());
    });
  });

  group('erasure is impossible', () {
    test('a concurrent load cannot wipe another feature error', () {
      final errors = FeatureErrors();

      // Discover's fetch fails...
      errors.set(AppFeature.discover, 'Feed unavailable.');
      // ...while the Jobs load starts and clears ITS slot, as loaders do.
      // These two genuinely run concurrently under one Future.wait.
      errors.clear(AppFeature.jobs);

      expect(errors[AppFeature.discover], 'Feed unavailable.',
          reason: "Jobs starting must not erase Discover's failure");
    });

    test('a feed reload cannot wipe a posting failure mid-flight', () {
      final errors = FeatureErrors();

      // createPost failed and PostScreen is about to read the reason.
      errors.set(AppFeature.posting, 'Could not save. Please try again.');
      // A feed reload fires first (any notifyListeners can trigger one).
      errors.clear(AppFeature.discover);

      expect(errors[AppFeature.posting], 'Could not save. Please try again.',
          reason: 'the real reason must survive to reach PostScreen');
    });

    test('clearing one slot leaves every other untouched', () {
      final errors = FeatureErrors();
      for (final feature in AppFeature.values) {
        errors.set(feature, feature.name);
      }

      errors.clear(AppFeature.discover);

      expect(errors[AppFeature.discover], isNull);
      for (final feature in AppFeature.values.where((f) => f != AppFeature.discover)) {
        expect(errors[feature], feature.name);
      }
    });
  });

  group('slot mechanics', () {
    test('a fresh holder is entirely healthy', () {
      final errors = FeatureErrors();
      expect(errors.isEmpty, isTrue);
      for (final feature in AppFeature.values) {
        expect(errors[feature], isNull);
        expect(errors.has(feature), isFalse);
      }
    });

    test('set reports whether anything changed', () {
      final errors = FeatureErrors();

      expect(errors.set(AppFeature.discover, 'boom'), isTrue);
      expect(errors.set(AppFeature.discover, 'boom'), isFalse,
          reason: 'the same message twice is not a change — no rebuild needed');
      expect(errors.set(AppFeature.discover, 'different'), isTrue);
      expect(errors.clear(AppFeature.discover), isTrue);
      expect(errors.clear(AppFeature.discover), isFalse,
          reason: 'clearing an already-clear slot is the common case on load');
    });

    test('null and empty both mean healthy', () {
      final errors = FeatureErrors();

      errors.set(AppFeature.jobs, '');
      expect(errors[AppFeature.jobs], isNull);
      expect(errors.has(AppFeature.jobs), isFalse);

      errors.set(AppFeature.jobs, 'real');
      errors.set(AppFeature.jobs, null);
      expect(errors.has(AppFeature.jobs), isFalse);
    });

    test('a later failure replaces the earlier one for that feature', () {
      final errors = FeatureErrors();
      errors.set(AppFeature.discover, 'first');
      errors.set(AppFeature.discover, 'second');
      expect(errors[AppFeature.discover], 'second');
    });
  });

  group('sign-out drops everything', () {
    test('clearAll empties every slot', () {
      final errors = FeatureErrors();
      for (final feature in AppFeature.values) {
        errors.set(feature, 'x');
      }

      expect(errors.clearAll(), isTrue);
      expect(errors.isEmpty, isTrue);
      for (final feature in AppFeature.values) {
        expect(errors[feature], isNull);
      }
    });

    test('clearAll on a healthy holder reports no change', () {
      expect(FeatureErrors().clearAll(), isFalse);
    });
  });

  group('the feature list itself', () {
    test('covers every surface whose error lives in AppProvider', () {
      // Notifications, Profile, Applications, Saved and the job-lifecycle
      // screens are absent ON PURPOSE — they already hold their own local
      // _error and were never part of the shared slot. Adding them here would
      // centralise state that is correctly local.
      expect(
        AppFeature.values.map((f) => f.name).toSet(),
        {'discover', 'jobs', 'urgent', 'messages', 'posting'},
      );
    });
  });
}
