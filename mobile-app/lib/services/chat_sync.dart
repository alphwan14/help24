import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_person.dart';
import '../models/post_model.dart';
import '../providers/connectivity_provider.dart' show NetworkHealth;
import 'adaptive_poll.dart';
import 'chat_media_store.dart';
import 'chat_service_supabase.dart';
import 'chat_store.dart';
import 'delivery_receipts.dart';

/// Where chat stands with the server, for the one small status line the chat
/// screens show under their title. Content never waits on this.
enum ChatSyncPhase {
  /// Up to date (or nothing worth saying).
  idle,

  /// No network. "Waiting for network".
  offline,

  /// A network, and no successful sync on it yet. "Connecting…"
  connecting,
}

/// THE NETWORK SIDE OF CHAT: it reads the server and writes [ChatStore].
///
/// Nothing here renders, and nothing that renders calls the server. The
/// Messages tab and every chat read the database; this class is the only
/// writer of the conversation list, and of the threads nobody has open.
///
/// WHEN IT SYNCS
///   * launch (when the signed-in account's list is first wanted);
///   * the app returning to the foreground;
///   * the network returning (via [AdaptivePoll]'s one reconnect tick);
///   * a realtime nudge on any of the account's `chats` rows (a message was
///     sent or received anywhere);
///   * a push for a chat ([onPush]);
///   * otherwise a poll — 15 s, relaxed to 60 s once realtime proves alive.
///
/// WHAT ONE SYNC DOES
///   1. Reads the conversation list: always the newest page (that is where
///      unread counts change), then older pages until it reaches the cursor —
///      the newest `chats.updated_at` it had already stored. A first sync on a
///      device pages through the account's whole list.
///   2. Reads the profiles of the people in it — all of them on the first sync
///      of a session, otherwise only people this phone has no name for. If
///      that read fails, the conversations are stored WITHOUT touching anyone's
///      name: the phone keeps what it knew. This is the "?" fix.
///   3. Writes both in one transaction.
///   4. Afterwards, in the background: the latest 50 messages of each of the
///      30 most recent conversations that moved since their thread was last
///      fetched, the people's photos, and photo thumbnails for the most recent
///      chats — so the next offline launch has something to show.
///
/// There is no "changes since" endpoint for messages: `chat_messages` has no
/// updated_at, so a seen/delivered/deleted change is only picked up by
/// re-reading the latest page of a thread, which step 4 does whenever its
/// conversation moves and ChatScreen does on open.
class ChatSync with WidgetsBindingObserver {
  ChatSync._();

  static final ChatSync instance = ChatSync._();

  /// The status line's input.
  final ValueNotifier<ChatSyncPhase> phase = ValueNotifier(ChatSyncPhase.idle);

  /// The failure of the very first load for an account whose database is
  /// still empty — the only failure worth showing as such. Null otherwise.
  final ValueNotifier<Object?> firstLoadError = ValueNotifier(null);

  static const int _headPage = 30;
  static const int _pageSize = 50;
  static const int _maxPages = 20;
  static const int _threadsToKeepWarm = 30;
  static const int _messagesPerThread = 50;

  String _uid = '';
  String get uid => _uid;

  AdaptivePoll? _poll;
  RealtimeChannel? _channel;
  Timer? _nudge;
  StreamSubscription<bool>? _network;
  bool _realtimeConfirmed = false;
  bool _running = false;
  bool _queued = false;
  bool _syncedSinceConnect = false;
  bool _syncedThisSession = false;
  bool _backgroundRunning = false;
  bool _observing = false;
  final Set<String> _urgentThreads = {};

  /// The server, as sync sees it. Tests replace it; nothing else does.
  @visibleForTesting
  static ChatSyncTransport transport = const ChatSyncTransport();

  Future<void>? _background;

  /// The post-sync work (threads, photos) of the last sync, for tests.
  @visibleForTesting
  Future<void>? get backgroundWork => _background;

  /// Sync for [uid] with no poll, realtime or lifecycle observer — a test
  /// drives [syncNow] by hand.
  @visibleForTesting
  void attachForTest(String uid) {
    stop();
    _uid = uid;
    ChatMediaStore.activeUid = uid;
  }

  /// Forget the session (as a new launch would), keeping the account.
  @visibleForTesting
  void newSessionForTest() {
    _syncedThisSession = false;
    _syncedSinceConnect = false;
  }

  /// Begin syncing for [uid]. Idempotent; a different uid restarts cleanly.
  void start(String uid) {
    final owner = uid.trim();
    if (owner.isEmpty) return;
    if (owner == _uid && _poll != null) return;
    stop();
    _uid = owner;
    ChatMediaStore.activeUid = owner;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _network = NetworkHealth.onStatusChange.listen((offline) {
      if (offline) {
        _syncedSinceConnect = false;
        phase.value = ChatSyncPhase.offline;
      } else {
        // The poll's reconnect tick does the sync; this only says so.
        phase.value = ChatSyncPhase.connecting;
      }
    });
    phase.value = NetworkHealth.isOffline ? ChatSyncPhase.offline : ChatSyncPhase.connecting;
    _poll = AdaptivePoll(
      interval: const Duration(seconds: 15),
      onTick: syncNow,
      debugLabel: 'chat-sync',
      tickOnStart: false,
    )..start();
    _subscribeRealtime(owner);
    unawaited(syncNow());
  }

  /// Stop syncing (sign-out, account switch). The database is not touched.
  void stop() {
    _poll?.dispose();
    _poll = null;
    _nudge?.cancel();
    _nudge = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.unsubscribe());
    _network?.cancel();
    _network = null;
    _uid = '';
    _realtimeConfirmed = false;
    _syncedSinceConnect = false;
    _syncedThisSession = false;
    _urgentThreads.clear();
    phase.value = ChatSyncPhase.idle;
    firstLoadError.value = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _uid.isEmpty) return;
    // A push may have written the database from the background isolate while
    // this one was paused: let every screen re-read, then ask the server.
    ChatStore.instance.announceExternalWrite(_uid);
    unawaited(syncNow());
  }

  /// A chat push arrived while the app is running: its thread is fetched
  /// first, whatever its place in the list.
  void onPush(String chatId) {
    if (_uid.isEmpty || chatId.isEmpty) return;
    _urgentThreads.add(chatId);
    unawaited(syncNow());
  }

  void _subscribeRealtime(String owner) {
    try {
      PostgresChangeFilter userFilter(String column) => PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: column,
            value: owner,
          );
      var channel = Supabase.instance.client.channel('chats_sync:$owner');
      for (final event in [PostgresChangeEvent.insert, PostgresChangeEvent.update]) {
        for (final column in ['user1', 'user2']) {
          channel = channel.onPostgresChanges(
            event: event,
            schema: 'public',
            table: 'chats',
            filter: userFilter(column),
            callback: (_) => _onNudge(),
          );
        }
      }
      _channel = channel..subscribe();
    } catch (e) {
      // No realtime: the poll alone keeps the list current.
      debugPrint('[CHAT_SYNC] realtime unavailable: $e');
    }
  }

  void _onNudge() {
    if (!_realtimeConfirmed) {
      _realtimeConfirmed = true;
      _poll?.interval = const Duration(seconds: 60);
    }
    _nudge?.cancel();
    _nudge = Timer(const Duration(milliseconds: 400), () => unawaited(syncNow()));
  }

  /// Sync now. Coalesced: a call during a sync queues exactly one more.
  Future<void> syncNow() async {
    final owner = _uid;
    if (owner.isEmpty) return;
    if (_running) {
      _queued = true;
      return;
    }
    if (NetworkHealth.isOffline) {
      phase.value = ChatSyncPhase.offline;
      return;
    }
    _running = true;
    if (!_syncedSinceConnect) phase.value = ChatSyncPhase.connecting;
    try {
      final rows = await _syncList(owner);
      if (_uid != owner) return;
      _syncedSinceConnect = true;
      _syncedThisSession = true;
      firstLoadError.value = null;
      phase.value = ChatSyncPhase.idle;
      final arrived = rows.where((r) => r.unreadCount > 0).toList();
      if (arrived.isNotEmpty) {
        // Whatever is unread here has reached this phone: the sender's
        // second tick. Only chats whose newest message moved.
        unawaited(DeliveryReceipts.acknowledge(
          uid: owner,
          chatIds: arrived.map((r) => r.id),
          newest: {for (final r in arrived) r.id: r.updatedAt},
        ));
      }
      _background = _afterListSync(owner);
    } catch (e) {
      if (_uid != owner) return;
      debugPrint('[CHAT_SYNC] list sync failed: $e');
      phase.value = NetworkHealth.isOffline ? ChatSyncPhase.offline : ChatSyncPhase.connecting;
      // An error is not an emptiness: report it only while the database has
      // never held a list for this account (see conversationEmissionFor).
      final hasList = await ChatStore.instance.hasConversations(owner);
      if (_uid == owner &&
          conversationEmissionFor(fetchSucceeded: false, hasDeliveredList: hasList) ==
              ConversationEmission.error) {
        firstLoadError.value = e;
      }
    } finally {
      _running = false;
      if (_queued && _uid == owner) {
        _queued = false;
        unawaited(Future.microtask(syncNow));
      } else {
        _queued = false;
      }
    }
  }

  /// Steps 1–3. Returns the rows read, newest first.
  Future<List<ChatRowSnapshot>> _syncList(String owner) async {
    final store = ChatStore.instance;
    final cursorRaw = await store.syncValue(owner, 'conversations_cursor');
    final cursor = cursorRaw == null ? null : DateTime.tryParse(cursorRaw);
    final rows = <ChatRowSnapshot>[];
    var offset = 0;
    var limit = cursor == null ? _pageSize : _headPage;
    for (var page = 0; page < _maxPages; page++) {
      final batch = await transport.fetchRows(owner, limit: limit, offset: offset);
      rows.addAll(batch);
      if (batch.length < limit) break;
      // Caught up with what the database already holds.
      if (cursor != null && !batch.last.updatedAt.isAfter(cursor)) break;
      offset += batch.length;
      limit = _pageSize;
    }

    // People: everyone on the session's first sync (names and photos change),
    // afterwards only those this phone cannot name.
    final ids = rows.map((r) => r.participantId).where((id) => id.isNotEmpty).toSet();
    final wanted = _syncedThisSession ? await store.unnamedPeople(owner, ids) : ids;
    var people = const <String, ChatPerson>{};
    if (wanted.isNotEmpty) {
      try {
        people = await transport.fetchProfiles(wanted);
      } catch (e) {
        // THE "?" BUG, STOPPED HERE. The rows are good; the people are not
        // known this time. Store the rows and leave every name as it was.
        debugPrint('[CHAT_SYNC] profiles unavailable ($e) — keeping known names');
      }
    }

    String? newest;
    DateTime? newestAt;
    for (final r in rows) {
      if (r.serverUpdatedAt.isEmpty) continue;
      if (newestAt == null || r.updatedAt.isAfter(newestAt)) {
        newestAt = r.updatedAt;
        newest = r.serverUpdatedAt;
      }
    }
    if (_uid != owner) return rows;
    await store.applyConversationSync(owner, rows: rows, people: people, cursor: newest);
    debugPrint('[CHAT_SYNC] list: ${rows.length} rows, ${people.length}/${wanted.length} profiles');
    return rows;
  }

  /// Step 4: threads, photos and thumbnails, one at a time, never blocking
  /// the list.
  Future<void> _afterListSync(String owner) async {
    if (_backgroundRunning) return;
    _backgroundRunning = true;
    try {
      final store = ChatStore.instance;
      final recent = await store.recentThreads(owner, limit: _threadsToKeepWarm);
      final urgent = recent.where((c) => _urgentThreads.contains(c.chatId)).toList();
      final ordered = [...urgent, ...recent.where((c) => !_urgentThreads.contains(c.chatId))];
      var fetched = 0;
      for (final c in ordered) {
        if (_uid != owner || NetworkHealth.isOffline) return;
        final urgentOne = _urgentThreads.remove(c.chatId);
        if (!c.isStale && !urgentOne) continue;
        try {
          final page = await transport.fetchThread(c.chatId, owner, limit: _messagesPerThread);
          if (_uid != owner) return;
          await store.upsertMessages(owner, c.chatId, page);
          await store.setThreadSynced(owner, c.chatId, c.lastMessageAt);
          fetched++;
        } catch (e) {
          debugPrint('[CHAT_SYNC] thread ${shortId(c.chatId)} not fetched: $e');
          break; // the network is struggling; the next sync resumes here
        }
      }
      if (fetched > 0) debugPrint('[CHAT_SYNC] threads fetched: $fetched');
      if (_uid != owner || NetworkHealth.isOffline) return;
      await ChatMediaStore.syncAvatars(owner);
      if (_uid != owner || NetworkHealth.isOffline) return;
      // Thumbnails for the five most recent chats always; for all thirty when
      // the connection is not metered.
      final unmetered = await _isUnmetered();
      final thumbChats = recent.take(unmetered ? _threadsToKeepWarm : 5).map((c) => c.chatId).toList();
      await ChatMediaStore.ensureThumbs(owner, thumbChats, limit: unmetered ? 60 : 20);
    } catch (e) {
      debugPrint('[CHAT_SYNC] background: $e');
    } finally {
      _backgroundRunning = false;
    }
  }

  static Future<bool> _isUnmetered() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }
}

/// What [ChatSync] reads from the server. The defaults are the app's real
/// reads; a test supplies its own to drive a sync without a network.
class ChatSyncTransport {
  const ChatSyncTransport({
    this.fetchRows = ChatServiceSupabase.fetchConversationRows,
    this.fetchProfiles = ChatServiceSupabase.fetchProfiles,
    this.fetchThread = _fetchThread,
  });

  final Future<List<ChatRowSnapshot>> Function(String me, {int limit, int offset}) fetchRows;
  final Future<Map<String, ChatPerson>> Function(Iterable<String> ids) fetchProfiles;
  final Future<List<Message>> Function(String chatId, String me, {int limit}) fetchThread;

  static Future<List<Message>> _fetchThread(String chatId, String me, {int limit = 50}) async =>
      (await ChatServiceSupabase.fetchMessagesPage(chatId, me, limit: limit)).messages;
}
