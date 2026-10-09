import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_notification.dart';
import '../models/post_model.dart';
import 'chat_store.dart';
import 'session_scope.dart';

/// Registers the in-memory message mirror with [SessionScope] so it is dropped
/// at a session boundary like every other user-owned store.
///
/// The map is already uid-namespaced, so a cross-account READ is impossible;
/// this is the second defence SessionScope insists on — making the data absent
/// as well as unaddressable.
class MessageMemoScope implements SessionScoped {
  const MessageMemoScope();

  @override
  void resetForSignOut() => CacheService.resetMessageMemo();
}

/// Keys for offline cache in SharedPreferences.
///
/// PUBLIC vs USER-OWNED
/// --------------------
/// `posts` is the public marketplace — identical for every account, so it
/// stays device-global and survives a session change (a cold feed on every
/// sign-in would cost real UX and protect nothing).
///
/// Conversations, message threads and the outbox are USER-OWNED. They live in
/// the account's own chat database (`ChatStore`, one file per uid), and the
/// methods below that touch them are a facade over it. Builds up to 1.0.2 kept
/// them here under uid-scoped [SessionKeys]; `ChatStore` imports those once and
/// deletes them. Either way the uid decides WHICH store is read, so a read
/// performed as C cannot address data written as A — the isolation is
/// structural, not a filter applied afterwards.
class _Keys {
  static const String posts = 'help24_cache_posts';
  // 'help24_cache_jobs' was here, holding the parallel jobs corpus. Removed
  // with the corpus — see the note where saveJobs/loadJobs used to be.
}

/// Saves and loads posts/jobs for offline use. When offline and cache exists, UI shows cached data.
///
/// Every user-owned method takes the owning [userId] explicitly rather than
/// reading an ambient "current user". An ambient read is what allows a stale
/// value to be used after the session it belonged to has ended; passing the
/// owner makes each call site prove which account the data belongs to.
class CacheService {
  /// Deliberately NOT memoized in a local static.
  ///
  /// `SharedPreferences.getInstance()` already returns a process-wide
  /// singleton, so caching it here bought nothing — but it did mean this class
  /// could keep serving reads from a handle that [SessionScope]'s purge had
  /// operated on separately. One handle, one source of truth: when the session
  /// purge removes a key, the very next read here sees it gone.
  static Future<SharedPreferences> get _instance =>
      SharedPreferences.getInstance();

  // ---------- In-memory mirror of the message cache ----------
  //
  // NOT a second cache. It is a read-through memo over the SAME
  // SharedPreferences entries, keyed by the SAME scoped key, so it cannot
  // disagree with disk about who owns what. It exists because the disk read is
  // async: `loadMessages` needs a SharedPreferences handle plus a JSON decode,
  // so a chat opening from cache still paints a spinner for the first frame or
  // two. Measured on a Galaxy S20+: +25ms to the cached paint with a warm disk
  // cache. This makes that path synchronous, so the thread is on screen in the
  // FIRST frame.
  //
  // Isolation: entries are stored under the uid-scoped key, and the whole map
  // is dropped at a session boundary via [_MessageMemo] below. Both of
  // SessionScope's defences therefore still apply — namespacing AND purge.
  static final Map<String, List<Message>> _memMessages = {};

  /// Drop the in-memory mirror. Called at sign-out through [SessionScope].
  static void resetMessageMemo() => _memMessages.clear();

  /// Synchronous peek — returns null when nothing is memoised yet.
  ///
  /// Callers MUST treat null as "not known yet", never as "no messages":
  /// the disk may still hold a thread this session has not read.
  static List<Message>? peekMessages(String chatId, String currentUserId) {
    if (chatId.isEmpty || currentUserId.isEmpty) return null;
    return _memMessages[SessionScope.scopedKey(
      SessionKeys.messages,
      currentUserId,
      chatId,
    )];
  }

  static Future<void> savePosts(List<PostModel> posts) async {
    try {
      final prefs = await _instance;
      final list = posts.map((p) => p.toCacheMap()).toList();
      final json = jsonEncode(list);
      await prefs.setString(_Keys.posts, json);
    } catch (e) {
      // Non-critical; ignore
    }
  }

  static Future<List<PostModel>> loadPosts() async {
    try {
      final prefs = await _instance;
      final json = prefs.getString(_Keys.posts);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => PostModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  // The jobs cache lived here. It served AppProvider's parallel `_jobs` corpus,
  // whose only reader was the Jobs TAB — now a scope pill in Discover, served
  // by the posts cache like every other scope. Installs that ran an older build
  // still hold a 'help24_cache_jobs' value; nothing reads it, and it is dropped
  // whenever the OS clears app data. Not worth a migration to delete.

  // ---------- Conversations (offline messages list) ----------
  //
  // Backed by the chat database (`ChatStore`) since the local-first rebuild.
  // These two remain as the facade older call sites and tests use; the
  // Messages tab itself reads ChatStore directly and ChatSync writes it.

  /// Replace [userId]'s stored list with [list] — an empty list persists the
  /// fact "this account has no conversations".
  static Future<void> saveConversations(
    String userId,
    List<Conversation> list,
  ) async {
    if (userId.isEmpty) return;
    try {
      await ChatStore.instance.replaceConversations(userId, list);
    } catch (e) {
      // Non-critical
    }
  }

  static Future<List<Conversation>> loadConversations(String userId) async {
    if (userId.isEmpty) return [];
    return ChatStore.instance.loadConversations(userId);
  }

  // ---------- Notifications (offline notification centre) ----------

  /// The notification register, with its unread count.
  ///
  /// The count is stored ALONGSIDE the rows rather than derived from them, and
  /// that is the point: the register is paginated, so counting the rows on disk
  /// would under-report every user with more unread notifications than one page
  /// — and a badge that reads (7) online and (3) offline is worse than no badge.
  /// The stored figure is the last authoritative answer the server gave, which
  /// is exactly what a cold start should render on its first frame instead of
  /// the zero it used to show while a query was in flight.
  static Future<void> saveNotifications(
    String userId,
    List<AppNotification> list, {
    required int unread,
  }) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await _instance;
      await prefs.setString(
        SessionScope.scopedKey(SessionKeys.notifications, userId),
        jsonEncode({
          'unread': unread,
          // Bounded: the register is history, and history is read from the
          // server. This is the window somebody can scroll offline, not an
          // archive.
          'rows': list.take(_maxCachedNotifications).map((n) => n.toCacheMap()).toList(),
        }),
      );
    } catch (e) {
      // Non-critical
    }
  }

  static Future<({List<AppNotification> rows, int unread})> loadNotifications(
    String userId,
  ) async {
    if (userId.isEmpty) return (rows: const <AppNotification>[], unread: 0);
    try {
      final prefs = await _instance;
      final json =
          prefs.getString(SessionScope.scopedKey(SessionKeys.notifications, userId));
      if (json == null || json.isEmpty) {
        return (rows: const <AppNotification>[], unread: 0);
      }
      final decoded = jsonDecode(json);
      if (decoded is! Map) return (rows: const <AppNotification>[], unread: 0);
      final rawRows = decoded['rows'];
      final rows = <AppNotification>[
        if (rawRows is List)
          for (final row in rawRows)
            if (row is Map)
              AppNotification.fromJson(Map<String, dynamic>.from(row)),
      ];
      final unread = decoded['unread'];
      return (rows: rows, unread: unread is int ? unread : 0);
    } catch (e) {
      return (rows: const <AppNotification>[], unread: 0);
    }
  }

  static const int _maxCachedNotifications = 60;

  // ---------- Messages per chat (offline chat view) ----------

  /// Message BODIES — the most sensitive thing the app keeps. They live in the
  /// account's own database file, so a read as one account cannot reach
  /// another's (`ChatStore.fileNameFor`), and `isMe` is resolved against the
  /// file's owner.
  ///
  /// UPSERT, not replace: a page of messages is a window onto the thread, and
  /// writing it must never delete the older history the database already
  /// holds. "Clear chat" is [clearMessages].
  static Future<void> saveMessages(
    String userId,
    String chatId,
    List<Message> messages,
  ) async {
    if (userId.isEmpty || chatId.isEmpty || messages.isEmpty) return;
    final key = SessionScope.scopedKey(SessionKeys.messages, userId, chatId);
    _memMessages[key] = List<Message>.unmodifiable(
      _mergeById(_memMessages[key] ?? const [], messages),
    );
    try {
      await ChatStore.instance.upsertMessages(userId, chatId, messages);
    } catch (e) {
      // Non-critical
    }
  }

  /// Forget [chatId]'s stored thread on this device.
  static Future<void> clearMessages(String userId, String chatId) async {
    if (userId.isEmpty || chatId.isEmpty) return;
    _memMessages.remove(SessionScope.scopedKey(SessionKeys.messages, userId, chatId));
    try {
      await ChatStore.instance.clearThread(userId, chatId);
    } catch (e) {
      // Non-critical
    }
  }

  /// The newest stored messages of [chatId], oldest first.
  static Future<List<Message>> loadMessages(
    String chatId,
    String currentUserId, {
    int limit = 100,
  }) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return [];
    final messages = await ChatStore.instance.loadThread(currentUserId, chatId, limit: limit);
    if (messages.isNotEmpty) {
      // Memoise so the next open of this thread paints in the first frame.
      _memMessages[SessionScope.scopedKey(SessionKeys.messages, currentUserId, chatId)] =
          List<Message>.unmodifiable(messages);
    }
    return messages;
  }

  /// [a] with [b] merged in by id (b wins), chronological, newest 200 kept.
  static List<Message> _mergeById(List<Message> a, List<Message> b) {
    final byId = <String, Message>{for (final m in a) m.id: m};
    for (final m in b) {
      byId[m.id] = m;
    }
    final merged = byId.values.toList()..sort((x, y) => x.timestamp.compareTo(y.timestamp));
    return merged.length > 200 ? merged.sublist(merged.length - 200) : merged;
  }

  // ---------- Outbox per chat (unsent messages, survive restart) ----------

  /// Persist the queue of messages that have not yet reached the server, so a
  /// message composed offline is not lost when the user leaves the chat or the
  /// app restarts. Passing an empty list clears the outbox for [chatId].
  ///
  /// Kept in the SAME database as the thread, so a message can never be both
  /// delivered (in `messages`) and queued (in `outbox`): writing the server
  /// row removes its queued copy in the same batch.
  static Future<void> saveOutbox(
    String userId,
    String chatId,
    List<Message> outbox,
  ) async {
    if (userId.isEmpty || chatId.isEmpty) return;
    try {
      await ChatStore.instance.replaceOutbox(userId, chatId, outbox);
    } catch (e) {
      // Non-critical
    }
  }

  static Future<List<Message>> loadOutbox(String chatId, String currentUserId) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return [];
    final queued = await ChatStore.instance.loadOutbox(currentUserId, chatId);
    return [
      // 'sending' (OutboxStatus.sending) on disk means a request was open
      // when this was written. A process reading it now has opened none, so
      // the true state is queued — a spinner here would claim work that
      // died with the previous process.
      for (final m in queued) m.status == 'sending' ? m.copyWith(status: 'queued') : m,
    ];
  }

  /// Every chat [userId] has something queued in.
  static Future<List<String>> outboxChatIds(String userId) async {
    if (userId.isEmpty) return [];
    return ChatStore.instance.outboxChatIds(userId);
  }
}
