import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_notification.dart';
import '../providers/connectivity_provider.dart' show NetworkHealth;
import '../utils/error_mapper.dart';
import 'cache_service.dart';
import 'session_scope.dart';

/// What the notification centre is entitled to render right now.
///
/// The same four-state discipline the Discover feed runs on, for the same
/// reason: `isLoading && isEmpty` cannot distinguish "we have not asked yet"
/// from "we asked and there is nothing", and the notification screen used to
/// resolve that ambiguity by showing a full-screen spinner over content it
/// already had.
enum NotificationPresentation {
  /// No answer yet for this account. Renders skeletons.
  loading,

  /// There are notifications to render — including cached ones being refreshed
  /// underneath, and cached ones being read offline.
  content,

  /// A completed load returned nothing. Terminal.
  empty,

  /// The load failed and there is nothing to show in its place.
  failed;

  /// The decision, as a pure function of the facts it turns on. The ORDER is
  /// the contract, and it is the same order the feed uses:
  ///
  ///   1. rows on screen beat everything — no refresh, reconnect or failure may
  ///      replace notifications the user is reading with a spinner;
  ///   2. an empty list is [empty] only with a completed load behind it;
  ///   3. otherwise a recorded failure is [failed];
  ///   4. everything left — including "we have not asked yet" — is [loading].
  static NotificationPresentation resolve({
    required bool hasRows,
    required bool resolved,
    required bool loading,
    required bool hasError,
  }) {
    if (hasRows) return NotificationPresentation.content;
    if (resolved && !loading) return NotificationPresentation.empty;
    if (hasError) return NotificationPresentation.failed;
    return NotificationPresentation.loading;
  }
}

/// The single owner of notification state.
///
/// WHAT THIS REPLACES
/// ------------------
/// Two widgets, each with its own fetch, its own realtime channel and its own
/// idea of the truth. `NotificationsScreen` held a list and derived an unread
/// count from it (capped at 50 rows); `NotificationBadge` ran a separate COUNT
/// query over all rows. Neither told the other anything, so they could
/// legitimately disagree — and the badge only learned that the screen had marked
/// something read by way of a realtime round trip.
///
/// The instability users reported falls straight out of that arrangement:
///
///   * the badge started at 0 with nothing persisted, so every cold start
///     rendered NO badge and then popped one in;
///   * it subscribed to every INSERT *and* UPDATE and re-ran a full COUNT for
///     each, unsequenced — so "mark all read" (one statement, N rows, N events)
///     fired N racing queries whose answers landed in arbitrary order. That is
///     the badge stepping 2 → 0 → 2 → 1 in front of the user;
///   * the screen set `loading = true` on every load — including the one wired
///     to the reconnect edge — which replaced the list with a full-screen
///     spinner, and the query had no timeout, so with no usable network it never
///     came back;
///   * and there was no cache at all, so offline the screen had nothing to show
///     and a failed refresh was indistinguishable from an empty inbox.
///
/// THE CONTRACTS THIS OBEYS
/// ------------------------
/// All five are already proven elsewhere in this app; none of them had been
/// carried across to notifications:
///
///   * **cache-first** — hydrate from disk before any network call, so history
///     is on screen in the first frame (Messages);
///   * **a failed fetch is never published as an empty result** — failures set
///     an error slot and never clear rows (`watchConversations`);
///   * **offline is not emptiness** — cached rows stay fully readable, and no
///     request is even attempted (`loadUrgentPosts`);
///   * **sequence-guarded** — a stale response can never overwrite a fresh one
///     (`AppProvider._postsRequestSeq`);
///   * **session-scoped** — keyed by uid and purged at a session boundary
///     (`SessionScope`).
///
/// THE UNREAD COUNT CHANGES ON EXACTLY FOUR EVENTS
/// -----------------------------------------------
/// A notification arrives (+1), one is read (−1), all are read (→0), or a
/// completed refresh reports an authoritative figure. Nothing else moves it:
/// not a failed load, not an unrelated realtime event, not a rebuild, not a
/// resume. That is the whole of "update once, stay stable, never oscillate".
class NotificationStore extends ChangeNotifier implements SessionScoped {
  NotificationStore._() {
    SessionScope.instance.register(this);
  }

  static final NotificationStore instance = NotificationStore._();

  /// Matches [FeedService]'s bound. A notification query that takes longer than
  /// this is not going to arrive usefully, and the failure mode it prevents —
  /// a spinner with no timeout behind it — is the one users actually hit.
  static const Duration _timeout = Duration(seconds: 8);

  static const int pageSize = 30;

  /// How long the store waits for realtime to go quiet before reconciling the
  /// count against the server.
  ///
  /// "Mark all read" is ONE statement over N rows and arrives as N separate
  /// events. Reconciling per event is what made the badge oscillate; reconciling
  /// once the burst has finished is one query and one visible change.
  static const Duration _reconcileQuiet = Duration(milliseconds: 600);

  /// How recently a refresh has to have completed for a repeat [bind] to skip
  /// its own. Deliberately short: this deduplicates a launch, not a session.
  /// Explicit refreshes — pull, reconnect, resume, retry — ignore it entirely.
  static const Duration _bindFreshness = Duration(seconds: 10);

  SupabaseClient get _db => Supabase.instance.client;

  // ── State ─────────────────────────────────────────────────────────────────

  /// The account these notifications belong to. Everything below is scoped to
  /// it; a read performed as anyone else returns nothing.
  String _userId = '';

  /// Id-keyed rather than a list, so a realtime insert that races a page load
  /// cannot produce two rows for one notification.
  final Map<String, AppNotification> _byId = {};

  /// Rendering order, recomputed only when the set actually changes.
  List<AppNotification> _ordered = const [];

  int _unread = 0;

  /// Whether a COMPLETED load stands behind the current list, for the account
  /// currently bound. Cache hydration deliberately does NOT set it: disk is old
  /// by definition, so it may keep the screen alive but may never be the
  /// evidence behind "no notifications yet".
  bool _resolved = false;

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  int _seq = 0;
  int _countSeq = 0;

  /// When the last refresh COMPLETED successfully. Only [bind] reads it.
  DateTime? _refreshedAt;
  RealtimeChannel? _channel;
  String _subscribedUserId = '';
  Timer? _reconcileTimer;

  // ── Reads ─────────────────────────────────────────────────────────────────

  List<AppNotification> get all => _ordered;

  /// Unread notifications the user should act on, newest-first within priority.
  /// Rendered as a pinned block above the timeline.
  List<AppNotification> get needsAttention => [
        for (final n in _ordered)
          if (!n.read && n.kind.priority.isPinnable) n,
      ];

  /// Everything not pinned, strictly reverse-chronological.
  List<AppNotification> get timeline => [
        for (final n in _ordered)
          if (n.read || !n.kind.priority.isPinnable) n,
      ];

  int get unreadCount => _unread;
  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get error => _error;
  bool get isBound => _userId.isNotEmpty;

  NotificationPresentation get presentation => NotificationPresentation.resolve(
        hasRows: _ordered.isNotEmpty,
        resolved: _resolved,
        loading: _loading,
        hasError: _error != null,
      );

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Attach the store to [userId]. Idempotent: calling it on every auth change,
  /// every tab open and every screen build is free.
  ///
  /// An empty id is a sign-out and resets everything.
  Future<void> bind(String? userId) async {
    final uid = userId?.trim() ?? '';
    if (uid.isEmpty) {
      if (_userId.isNotEmpty) resetForSignOut();
      return;
    }
    if (_userId == uid) {
      // Already this account. Re-subscribe if the channel was dropped, and
      // refresh only if the last one was not a moment ago — bind() is called
      // from three places that can all fire during one launch (auth resolving,
      // the bell mounting, the screen opening), and three identical fetches is
      // the redundancy this store exists to remove.
      _subscribe();
      final last = _refreshedAt;
      if (last == null || DateTime.now().difference(last) >= _bindFreshness) {
        unawaited(refresh());
      }
      return;
    }

    // A different account: drop the outgoing one's rows BEFORE anything can
    // paint them under the new session.
    _clear();
    _userId = uid;
    notifyListeners();

    await _hydrateFromCache(uid);
    _subscribe();
    unawaited(refresh());
  }

  @override
  void resetForSignOut() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _channel?.unsubscribe();
    _channel = null;
    _subscribedUserId = '';
    _clear();
    _userId = '';
    notifyListeners();
  }

  void _clear() {
    _byId.clear();
    _ordered = const [];
    _unread = 0;
    _resolved = false;
    _loading = false;
    _loadingMore = false;
    _hasMore = true;
    _error = null;
    _refreshedAt = null;
    // Bumped so any response still in flight for the outgoing account is
    // recognised as stale and dropped rather than merged into the new one.
    _seq++;
    _countSeq++;
  }

  @override
  void dispose() {
    _reconcileTimer?.cancel();
    _channel?.unsubscribe();
    SessionScope.instance.unregister(this);
    super.dispose();
  }

  // ── Disk ──────────────────────────────────────────────────────────────────

  /// Put the last known register on screen while the live one is fetched.
  ///
  /// Silent on every failure, and deliberately not an "answer": a cache miss
  /// leaves the screen in [NotificationPresentation.loading], which is where a
  /// fresh install belongs.
  Future<void> _hydrateFromCache(String uid) async {
    final cached = await CacheService.loadNotifications(uid);
    // Re-checked across the await: a live load or an account change may have
    // overtaken the disk read, and disk data must never win against either.
    if (_userId != uid || cached.rows.isEmpty || _byId.isNotEmpty) return;
    for (final n in cached.rows) {
      _byId[n.id] = n;
    }
    _reorder();
    _unread = cached.unread;
    notifyListeners();
  }

  void _persist() {
    if (_userId.isEmpty) return;
    unawaited(CacheService.saveNotifications(_userId, _ordered, unread: _unread));
  }

  // ── Network ───────────────────────────────────────────────────────────────

  /// Refresh page one and the authoritative unread count.
  ///
  /// Never clears what is on screen. Never spins over content. Never attempts a
  /// request the connection cannot carry.
  Future<void> refresh() async {
    final uid = _userId;
    if (uid.isEmpty) return;

    if (NetworkHealth.isOffline) {
      // Offline is not emptiness and not a failure: the cached register stays
      // exactly as it is, fully readable. ReconnectListener re-runs this the
      // moment the connection is back.
      debugPrint('[NOTIFICATIONS] offline — keeping the cached register');
      if (_loading) {
        _loading = false;
        notifyListeners();
      }
      return;
    }

    final seq = ++_seq;
    // Only spin when there is genuinely nothing to look at. A refresh
    // underneath existing rows must be completely invisible.
    final firstPaint = _byId.isEmpty;
    if (firstPaint && !_loading) {
      _loading = true;
      notifyListeners();
    }

    try {
      final rows = await _fetchPage(uid, before: null);
      if (seq != _seq || _userId != uid) return;

      // Page one is authoritative for the window it covers: rows that fall
      // inside it and are no longer returned have been deleted server-side.
      // Anything OLDER than the page is paginated history and is preserved —
      // dropping it would make the list jump backwards under a reader who had
      // scrolled into it.
      //
      // An EMPTY page one is the one case that clears everything, and it has to
      // be handled separately: page one is "the newest N", so nothing at all in
      // it means there is nothing anywhere, and the range test below would
      // otherwise preserve every stale row forever.
      if (rows.isEmpty) {
        _byId.clear();
      } else {
        final oldest = rows.last.createdAt;
        final incoming = {for (final n in rows) n.id};
        _byId.removeWhere((id, n) =>
            !incoming.contains(id) && !n.createdAt.isBefore(oldest));
        for (final n in rows) {
          _byId[n.id] = n;
        }
      }
      _reorder();
      _hasMore = rows.length >= pageSize;
      _resolved = true;
      _error = null;
      _refreshedAt = DateTime.now();
      NetworkHealth.success();

      await _reconcileUnread(uid);
      if (seq != _seq || _userId != uid) return;
      _persist();
    } catch (e) {
      if (seq != _seq || _userId != uid) return;
      // A failed refresh is not the user's problem when they are reading a
      // perfectly good cached register. Failure is only reported when there is
      // nothing on screen at all.
      if (_byId.isEmpty) {
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
      }
      // ONLY a transport failure counts as evidence about the network.
      //
      // Reporting every failure here was wrong and had a visible cost: at cold
      // start the Firebase→Supabase token exchange is still in flight, so this
      // query can come back as an RLS rejection — a perfectly reachable server
      // saying no. Two of those tipped ConnectivityProvider into probing, a
      // slow probe published "offline", the recovery published "online", and
      // the reconnect handler refreshed the whole app. A permissions answer was
      // being laundered into a feed reload.
      if (e is TimeoutException || e is SocketException) NetworkHealth.failure();
      debugPrint('[NOTIFICATIONS] refresh failed: $e');
    } finally {
      if (seq == _seq && _userId == uid) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Append the next page of history.
  Future<void> loadMore() async {
    final uid = _userId;
    if (uid.isEmpty || !_hasMore || _loadingMore || _loading) return;
    if (_ordered.isEmpty || NetworkHealth.isOffline) return;

    _loadingMore = true;
    notifyListeners();
    final seq = _seq;
    try {
      final rows = await _fetchPage(uid, before: _ordered.last.createdAt);
      if (seq != _seq || _userId != uid) return;
      for (final n in rows) {
        _byId[n.id] = n;
      }
      _reorder();
      _hasMore = rows.length >= pageSize;
      _persist();
    } catch (e) {
      // Stop paginating rather than retry-looping at the bottom of the list.
      _hasMore = false;
      debugPrint('[NOTIFICATIONS] loadMore failed: $e');
    } finally {
      if (seq == _seq && _userId == uid) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<List<AppNotification>> _fetchPage(String uid, {DateTime? before}) async {
    var query = _db
        .from('notifications')
        .select()
        .eq('user_id', uid)
        // Chat lives in the Messages tab. Two inboxes for one conversation is
        // how unread counts start disagreeing with each other.
        .neq('type', 'chat_message');
    if (before != null) {
      query = query.lt('created_at', before.toUtc().toIso8601String());
    }
    final res = await query
        .order('created_at', ascending: false)
        .limit(pageSize)
        .timeout(_timeout);
    return [
      for (final row in res as List<dynamic>)
        AppNotification.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  /// Ask the server how many are unread, and publish it as the truth.
  ///
  /// This is the ONLY place a network answer is allowed to set the count
  /// outright. Everything else adjusts it by a known delta, which is why the
  /// badge does not flicker: there is one authoritative write per refresh, not
  /// one per realtime event.
  Future<void> _reconcileUnread(String uid) async {
    final seq = ++_countSeq;
    try {
      final res = await _db
          .from('notifications')
          .select('id')
          .eq('user_id', uid)
          .neq('type', 'chat_message')
          .eq('read', false)
          .timeout(_timeout);
      // A stale count is worse than no count: it is a number that contradicts
      // what the user just did.
      if (seq != _countSeq || _userId != uid) return;
      final count = (res as List<dynamic>).length;
      if (count == _unread) return;
      _unread = count;
      _persist();
    } catch (e) {
      // The previous count stands. Dropping to zero because a query failed is
      // how a user comes to believe they have no unread work.
      debugPrint('[NOTIFICATIONS] unread reconcile failed: $e');
    }
  }

  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(_reconcileQuiet, () {
      final uid = _userId;
      if (uid.isEmpty || NetworkHealth.isOffline) return;
      unawaited(_reconcileUnread(uid).then((_) => notifyListeners()));
    });
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Mark one notification read, immediately and locally. The DB write follows
  /// and rolls the local state back if it fails.
  Future<void> markRead(String id) async {
    final current = _byId[id];
    if (current == null || current.read || _userId.isEmpty) return;
    _byId[id] = current.copyWith(read: true);
    _reorder();
    _unread = _unread > 0 ? _unread - 1 : 0;
    _persist();
    notifyListeners();

    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('id', id)
          .timeout(_timeout);
    } catch (e) {
      // Put it back. An optimistic update that silently keeps a state the
      // server rejected is a lie the user cannot see or correct.
      final reverted = _byId[id];
      if (reverted != null && reverted.read) {
        _byId[id] = reverted.copyWith(read: false);
        _reorder();
        _unread += 1;
        _persist();
        notifyListeners();
      }
      debugPrint('[NOTIFICATIONS] markRead failed for $id: $e');
    }
  }

  /// Mark everything read.
  ///
  /// One statement server-side, one local transition, one visible change — and
  /// the N realtime events it produces are absorbed by [_applyRemoteUpdate]
  /// without moving the count at all, because each row is already read locally.
  Future<void> markAllRead() async {
    final uid = _userId;
    if (uid.isEmpty || _unread == 0) return;
    final previous = {
      for (final entry in _byId.entries)
        if (!entry.value.read) entry.key: entry.value,
    };
    if (previous.isEmpty && _unread == 0) return;

    for (final id in previous.keys) {
      _byId[id] = previous[id]!.copyWith(read: true);
    }
    final previousUnread = _unread;
    _reorder();
    _unread = 0;
    _persist();
    notifyListeners();

    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .neq('type', 'chat_message')
          .eq('read', false)
          .timeout(_timeout);
    } catch (e) {
      for (final entry in previous.entries) {
        _byId[entry.key] = entry.value;
      }
      _reorder();
      _unread = previousUnread;
      _persist();
      notifyListeners();
      debugPrint('[NOTIFICATIONS] markAllRead failed: $e');
    }
  }

  // ── Realtime ──────────────────────────────────────────────────────────────

  /// ONE subscription for the whole app.
  ///
  /// The payload is used as DATA, not as a mere trigger. The old badge threw
  /// away the row it was handed and re-queried the entire count for every event
  /// — which is both the extra load and the oscillation. An insert is a row; an
  /// update is a known read-state transition. Neither needs a query.
  void _subscribe() {
    final uid = _userId;
    if (uid.isEmpty) return;
    if (_subscribedUserId == uid && _channel != null) return;
    _channel?.unsubscribe();
    _subscribedUserId = uid;
    _channel = _db
        .channel('notifications:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (payload) => _applyRemoteInsert(uid, payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (payload) => _applyRemoteUpdate(uid, payload.newRecord),
        )
        .subscribe((status, [error]) {
          debugPrint('[NOTIFICATIONS] realtime status=$status error=$error');
        });
  }

  void _applyRemoteInsert(String uid, Map<String, dynamic> record) {
    if (_userId != uid) return;
    try {
      final n = AppNotification.fromJson(record);
      if (n.id.isEmpty || n.type == 'chat_message') return;
      // Keyed insert, so a push that races a page load produces one row rather
      // than two.
      if (_byId.containsKey(n.id)) return;
      _byId[n.id] = n;
      _reorder();
      if (!n.read) _unread += 1;
      _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('[NOTIFICATIONS] realtime insert parse failed: $e');
    }
  }

  void _applyRemoteUpdate(String uid, Map<String, dynamic> record) {
    if (_userId != uid) return;
    try {
      final incoming = AppNotification.fromJson(record);
      if (incoming.id.isEmpty || incoming.type == 'chat_message') return;
      final current = _byId[incoming.id];
      if (current == null) {
        // A row outside the pages we hold changed. We cannot know its previous
        // state, so this is the one case that needs the server — coalesced, so
        // a burst of N costs one query instead of N.
        _scheduleReconcile();
        return;
      }
      if (current.read == incoming.read) {
        // Nothing that affects the count. Most commonly this is the echo of the
        // app's own optimistic write coming back — absorbing it silently is
        // what stops "mark all read" from stepping the badge through N values.
        _byId[incoming.id] = incoming;
        return;
      }
      _byId[incoming.id] = incoming;
      _reorder();
      _unread = incoming.read
          ? (_unread > 0 ? _unread - 1 : 0)
          : _unread + 1;
      _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('[NOTIFICATIONS] realtime update parse failed: $e');
    }
  }

  // ── Ordering ──────────────────────────────────────────────────────────────

  /// Newest first, always.
  ///
  /// Priority does NOT sort this list. It decides which unread rows are lifted
  /// into the pinned block ([needsAttention]) and nothing else — so a resolved
  /// dispute from last week never outranks this morning's application, and a
  /// background refresh cannot re-sort history under a reader. Importance
  /// chooses what surfaces; recency orders everything.
  void _reorder() {
    final rows = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _ordered = List.unmodifiable(rows);
  }

  /// Test seam: install a known state without a network or a database.
  @visibleForTesting
  void debugSeed(
    String userId,
    List<AppNotification> rows, {
    int? unread,
    bool resolved = true,
  }) {
    _userId = userId;
    _byId
      ..clear()
      ..addEntries(rows.map((n) => MapEntry(n.id, n)));
    _reorder();
    _unread = unread ?? rows.where((n) => !n.read).length;
    _resolved = resolved;
    _loading = false;
    _error = null;
  }

  /// Test seam: the local half of a realtime event, without a channel.
  @visibleForTesting
  void debugApplyInsert(Map<String, dynamic> record) =>
      _applyRemoteInsert(_userId, record);

  @visibleForTesting
  void debugApplyUpdate(Map<String, dynamic> record) =>
      _applyRemoteUpdate(_userId, record);

  /// Test seam: mark read WITHOUT the database round trip, so the local
  /// unread-count lifecycle can be asserted in isolation.
  @visibleForTesting
  void debugMarkReadLocally(String id) {
    final current = _byId[id];
    if (current == null || current.read) return;
    _byId[id] = current.copyWith(read: true);
    _reorder();
    _unread = _unread > 0 ? _unread - 1 : 0;
    notifyListeners();
  }

  @visibleForTesting
  void debugMarkAllReadLocally() {
    for (final entry in _byId.entries.toList()) {
      if (!entry.value.read) _byId[entry.key] = entry.value.copyWith(read: true);
    }
    _reorder();
    _unread = 0;
    notifyListeners();
  }
}
