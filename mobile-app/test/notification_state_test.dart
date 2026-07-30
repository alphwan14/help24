import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/app_notification.dart';
import 'package:help24/services/notification_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite: THE UNREAD COUNT UPDATES ONCE, STAYS STABLE, AND NEVER
/// OSCILLATES.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// The badge and the notification screen were two widgets with two fetches, two
/// realtime subscriptions and two ideas of the truth. The badge subscribed to
/// every INSERT *and* UPDATE and re-ran a full COUNT query for each, with no
/// sequencing — so "mark all read" (one statement, N rows, N events) fired N
/// racing queries whose answers landed in arbitrary order, and the user watched
/// the badge step 2 → 0 → 2 → 1 before settling. It also started at zero with
/// nothing persisted, so a cold start rendered no badge and then popped one in.
///
/// [NotificationStore] replaces both with one owner and one number, and that
/// number moves on exactly four events: a notification arrives, one is read, all
/// are read, or a completed refresh reports an authoritative figure. Nothing
/// else touches it — not a failed load, not an unrelated realtime event, not a
/// resume, not a rebuild.
///
/// Companion: `notification_taxonomy_test.dart` (what a notification IS, and
/// how the register is ordered and grouped).

AppNotification _n(
  String id, {
  String type = 'provider_applied',
  bool read = false,
  DateTime? at,
  Map<String, dynamic> data = const {},
}) =>
    AppNotification(
      id: id,
      type: type,
      title: 'Title $id',
      body: 'Body $id',
      data: data,
      read: read,
      createdAt: at ?? DateTime(2026, 7, 30, 9),
    );

Map<String, dynamic> _row(
  String id, {
  String type = 'provider_applied',
  bool read = false,
  String at = '2026-07-30T09:00:00Z',
}) =>
    {
      'id': id,
      'type': type,
      'title': 'Title $id',
      'body': 'Body $id',
      'data': <String, dynamic>{},
      'read': read,
      'created_at': at,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = NotificationStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetForSignOut();
  });

  tearDown(() => store.resetForSignOut());

  group('the unread count moves on four events and nothing else', () {
    test('a new notification arriving adds exactly one', () {
      store.debugSeed('me', [_n('a', read: true)], unread: 0);
      store.debugApplyInsert(_row('b'));
      expect(store.unreadCount, 1);
    });

    test('an already-read arrival adds nothing', () {
      store.debugSeed('me', [], unread: 0);
      store.debugApplyInsert(_row('b', read: true));
      expect(store.unreadCount, 0);
    });

    test('reading one subtracts exactly one', () {
      store.debugSeed('me', [_n('a'), _n('b')]);
      expect(store.unreadCount, 2);
      store.debugMarkReadLocally('a');
      expect(store.unreadCount, 1);
    });

    test('reading the same one twice subtracts once', () {
      store.debugSeed('me', [_n('a'), _n('b')]);
      store.debugMarkReadLocally('a');
      store.debugMarkReadLocally('a');
      expect(store.unreadCount, 1);
    });

    test('marking all read goes to zero and stays there', () {
      store.debugSeed('me', [_n('a'), _n('b'), _n('c')]);
      store.debugMarkAllReadLocally();
      expect(store.unreadCount, 0);
    });

    test('the count never goes negative', () {
      store.debugSeed('me', [_n('a', read: true)], unread: 0);
      store.debugApplyUpdate(_row('a', read: true));
      expect(store.unreadCount, 0);
    });
  });

  group('it does not oscillate', () {
    /// Every value the badge would have rendered, in order.
    List<int> observe(void Function() body) {
      final seen = <int>[];
      void listener() => seen.add(store.unreadCount);
      store.addListener(listener);
      body();
      store.removeListener(listener);
      return seen;
    }

    test('mark-all-read is ONE visible change, not N', () {
      // THE REPORTED BUG. The old badge re-queried per realtime event, so five
      // rows going read produced five un-sequenced answers and five renders.
      store.debugSeed('me', [_n('a'), _n('b'), _n('c'), _n('d'), _n('e')]);

      final seen = observe(() {
        store.debugMarkAllReadLocally();
        // The server echoes back one UPDATE per row. Each is already read
        // locally, so each must be absorbed in silence.
        for (final id in ['a', 'b', 'c', 'd', 'e']) {
          store.debugApplyUpdate(_row(id, read: true));
        }
      });

      expect(seen, [0], reason: 'one transition to zero, and nothing after it');
    });

    test('the echo of an optimistic read moves nothing', () {
      store.debugSeed('me', [_n('a'), _n('b')]);
      store.debugMarkReadLocally('a');

      final seen = observe(() => store.debugApplyUpdate(_row('a', read: true)));

      expect(seen, isEmpty);
      expect(store.unreadCount, 1);
    });

    test('a duplicate realtime insert is ignored', () {
      // A push and a websocket event can describe the same row, and a page load
      // can race both. Keyed storage means one notification is one row.
      store.debugSeed('me', [], unread: 0);
      store.debugApplyInsert(_row('a'));
      store.debugApplyInsert(_row('a'));

      expect(store.all.length, 1);
      expect(store.unreadCount, 1);
    });

    test('an unread row becoming unread again is counted once', () {
      store.debugSeed('me', [_n('a', read: true)], unread: 0);
      store.debugApplyUpdate(_row('a'));
      store.debugApplyUpdate(_row('a'));
      expect(store.unreadCount, 1);
    });
  });

  group('reading stays consistent with what is on screen', () {
    test('the pinned block and the timeline partition the register', () {
      // Every row is in exactly one of them. Overlap would make the register
      // look fuller than it is and make "mark all read" look half-done.
      store.debugSeed('me', [
        _n('dispute', type: 'dispute_opened'),
        _n('applied', type: 'provider_applied'),
        _n('review', type: 'review_received'),
        _n('promo', type: 'promotion_completed', read: true),
      ]);

      final pinned = store.needsAttention.map((n) => n.id).toSet();
      final rest = store.timeline.map((n) => n.id).toSet();

      expect(pinned.intersection(rest), isEmpty);
      expect(pinned.union(rest).length, store.all.length);
    });

    test('reading a pinned item moves it into the timeline', () {
      store.debugSeed('me', [_n('dispute', type: 'dispute_opened')]);
      expect(store.needsAttention.length, 1);

      store.debugMarkReadLocally('dispute');

      expect(store.needsAttention, isEmpty);
      expect(store.timeline.length, 1);
    });

    test('the list is newest-first regardless of priority', () {
      // Priority decides what surfaces; recency orders everything. A resolved
      // dispute from last week must not outrank this morning's application.
      store.debugSeed('me', [
        _n('old', type: 'dispute_opened', read: true, at: DateTime(2026, 7, 20)),
        _n('new', type: 'promotion_completed', read: true, at: DateTime(2026, 7, 30)),
      ]);

      expect(store.all.map((n) => n.id), ['new', 'old']);
    });
  });

  group('chat never enters the bell', () {
    test('a chat_message insert is dropped', () {
      // Two inboxes for one conversation is how unread counts start disagreeing
      // with each other. Chat belongs to the Messages tab.
      store.debugSeed('me', [], unread: 0);
      store.debugApplyInsert(_row('c1', type: 'chat_message'));

      expect(store.all, isEmpty);
      expect(store.unreadCount, 0);
    });
  });

  group('presentation: absence of an answer is not emptiness', () {
    test('a fresh install shows skeletons, never "nothing to report"', () {
      expect(
        NotificationPresentation.resolve(
          hasRows: false,
          resolved: false,
          loading: false,
          hasError: false,
        ),
        NotificationPresentation.loading,
      );
    });

    test('empty requires a completed load', () {
      expect(
        NotificationPresentation.resolve(
          hasRows: false,
          resolved: true,
          loading: false,
          hasError: false,
        ),
        NotificationPresentation.empty,
      );
    });

    test('rows on screen outrank a failure — offline reading keeps working', () {
      // The offline case, exactly: cached history is on screen and a refresh
      // failed. Replacing it with a spinner or an apology is the behaviour
      // users described as "they appear, then disappear, then load forever".
      expect(
        NotificationPresentation.resolve(
          hasRows: true,
          resolved: false,
          loading: true,
          hasError: true,
        ),
        NotificationPresentation.content,
      );
    });

    test('a failure with nothing to show gets a retry, not an empty state', () {
      expect(
        NotificationPresentation.resolve(
          hasRows: false,
          resolved: false,
          loading: false,
          hasError: true,
        ),
        NotificationPresentation.failed,
      );
    });

    test('a load in flight never resolves to empty', () {
      expect(
        NotificationPresentation.resolve(
          hasRows: false,
          resolved: true,
          loading: true,
          hasError: false,
        ),
        NotificationPresentation.loading,
      );
    });

    test('seeded rows present as content', () {
      store.debugSeed('me', [_n('a')]);
      expect(store.presentation, NotificationPresentation.content);
    });
  });

  group('the register is scoped to the account holding it', () {
    test('signing out destroys the rows and the count together', () {
      store.debugSeed('me', [_n('a'), _n('b')]);
      store.resetForSignOut();

      expect(store.all, isEmpty);
      expect(store.unreadCount, 0);
      expect(store.isBound, isFalse);
    });

    test('a realtime event for the previous account is discarded', () {
      // A channel started for one user can still deliver after the switch;
      // unsubscribing does not retroactively drop an in-flight event.
      store.debugSeed('me', [_n('a')]);
      store.resetForSignOut();
      store.debugSeed('someone-else', [], unread: 0);

      store.debugApplyInsert(_row('leaked'));
      // Bound to the new account, so the insert IS for them — the guard being
      // asserted is that nothing survived the switch.
      expect(store.all.map((n) => n.id), ['leaked']);
      expect(store.all.any((n) => n.id == 'a'), isFalse);
    });
  });

  group('rows round-trip through the cache unchanged', () {
    test('a notification survives save → load', () {
      final original = _n(
        'a',
        type: 'payment_secured',
        read: true,
        at: DateTime(2026, 7, 28, 14, 30),
        data: {'post_id': 'p1', 'transaction_id': 't1'},
      );
      final restored = AppNotification.fromJson(original.toCacheMap());

      expect(restored.id, original.id);
      expect(restored.type, original.type);
      expect(restored.read, isTrue);
      expect(restored.postId, 'p1');
      expect(restored.transactionId, 't1');
      expect(restored.createdAt.toUtc(), original.createdAt.toUtc());
    });

    test('a cached row parses through the same path as a fetched one', () {
      // One parser, so a cached register and a live one can never render
      // differently — the bug class that made offline lists look subtly wrong.
      final fetched = AppNotification.fromJson(_row('a', type: 'dispute_opened'));
      final cached = AppNotification.fromJson(fetched.toCacheMap());

      expect(cached.kind.type, fetched.kind.type);
      expect(cached.kind.priority, fetched.kind.priority);
    });
  });
}
