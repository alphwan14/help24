import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/connectivity_provider.dart' show NetworkHealth;
import 'package:help24/services/adaptive_poll.dart';

/// Regression suite: A POLL THAT CANNOT SUCCEED MUST NOT RUN.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Nine `Timer.periodic`s fired network requests on fixed cadences and none of
/// them knew what connectivity was. Losing signal slowed none of them down: the
/// conversation list refetched every 15s forever, `watchUser` and the settings
/// watcher every 15s each, a chat polled typing every 3s and presence every 30s,
/// presence heartbeats wrote every 60s, job-status cards polled every 30s.
///
/// Every tick failed. The cost was battery and radio wake-ups on the metered
/// connections most Help24 users are on — and, worse, CORRECTNESS: each failed
/// tick produced an error that some listener had to interpret, which is how a
/// dead network came to be published as "you have no conversations".
///
/// The contract, pinned below:
///   offline   → nothing scheduled, nothing fired;
///   reconnect → exactly ONE immediate tick, then the normal interval;
///   online    → an ordinary periodic poll.
void main() {
  setUp(NetworkHealth.resetForTest);
  tearDown(NetworkHealth.resetForTest);

  /// Drive [body] with a fake clock. `flushMicrotasks` after each publish lets
  /// the poller's stream subscription observe the edge before time advances.
  void withClock(void Function(FakeAsync async) body) =>
      fakeAsync((async) => body(async));

  void goOffline(FakeAsync async) {
    NetworkHealth.publish(offline: true);
    async.flushMicrotasks();
  }

  void goOnline(FakeAsync async) {
    NetworkHealth.publish(offline: false);
    async.flushMicrotasks();
  }

  group('online behaviour is an ordinary poll', () {
    test('ticks immediately, then on every interval', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        expect(ticks, 1, reason: 'the immediate tick is the point of start()');

        async.elapse(const Duration(seconds: 35));
        expect(ticks, 4); // 1 immediate + 3 intervals
        expect(poll.isPolling, isTrue);
      });
    });

    test('tickOnStart: false waits a full interval', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
          tickOnStart: false,
        )..start();
        addTearDown(poll.dispose);

        expect(ticks, 0);
        async.elapse(const Duration(seconds: 10));
        expect(ticks, 1);
      });
    });

    test('start is idempotent — it does not double the cadence', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);
        poll.start();
        poll.start();

        expect(ticks, 1);
        async.elapse(const Duration(seconds: 30));
        expect(ticks, 4);
      });
    });
  });

  group('offline parks the poll entirely', () {
    test('a poll started while offline never fires', () {
      withClock((async) {
        NetworkHealth.publish(offline: true);
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 5),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        expect(ticks, 0, reason: 'no immediate tick while offline');
        expect(poll.isPolling, isFalse, reason: 'nothing may be scheduled');

        async.elapse(const Duration(minutes: 10));
        expect(ticks, 0, reason: '10 minutes offline must cost zero requests');
      });
    });

    test('going offline mid-poll stops it', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        async.elapse(const Duration(seconds: 25)); // 1 + 2
        expect(ticks, 3);

        goOffline(async);
        expect(poll.isPolling, isFalse);

        async.elapse(const Duration(minutes: 5));
        expect(ticks, 3, reason: 'not one tick may fire while offline');
      });
    });

    test('refreshNow is a no-op while offline', () {
      withClock((async) {
        NetworkHealth.publish(offline: true);
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        poll.refreshNow();
        async.flushMicrotasks();
        expect(ticks, 0);
      });
    });
  });

  group('reconnect resumes with exactly one immediate refresh', () {
    test('one catch-up tick, then the normal interval', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        expect(ticks, 1);
        goOffline(async);
        async.elapse(const Duration(minutes: 5));
        expect(ticks, 1);

        goOnline(async);
        expect(ticks, 2,
            reason: 'exactly one immediate catch-up — not zero, not a burst');

        async.elapse(const Duration(seconds: 30));
        expect(ticks, 5, reason: 'normal cadence resumes');
      });
    });

    test('a long outage does not queue up missed ticks', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 5),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        goOffline(async);
        async.elapse(const Duration(hours: 2)); // 1440 missed intervals
        goOnline(async);

        expect(ticks, 2, reason: 'one start tick + one reconnect tick');
      });
    });

    test('a poll started while offline comes alive on reconnect', () {
      withClock((async) {
        NetworkHealth.publish(offline: true);
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        async.elapse(const Duration(minutes: 1));
        expect(ticks, 0);

        goOnline(async);
        expect(ticks, 1);
        async.elapse(const Duration(seconds: 20));
        expect(ticks, 3);
      });
    });

    test('repeated offline→online cycles each yield one catch-up', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(minutes: 10),
          onTick: () => ticks++,
          tickOnStart: false,
        )..start();
        addTearDown(poll.dispose);

        for (var i = 0; i < 4; i++) {
          goOffline(async);
          async.elapse(const Duration(seconds: 30));
          goOnline(async);
        }
        expect(ticks, 4);
      });
    });
  });

  group('lifecycle', () {
    test('dispose stops the poll and reconnect does not revive it', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();

        expect(ticks, 1);
        poll.dispose();

        async.elapse(const Duration(minutes: 5));
        goOffline(async);
        goOnline(async);
        async.elapse(const Duration(minutes: 5));

        expect(ticks, 1, reason: 'a disposed poll is gone for good');
        expect(poll.isStarted, isFalse);
      });
    });

    test('stop halts it and reconnect does not revive it', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
        )..start();
        addTearDown(poll.dispose);

        poll.stop();
        goOffline(async);
        goOnline(async);
        async.elapse(const Duration(minutes: 5));

        expect(ticks, 1);
      });
    });

    test('changing the interval re-arms at the new cadence', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () => ticks++,
          tickOnStart: false,
        )..start();
        addTearDown(poll.dispose);

        async.elapse(const Duration(seconds: 20));
        expect(ticks, 2);

        // What the conversation stream does once Realtime proves itself.
        poll.interval = const Duration(seconds: 60);
        async.elapse(const Duration(seconds: 59));
        expect(ticks, 2, reason: 'the old 10s cadence must be gone');
        async.elapse(const Duration(seconds: 1));
        expect(ticks, 3);
      });
    });

    test('a throwing tick does not kill the poll', () {
      withClock((async) {
        var ticks = 0;
        final poll = AdaptivePoll(
          interval: const Duration(seconds: 10),
          onTick: () {
            ticks++;
            throw StateError('boom');
          },
        )..start();
        addTearDown(poll.dispose);

        async.elapse(const Duration(seconds: 30));
        expect(ticks, 4, reason: 'one bad tick must not end the schedule');
      });
    });
  });

  group('NetworkHealth is the single reconnect edge source', () {
    test('publishes only on a change', () {
      withClock((async) {
        final seen = <bool>[];
        final sub = NetworkHealth.onStatusChange.listen(seen.add);
        addTearDown(sub.cancel);

        NetworkHealth.publish(offline: false); // already online — no edge
        NetworkHealth.publish(offline: true);
        NetworkHealth.publish(offline: true); // repeat — no edge
        NetworkHealth.publish(offline: false);
        async.flushMicrotasks();

        expect(seen, [true, false]);
      });
    });

    test('onReconnect fires only on offline→online', () {
      withClock((async) {
        var reconnects = 0;
        final sub = NetworkHealth.onReconnect.listen((_) => reconnects++);
        addTearDown(sub.cancel);

        NetworkHealth.publish(offline: true);
        async.flushMicrotasks();
        expect(reconnects, 0, reason: 'going offline is not a reconnect');

        NetworkHealth.publish(offline: false);
        async.flushMicrotasks();
        expect(reconnects, 1);
      });
    });

    test('isOffline reflects the last verdict', () {
      expect(NetworkHealth.isOffline, isFalse,
          reason: 'optimistic before evidence, like ConnectivityProvider');
      NetworkHealth.publish(offline: true);
      expect(NetworkHealth.isOffline, isTrue);
      NetworkHealth.publish(offline: false);
      expect(NetworkHealth.isOffline, isFalse);
    });
  });
}
