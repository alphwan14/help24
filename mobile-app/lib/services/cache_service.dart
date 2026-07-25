import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/post_model.dart';
import 'session_scope.dart';

/// Keys for offline cache in SharedPreferences.
///
/// PUBLIC vs USER-OWNED
/// --------------------
/// `posts` and `jobs` are the public marketplace — identical for every account,
/// so they stay device-global and survive a session change (a cold feed on
/// every sign-in would cost real UX and protect nothing).
///
/// Conversations, message threads and the outbox are USER-OWNED and are keyed
/// by uid via [SessionKeys]. They previously shared one device-global key each,
/// which is how account A's chat list rendered inside account C's session. The
/// uid is now part of the key, so a read performed as C cannot address data
/// written as A — the isolation is structural, not a filter applied afterwards.
class _Keys {
  static const String posts = 'help24_cache_posts';
  static const String jobs = 'help24_cache_jobs';
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

  static Future<void> saveJobs(List<JobModel> jobs) async {
    try {
      final prefs = await _instance;
      final list = jobs.map((j) => j.toCacheMap()).toList();
      final json = jsonEncode(list);
      await prefs.setString(_Keys.jobs, json);
    } catch (e) {
      // Non-critical; ignore
    }
  }

  static Future<List<JobModel>> loadJobs() async {
    try {
      final prefs = await _instance;
      final json = prefs.getString(_Keys.jobs);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => JobModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ---------- Conversations (offline messages list) ----------

  static Future<void> saveConversations(
    String userId,
    List<Conversation> list,
  ) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await _instance;
      final maps = list.map((c) => c.toCacheMap()).toList();
      await prefs.setString(
        SessionScope.scopedKey(SessionKeys.conversations, userId),
        jsonEncode(maps),
      );
    } catch (e) {
      // Non-critical
    }
  }

  static Future<List<Conversation>> loadConversations(String userId) async {
    if (userId.isEmpty) return [];
    try {
      final prefs = await _instance;
      final json = prefs
          .getString(SessionScope.scopedKey(SessionKeys.conversations, userId));
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => Conversation.fromCacheMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ---------- Messages per chat (offline chat view) ----------

  /// Message BODIES. The most sensitive thing the app caches, and previously
  /// the most exposed: keyed by chat id alone, it would render one account's
  /// private messages inside another account's session — and attribute them to
  /// the wrong author, since `isMe` is resolved against whoever is reading.
  static Future<void> saveMessages(
    String userId,
    String chatId,
    List<Message> messages,
  ) async {
    if (userId.isEmpty || chatId.isEmpty) return;
    try {
      final prefs = await _instance;
      final key = SessionScope.scopedKey(SessionKeys.messages, userId, chatId);
      final maps = messages.map((m) => m.toCacheMap()).toList();
      await prefs.setString(key, jsonEncode(maps));
    } catch (e) {
      // Non-critical
    }
  }

  static Future<List<Message>> loadMessages(String chatId, String currentUserId) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return [];
    try {
      final prefs = await _instance;
      final key =
          SessionScope.scopedKey(SessionKeys.messages, currentUserId, chatId);
      final json = prefs.getString(key);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map), currentUserId))
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ---------- Outbox per chat (unsent messages, survive restart) ----------

  /// Persist the queue of messages that have not yet reached the server, so a
  /// message composed offline is not lost when the user leaves the chat or the
  /// app restarts. Passing an empty list clears the outbox for [chatId].
  static Future<void> saveOutbox(
    String userId,
    String chatId,
    List<Message> outbox,
  ) async {
    if (userId.isEmpty || chatId.isEmpty) return;
    try {
      final prefs = await _instance;
      final key = SessionScope.scopedKey(SessionKeys.outbox, userId, chatId);
      if (outbox.isEmpty) {
        await prefs.remove(key);
        return;
      }
      final maps = outbox.map((m) => m.toCacheMap()).toList();
      await prefs.setString(key, jsonEncode(maps));
    } catch (e) {
      // Non-critical
    }
  }

  static Future<List<Message>> loadOutbox(String chatId, String currentUserId) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return [];
    try {
      final prefs = await _instance;
      final key =
          SessionScope.scopedKey(SessionKeys.outbox, currentUserId, chatId);
      final json = prefs.getString(key);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map), currentUserId))
          .toList();
    } catch (e) {
      return [];
    }
  }
}
