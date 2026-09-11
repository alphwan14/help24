import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/notification_toggle_state.dart';

/// Regression suite: ONE TAP ON THE NOTIFICATIONS SWITCH PRODUCES ONE VISIBLE
/// TRANSITION.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Traced on an SM-G986U (Android 13). Turning notifications off moved the
/// switch three times:
///
/// ```text
/// 31.555  onChanged(false)                     SWITCH=false  ← the tap
/// 31.567  watchUserPrefs() created a NEW stream
/// 32.037  db read  -> enabled=true             (issued BEFORE the write landed)
/// 32.038  db write -> enabled=false done
/// 32.438  optimistic value cleared
/// 32.448  paint streamValue=true               SWITCH=true   ← flashed back ON
/// 32.847  db read  -> enabled=false
/// 32.863  paint streamValue=false              SWITCH=false  ← settled
/// ```
///
/// The read at 32.037 was in flight while the write landed, so it described the
/// state BEFORE the change. The old code threw the user's choice away the
/// moment the write finished and fell back to that read.
///
/// Each test below walks a real event sequence and records what the switch
/// shows after every event, so an intermediate reversal fails the assertion
/// rather than hiding behind a correct final value.
void main() {
  /// Runs [events] against [start] and returns the switch position after each
  /// one, with consecutive duplicates collapsed — i.e. the transitions a user
  /// would actually SEE.
  List<bool> transitions(
    NotificationToggleState start,
    List<NotificationToggleState Function(NotificationToggleState)> events,
  ) {
    var state = start;
    final seen = <bool>[state.displayed];
    for (final event in events) {
      state = event(state);
      if (state.displayed != seen.last) seen.add(state.displayed);
    }
    return seen;
  }

  group('turning notifications OFF', () {
    test('the device sequence that flickered now shows ON → OFF, once', () {
      final seen = transitions(
        const NotificationToggleState().storedValueRead(true),
        [
          (s) => s.userChose(false), // the tap
          (s) => s.storedValueRead(true), // stale read that crossed the write
          (s) => s.writeSucceeded(false), // write confirmed
          (s) => s.storedValueRead(false), // the next honest read agrees
        ],
      );
      expect(seen, [true, false]);
    });

    test('no intermediate ON is emitted after the user acts', () {
      var state = const NotificationToggleState().storedValueRead(true);
      state = state.userChose(false);
      expect(state.displayed, isFalse);

      // Anything a read says while the write is in flight is older than the
      // choice, and must not move the switch.
      state = state.storedValueRead(true);
      expect(state.displayed, isFalse);

      state = state.writeSucceeded(false);
      expect(state.displayed, isFalse);
    });

    test('the confirmed write is the stored value, not the last read', () {
      final state = const NotificationToggleState()
          .storedValueRead(true)
          .userChose(false)
          .writeSucceeded(false);
      expect(state.stored, isFalse);
      expect(state.isWriting, isFalse);
    });
  });

  group('turning notifications ON', () {
    test('the device sequence that flickered now shows OFF → ON, once', () {
      final seen = transitions(
        const NotificationToggleState().storedValueRead(false),
        [
          (s) => s.userChose(true),
          (s) => s.storedValueRead(false), // stale read that crossed the write
          (s) => s.writeSucceeded(true),
          (s) => s.storedValueRead(true),
        ],
      );
      expect(seen, [false, true]);
    });

    test('no intermediate OFF is emitted after the user acts', () {
      var state = const NotificationToggleState().storedValueRead(false);
      state = state.userChose(true);
      expect(state.displayed, isTrue);

      state = state.storedValueRead(false);
      expect(state.displayed, isTrue);

      state = state.writeSucceeded(true);
      expect(state.displayed, isTrue);
    });
  });

  group('the persistence failure path', () {
    test('a failed write returns the switch to what is actually saved', () {
      final seen = transitions(
        const NotificationToggleState().storedValueRead(true),
        [
          (s) => s.userChose(false),
          (s) => s.writeFailed(false),
        ],
      );
      // Shown OFF while the write was tried, then honestly back to ON.
      expect(seen, [true, false, true]);
    });

    test('a failed write never claims a preference that was not saved', () {
      final state = const NotificationToggleState()
          .storedValueRead(true)
          .userChose(false)
          .writeFailed(false);
      expect(state.stored, isTrue);
      expect(state.displayed, isTrue);
      expect(state.isWriting, isFalse);
    });
  });

  group('rapid toggling', () {
    test('a second tap during the first write keeps the second choice', () {
      var state = const NotificationToggleState().storedValueRead(true);
      state = state.userChose(false); // tap 1
      state = state.userChose(true); // tap 2, before write 1 resolves
      expect(state.displayed, isTrue);

      // Write 1 lands. It is not the value now pending, so the user's latest
      // choice keeps the switch.
      state = state.writeSucceeded(false);
      expect(state.displayed, isTrue, reason: 'tap 2 must not be undone by write 1');
      expect(state.isWriting, isTrue);

      state = state.writeSucceeded(true); // write 2 lands
      expect(state.displayed, isTrue);
      expect(state.isWriting, isFalse);
    });

    test('ten alternating taps end where the last tap asked', () {
      var state = const NotificationToggleState().storedValueRead(true);
      var want = true;
      for (var i = 0; i < 10; i++) {
        want = !want;
        state = state.userChose(want);
        expect(state.displayed, want);
        state = state.writeSucceeded(want);
        expect(state.displayed, want, reason: 'settling must not reverse tap $i');
      }
      // Ten flips starting from ON land back on ON. What the loop proves is
      // that every single step showed exactly what was tapped, and that no
      // settling write reversed the step it belonged to.
      expect(state.displayed, isTrue);
      expect(state.stored, isTrue);
    });
  });

  group('before anything has answered', () {
    test('defaults to enabled, matching the column default', () {
      expect(const NotificationToggleState().displayed, isTrue);
    });

    test('a first read replaces the default without a tap', () {
      expect(const NotificationToggleState().storedValueRead(false).displayed,
          isFalse);
    });
  });

  group('preferenceReadIsStale', () {
    test('a read that crossed a write is stale', () {
      expect(
        preferenceReadIsStale(epochAtRequest: 4, epochNow: 5),
        isTrue,
        reason: 'a write landed while this read was in flight',
      );
    });

    test('a read with no write in between is publishable', () {
      expect(preferenceReadIsStale(epochAtRequest: 4, epochNow: 4), isFalse);
    });

    test('several writes during one read are still stale', () {
      expect(preferenceReadIsStale(epochAtRequest: 0, epochNow: 3), isTrue);
    });
  });
}
