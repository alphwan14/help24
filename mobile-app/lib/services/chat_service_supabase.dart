import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/api_config.dart';
import '../models/post_model.dart';
import '../utils/time_utils.dart';
import 'supabase_auth_bridge.dart';

/// Outcome of a delete-for-everyone attempt. Distinct cases so the UI can show
/// an accurate message: [windowExpired] is the sender's 15-minute rule;
/// [failed] is a server/RLS/network failure and must NOT be blamed on the window.
enum DeleteForEveryoneResult { success, windowExpired, failed }

/// Supabase-only messaging: chats + chat_messages.
/// Conversation list: polled (Realtime can't filter user1 OR user2).
/// Individual chat messages: Supabase Realtime channel (instant delivery).
class ChatServiceSupabase {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Get or create a chat by (user1, user2, post_id). postId and jobId map to post_id (uuid or null).
  static Future<Conversation> createChat({
    required String user1Id,
    required String user2Id,
    required String currentUserId,
    String initialMessage = '',
    String? postId,
    String? jobId,
  }) async {
    final idA = user1Id.trim();
    final idB = user2Id.trim();
    String u1 = idA.compareTo(idB) <= 0 ? idA : idB;
    String u2 = idA.compareTo(idB) <= 0 ? idB : idA;
    final postIdUuid = _parseUuid(postId ?? jobId);
    debugPrint('ChatServiceSupabase createChat: ordered user1_id=$u1 user2_id=$u2');

    if (u1.isEmpty || u2.isEmpty) {
      throw ChatServiceException('Cannot create chat with empty participant id');
    }
    if (u1 == u2) {
      throw ChatServiceException('Cannot create chat with same participant ids');
    }

    try {
      // Prevent duplicates: always check canonical pair first.
      final existing = await _findExistingChat(
        user1Ordered: u1,
        user2Ordered: u2,
        postIdUuid: postIdUuid,
      );

      late Map<String, dynamic> row;
      late String chatId;
      if (existing != null) {
        row = existing as Map<String, dynamic>;
        chatId = (row['id'] ?? '').toString();
      } else {
        debugPrint('ChatServiceSupabase createChat: inserting ordered user1_id=$u1 user2_id=$u2');
        try {
          final res = await _insertChatRow(
            user1: u1,
            user2: u2,
            postIdUuid: postIdUuid,
            initialMessage: initialMessage,
          );
          row = res as Map<String, dynamic>;
          chatId = (row['id'] ?? '').toString();
        } on PostgrestException catch (e) {
          if (e.code == '23514' && (e.message.contains('chats_user_order'))) {
            // Defensive fallback: retry once with swapped order if DB ordering differs.
            final su1 = u2;
            final su2 = u1;
            debugPrint(
              'ChatServiceSupabase createChat: chats_user_order violation, retry swap user1_id=$su1 user2_id=$su2',
            );
            u1 = su1;
            u2 = su2;
            final retried = await _insertChatRow(
              user1: u1,
              user2: u2,
              postIdUuid: postIdUuid,
              initialMessage: initialMessage,
            );
            row = retried as Map<String, dynamic>;
            chatId = (row['id'] ?? '').toString();
            // Recovered by retrying with swapped order.
          }
          // Race-safe duplicate prevention: if another request inserted first, re-fetch.
          else if (e.code == '23505' || (e.message.toLowerCase().contains('duplicate'))) {
            final racedExisting = await _findExistingChat(
              user1Ordered: u1,
              user2Ordered: u2,
              postIdUuid: postIdUuid,
            );
            if (racedExisting != null) {
              row = racedExisting as Map<String, dynamic>;
              chatId = (row['id'] ?? '').toString();
            } else {
              rethrow;
            }
          } else {
            rethrow;
          }
        }
      }

      final otherId = u1 == currentUserId ? u2 : u1;
      final profile = await _getUserProfile(otherId);

      return Conversation(
        id: chatId,
        participantId: otherId,
        userName: profile.name,
        userAvatar: profile.avatarUrl,
        lastMessage: (row['last_message'] as String? ?? '').toString(),
        lastMessageTime: parseServerTime(row['updated_at']),
        unreadCount: 0,
        postId: row['post_id']?.toString(),
      );
    } catch (e) {
      debugPrint('ChatServiceSupabase createChat: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>?> _findExistingChat({
    required String user1Ordered,
    required String user2Ordered,
    required String? postIdUuid,
  }) async {
    var query = _client
        .from('chats')
        .select()
        .eq('user1', user1Ordered)
        .eq('user2', user2Ordered);
    if (postIdUuid != null) {
      query = query.eq('post_id', postIdUuid);
    } else {
      query = query.isFilter('post_id', null);
    }
    final existing = await query.maybeSingle();
    return existing as Map<String, dynamic>?;
  }

  static Future<dynamic> _insertChatRow({
    required String user1,
    required String user2,
    required String? postIdUuid,
    required String initialMessage,
  }) async {
    final insert = <String, dynamic>{
      'user1': user1,
      'user2': user2,
      'last_message': initialMessage.isEmpty ? '' : _truncate(initialMessage),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (postIdUuid != null) insert['post_id'] = postIdUuid;
    return _client.from('chats').insert(insert).select().single();
  }

  static final _uuidRegex = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static String? _parseUuid(String? s) {
    if (s == null || s.isEmpty) return null;
    return _uuidRegex.hasMatch(s) ? s : null;
  }

  static String _truncate(String s, [int max = 200]) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }

  /// Stream of conversations for current user.
  ///
  /// Hybrid sync: a periodic poll (Realtime postgres_changes can't express
  /// user1 OR user2 in a single filter) plus a chats-table Realtime channel
  /// with one binding per column. Any INSERT/UPDATE on one of my chat rows
  /// (new message bumps last_message/updated_at/unread counts) nudges an
  /// immediate refetch, so the list updates in ~instant time while the poll
  /// degrades to a 60s safety net once Realtime is confirmed alive. If the
  /// chats table isn't in the supabase_realtime publication the channel just
  /// never fires and behavior is identical to the old 15s poll.
  static Stream<List<Conversation>> watchConversations(String currentUserId) {
    if (currentUserId.isEmpty) return Stream.value([]);

    final controller = StreamController<List<Conversation>>.broadcast();
    Timer? timer;
    Timer? nudgeDebounce;
    RealtimeChannel? channel;
    var pollInterval = const Duration(seconds: 15);
    var realtimeConfirmed = false;
    var fetching = false;
    var refetchQueued = false;

    Future<void> emit() async {
      // Coalesce: a nudge landing mid-fetch queues exactly one follow-up.
      if (fetching) {
        refetchQueued = true;
        return;
      }
      fetching = true;
      try {
        final list = await _fetchConversations(currentUserId);
        if (controller.isClosed) return;
        controller.add(list);
      } catch (e) {
        debugPrint('ChatServiceSupabase watchConversations fetch: $e');
        if (!controller.isClosed) controller.add([]);
      } finally {
        fetching = false;
        if (refetchQueued && !controller.isClosed) {
          refetchQueued = false;
          Future.microtask(emit);
        }
      }
    }

    void schedulePoll() {
      timer?.cancel();
      timer = Timer.periodic(pollInterval, (_) => emit());
    }

    void nudge() {
      if (!realtimeConfirmed) {
        realtimeConfirmed = true;
        pollInterval = const Duration(seconds: 60);
        schedulePoll();
      }
      // Debounce bursts (several rows updating at once) into one refetch.
      nudgeDebounce?.cancel();
      nudgeDebounce = Timer(const Duration(milliseconds: 400), emit);
    }

    emit();
    schedulePoll();

    PostgresChangeFilter userFilter(String column) => PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: column,
          value: currentUserId,
        );
    channel = _client.channel('chats_list:$currentUserId');
    for (final event in [PostgresChangeEvent.insert, PostgresChangeEvent.update]) {
      for (final column in ['user1', 'user2']) {
        channel = channel!.onPostgresChanges(
          event: event,
          schema: 'public',
          table: 'chats',
          filter: userFilter(column),
          callback: (_) => nudge(),
        );
      }
    }
    channel!.subscribe();

    controller.onCancel = () {
      timer?.cancel();
      nudgeDebounce?.cancel();
      channel?.unsubscribe();
    };

    return controller.stream;
  }

  static const int _conversationsPageSize = 20;

  static Future<List<Conversation>> _fetchConversations(
    String currentUserId, {
    int limit = _conversationsPageSize,
    int offset = 0,
  }) async {
    // Join posts(title) via the chats_post_id_fkey FK constraint.
    // user1_unread_count / user2_unread_count come from migration 025.
    // Filter: only return chats where a message has been sent (last_message != '').
    // This hides empty/orphaned chat rows that were created before a message was sent.
    final response = await _client
        .from('chats')
        .select('*, posts!chats_post_id_fkey(title)')
        .or('user1.eq.$currentUserId,user2.eq.$currentUserId')
        .neq('last_message', '')
        .order('updated_at', ascending: false)
        .range(offset, offset + limit - 1);

    final rows = response as List;

    // Collect all participant IDs, then fetch profiles in one batch query
    // instead of N sequential queries (eliminates N+1 pattern).
    final otherIds = <String>[];
    for (final row in rows) {
      final map = row as Map<String, dynamic>;
      final user1 = map['user1'] as String? ?? '';
      final user2 = map['user2'] as String? ?? '';
      otherIds.add(user1 == currentUserId ? user2 : user1);
    }
    final profiles = await _getBatchUserProfiles(otherIds);

    final list = <Conversation>[];
    for (final row in rows) {
      final map = row as Map<String, dynamic>;
      final user1 = map['user1'] as String? ?? '';
      final user2 = map['user2'] as String? ?? '';
      final otherId = user1 == currentUserId ? user2 : user1;
      final profile = profiles[otherId] ??
          (name: '?', avatarUrl: '', isOnline: false, lastSeen: null);
      final postsRaw = map['posts'];
      final postsData = postsRaw is Map<String, dynamic> ? postsRaw : null;
      final postTitle = postsData?['title'] as String?;

      // Determine this user's unread count from the correct column.
      final int unreadCount;
      if (user1 == currentUserId) {
        unreadCount = (map['user1_unread_count'] as int?) ?? 0;
      } else {
        unreadCount = (map['user2_unread_count'] as int?) ?? 0;
      }

      list.add(Conversation(
        id: (map['id'] ?? '').toString(),
        participantId: otherId,
        userName: profile.name,
        userAvatar: profile.avatarUrl,
        lastMessage: map['last_message'] as String? ?? '',
        lastMessageTime: parseServerTime(map['updated_at']),
        unreadCount: unreadCount,
        postId: map['post_id']?.toString(),
        postTitle: postTitle,
        isOnline: profile.isOnline,
        lastSeen: profile.lastSeen,
      ));
    }
    return list;
  }

  /// Fetch profiles (incl. presence) for multiple user IDs in a single query.
  /// Returns a map of userId → profile record.
  static Future<Map<String, ({String name, String avatarUrl, bool isOnline, DateTime? lastSeen})>>
      _getBatchUserProfiles(
    List<String> userIds,
  ) async {
    final result = <String, ({String name, String avatarUrl, bool isOnline, DateTime? lastSeen})>{};
    final uniqueIds = userIds.where((id) => id.isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return result;
    try {
      final r = await _client
          .from('users')
          .select('id, name, email, avatar_url, profile_image, is_online, last_seen')
          .inFilter('id', uniqueIds);
      for (final row in r as List) {
        final map = row as Map<String, dynamic>;
        final id = map['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final name = map['name']?.toString().trim();
        final email = map['email']?.toString().trim();
        final displayName = (name != null && name.isNotEmpty)
            ? name
            : (email != null && email.isNotEmpty
                ? (email.split('@').first.trim().isNotEmpty
                    ? email.split('@').first.trim()
                    : '?')
                : '?');
        final avatar = map['avatar_url']?.toString().trim();
        final profileImage = map['profile_image']?.toString().trim();
        result[id] = (
          name: displayName,
          avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : (profileImage ?? ''),
          isOnline: map['is_online'] as bool? ?? false,
          lastSeen: map['last_seen'] != null
              ? DateTime.tryParse(map['last_seen'].toString())
              : null,
        );
      }
    } catch (e) {
      debugPrint('ChatServiceSupabase _getBatchUserProfiles: $e');
    }
    return result;
  }

  /// Fetch a page of conversations (for load more). Returns (list, hasMore).
  static Future<({List<Conversation> list, bool hasMore})> getConversationsPage(
    String currentUserId, {
    int limit = _conversationsPageSize,
    int offset = 0,
  }) async {
    final list = await _fetchConversations(currentUserId, limit: limit, offset: offset);
    return (list: list, hasMore: list.length >= limit);
  }

  static const int _messagesPageSize = 30;

  /// Fetches the latest [limit] messages (newest first from DB), returned in chronological order.
  /// [before] optional cursor (ISO8601 created_at) to load older messages.
  /// Returns (messages in chronological order, hasMore).
  static Future<({List<Message> messages, bool hasMore})> getMessagesPage(
    String chatIdParam,
    String currentUserId, {
    int limit = _messagesPageSize,
    String? before,
  }) async {
    if (chatIdParam.isEmpty) return (messages: <Message>[], hasMore: false);
    try {
      var query = _client
          .from('chat_messages')
          .select()
          .eq('chat_id', chatIdParam);
      if (before != null && before.isNotEmpty) {
        query = query.lt('created_at', before);
      }
      final res = await query
          .order('created_at', ascending: false)
          .limit(limit);
      final rows = res as List;
      final list = rows
          .map((e) => _messageFromRow(e as Map<String, dynamic>, chatIdParam, currentUserId))
          .toList();
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return (messages: list, hasMore: list.length >= limit);
    } catch (e) {
      debugPrint('ChatServiceSupabase getMessagesPage: $e');
      return (messages: <Message>[], hasMore: false);
    }
  }

  /// Fetch messages for a single chat. Ordered by created_at ascending. No Realtime.
  /// Kept for backward compatibility; prefer [getMessagesPage] for pagination.
  static Future<List<Message>> getMessages(String chatIdParam, String currentUserId) async {
    final result = await getMessagesPage(chatIdParam, currentUserId);
    return result.messages;
  }

  static Message _messageFromRow(Map<String, dynamic> row, String chatIdParam, String currentUserId) {
    final id = (row['id'] ?? '').toString();
    final senderId = (row['sender_id'] ?? '').toString();
    final content = (row['content'] ?? row['message'] ?? '').toString();
    final type = (row['type'] ?? 'text').toString();
    // UTC-normalised: REST sends an offset designator, Realtime/WAL often does
    // not. parseServerTime makes both paths yield the same instant.
    final createdAt = parseServerTime(row['created_at']);
    final map = <String, dynamic>{
      'id': id,
      'conversation_id': chatIdParam,
      'chat_id': chatIdParam,
      'sender_id': senderId,
      'content': content,
      'message': content,
      'type': type,
      'created_at': toServerTime(createdAt),
      'status': (row['status'] ?? 'sent').toString(),
      if (row['seen_at'] != null) 'seen_at': row['seen_at'].toString(),
    };
    if (row['latitude'] != null) map['latitude'] = (row['latitude'] as num).toDouble();
    if (row['longitude'] != null) map['longitude'] = (row['longitude'] as num).toDouble();
    if (row['live_until'] != null) map['live_until'] = row['live_until'].toString();
    if (row['attachment_url'] != null) map['attachment_url'] = row['attachment_url'].toString();
    if (row['deleted_for_everyone'] != null) {
      map['deleted_for_everyone'] = row['deleted_for_everyone'] as bool;
    }
    if (row['reply_to_id']      != null) map['reply_to_id']      = row['reply_to_id'].toString();
    if (row['reply_to_sender']  != null) map['reply_to_sender']  = row['reply_to_sender'].toString();
    if (row['reply_to_preview'] != null) map['reply_to_preview'] = row['reply_to_preview'].toString();
    return Message.fromJson(map, currentUserId);
  }

  /// Case-insensitive text search within one chat. Excludes tombstones
  /// (deleted_for_everyone is NOT NULL DEFAULT false per migration 042).
  /// Newest matches first.
  static Future<List<Message>> searchMessages(
    String chatId,
    String currentUserId,
    String query, {
    int limit = 50,
  }) async {
    final q = query.trim();
    if (chatId.isEmpty || q.isEmpty) return [];
    try {
      final escaped = q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
      final res = await _client
          .from('chat_messages')
          .select()
          .eq('chat_id', chatId)
          .eq('type', 'text')
          .neq('deleted_for_everyone', true)
          .ilike('content', '%$escaped%')
          .order('created_at', ascending: false)
          .limit(limit);
      return (res as List)
          .map((e) => _messageFromRow(e as Map<String, dynamic>, chatId, currentUserId))
          .toList();
    } catch (e) {
      debugPrint('ChatServiceSupabase searchMessages: $e');
      return [];
    }
  }

  /// Mark all unread messages (not sent by current user) as seen,
  /// and reset this user's unread counter in the chats row.
  /// Call when the user opens a chat or new messages arrive while they are viewing it.
  static Future<void> markMessagesSeen(String chatId, String currentUserId) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return;
    try {
      // Mark individual message rows as seen.
      await _client
          .from('chat_messages')
          .update({
            'status': 'seen',
            'seen_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('chat_id', chatId)
          .neq('sender_id', currentUserId)
          .neq('status', 'seen');

    } catch (e) {
      debugPrint('ChatServiceSupabase markMessagesSeen (status update): $e');
      return;
    }

    // Reset unread counter — only works after migration 025 is applied.
    try {
      final chatRow = await _client
          .from('chats')
          .select('user1, user2')
          .eq('id', chatId)
          .maybeSingle();
      if (chatRow == null) return;
      final isUser1 = (chatRow['user1'] as String?) == currentUserId;
      final countCol = isUser1 ? 'user1_unread_count' : 'user2_unread_count';
      await _client.from('chats').update({countCol: 0}).eq('id', chatId);
    } catch (_) {
      // Column doesn't exist yet (migration 025 pending). Safe to ignore.
    }
  }

  /// Broadcast that the current user is typing. Debounce in the UI — don't call on every keystroke.
  static Future<void> setTyping(String chatId, String userId) async {
    if (chatId.isEmpty || userId.isEmpty) return;
    try {
      await _client.from('chats').update({
        'typing_user_id': userId,
        'typing_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatId);
    } catch (e) {
      debugPrint('ChatServiceSupabase setTyping: $e');
    }
  }

  /// Clear typing state (called on send or after idle timeout).
  static Future<void> clearTyping(String chatId, String userId) async {
    if (chatId.isEmpty || userId.isEmpty) return;
    try {
      // Only clear if this user is the one currently marked as typing.
      await _client
          .from('chats')
          .update({'typing_user_id': null, 'typing_at': null})
          .eq('id', chatId)
          .eq('typing_user_id', userId);
    } catch (e) {
      debugPrint('ChatServiceSupabase clearTyping: $e');
    }
  }

  /// Returns true when the other participant has been typing within the last 4 seconds.
  static Future<bool> isOtherUserTyping(String chatId, String currentUserId) async {
    if (chatId.isEmpty) return false;
    try {
      final r = await _client
          .from('chats')
          .select('typing_user_id, typing_at')
          .eq('id', chatId)
          .single();
      final map = r as Map<String, dynamic>;
      final typingUser = map['typing_user_id']?.toString();
      final typingAt = map['typing_at'] != null
          ? DateTime.tryParse(map['typing_at'].toString())
          : null;
      if (typingUser == null || typingUser.isEmpty || typingUser == currentUserId || typingAt == null) {
        return false;
      }
      return DateTime.now().difference(typingAt.toLocal()).inSeconds < 4;
    } catch (e) {
      return false;
    }
  }

  /// Real-time stream of messages for a single chat using Supabase Realtime.
  /// Initial load fetches the page; subsequent events are applied incrementally
  /// from the realtime payload — no full re-fetch per message (eliminates N
  /// round-trips after initial load).
  /// The caller should cancel the subscription in dispose().
  /// Live message stream for one chat.
  ///
  /// Delivery contract: a row inserted or updated by ANY participant lands in
  /// this stream while the screen stays open — no reopen, no poll.
  ///
  /// Resilience, learned from a production outage where the thread only ever
  /// populated from the initial REST fetch:
  ///  • INSERT and UPDATE get their OWN channels. Postgres-changes bindings are
  ///    validated per channel, so one rejected binding used to fail the whole
  ///    channel and silently take new-message delivery down with it. Split, a
  ///    degraded UPDATE path can never cost us new messages.
  ///  • The JWT is resolved BEFORE subscribing. Realtime authorises the socket
  ///    at join time; joining before the Firebase→Supabase exchange finished
  ///    joined as `anon`, RLS rejected it, and the channel died permanently.
  ///  • channelError / timedOut / closed schedule a re-subscribe with capped
  ///    exponential backoff instead of leaving a dead socket.
  ///  • Every successful (re)join triggers ONE catch-up fetch to heal the gap
  ///    that existed while disconnected. This is reconciliation on a lifecycle
  ///    edge, not polling — nothing runs on a timer.
  ///  • Channel topics are unique per subscription, so opening the same chat
  ///    twice (deep link over an open thread) cannot collide on one topic.
  static Stream<List<Message>> watchMessages(
    String chatId,
    String currentUserId,
  ) {
    if (chatId.isEmpty) return Stream.value([]);

    final controller = StreamController<List<Message>>.broadcast();
    final messages = <Message>[];
    final topicSuffix = DateTime.now().microsecondsSinceEpoch;

    RealtimeChannel? insertChannel;
    RealtimeChannel? updateChannel;
    Timer? retryTimer;
    Timer? stabilityTimer;
    var retryAttempt = 0;
    var disposed = false;
    var resyncing = false;
    DateTime? lastResyncAt;
    // Bumped on every (re)subscribe. Status callbacks carry the generation they
    // were created with, so callbacks from channels we have already torn down
    // (removeChannel fires `closed`) can't schedule retries for the live one.
    var generation = 0;

    void emit() {
      if (!controller.isClosed) controller.add(List.of(messages));
    }

    /// Insert-or-replace by id, keeping the thread in chronological order.
    /// Idempotent: realtime redelivery and a catch-up fetch covering the same
    /// row converge to one entry, so nothing double-renders.
    void upsert(Message msg, {bool insertIfMissing = true}) {
      if (msg.id.isEmpty) return;
      final idx = messages.indexWhere((m) => m.id == msg.id);
      if (idx != -1) {
        messages[idx] = msg;
      } else {
        if (!insertIfMissing) return;
        messages.add(msg);
        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
      emit();
    }

    /// One-shot reconciliation: pulls the latest page and merges it in. Used
    /// for the first load and after every reconnect.
    Future<void> resync({bool force = false}) async {
      if (disposed || resyncing) return;
      // Throttle: a server that rejects our bindings can flap subscribed→error
      // repeatedly, and each rejoin would otherwise fire a REST fetch.
      final since = lastResyncAt;
      if (!force && since != null &&
          DateTime.now().difference(since) < const Duration(seconds: 5)) {
        return;
      }
      lastResyncAt = DateTime.now();
      resyncing = true;
      try {
        final result = await getMessagesPage(chatId, currentUserId);
        if (disposed) return;
        var changed = false;
        for (final m in result.messages) {
          final idx = messages.indexWhere((e) => e.id == m.id);
          if (idx == -1) {
            messages.add(m);
            changed = true;
          } else if (messages[idx] != m) {
            messages[idx] = m;
            changed = true;
          }
        }
        if (changed) {
          messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
        // Always emit the first load so the screen can leave its spinner even
        // when the thread is empty.
        emit();
      } catch (e) {
        debugPrint('ChatServiceSupabase watchMessages resync: $e');
        // Surface the failure ONLY when we have nothing to show. With messages
        // already on screen (cache or an earlier page) a failed refresh is a
        // non-event; with none, the screen must say "couldn't load" instead of
        // rendering the empty state, which reads as "this chat has no messages"
        // and is simply untrue.
        if (!disposed && messages.isEmpty && !controller.isClosed) {
          controller.addError(e);
        }
      } finally {
        resyncing = false;
      }
    }

    void handleRow(PostgresChangePayload payload, {required bool isInsert}) {
      try {
        final row = Map<String, dynamic>.from(payload.newRecord);
        if (row.isEmpty) return;
        // An UPDATE for a row we have not loaded yet (older page) is not worth
        // materialising; an INSERT always is.
        upsert(
          _messageFromRow(row, chatId, currentUserId),
          insertIfMissing: isInsert,
        );
      } catch (e) {
        debugPrint('ChatServiceSupabase watchMessages payload: $e');
      }
    }

    // Declared late so scheduleRetry/onStatus (defined below) can re-enter it.
    late final Future<void> Function() subscribeAll;

    void scheduleRetry(String reason) {
      if (disposed || retryTimer != null) return;
      retryAttempt = retryAttempt >= 5 ? 5 : retryAttempt + 1;
      final delay = Duration(seconds: 1 << (retryAttempt - 1)); // 1,2,4,8,16s
      debugPrint(
        'ChatServiceSupabase watchMessages: $reason — resubscribing in '
        '${delay.inSeconds}s (attempt $retryAttempt)',
      );
      retryTimer = Timer(delay, () {
        retryTimer = null;
        if (!disposed) unawaited(subscribeAll());
      });
    }

    void teardownChannels() {
      final oldInsert = insertChannel;
      final oldUpdate = updateChannel;
      insertChannel = null;
      updateChannel = null;
      if (oldInsert != null) _client.removeChannel(oldInsert);
      if (oldUpdate != null) _client.removeChannel(oldUpdate);
    }

    void onStatus(
      String label,
      int gen,
      RealtimeSubscribeStatus status,
      Object? error,
    ) {
      // Ignore late callbacks from a superseded subscription.
      if (disposed || gen != generation) return;
      debugPrint(
        'ChatServiceSupabase watchMessages[$label] status: $status error: $error',
      );
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          // Joined (or re-joined): heal whatever we missed while away.
          unawaited(resync());
          // Only clear the backoff once the join has PROVEN stable. A server
          // that accepts the join then immediately rejects the binding (e.g.
          // the table is not in the realtime publication) would otherwise reset
          // the backoff every cycle and spin a hot retry loop.
          stabilityTimer?.cancel();
          stabilityTimer = Timer(const Duration(seconds: 8), () {
            if (!disposed && gen == generation) retryAttempt = 0;
          });
          break;
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
        case RealtimeSubscribeStatus.closed:
          stabilityTimer?.cancel();
          stabilityTimer = null;
          scheduleRetry('$label $status');
          break;
      }
    }

    subscribeAll = () async {
      if (disposed) return;
      final gen = ++generation; // invalidates callbacks from the old channels
      teardownChannels();

      // Realtime authorises the socket at JOIN time. Resolve the Supabase JWT
      // first, otherwise the channel joins as `anon`, RLS rejects it and the
      // subscription is dead for the life of the screen.
      try {
        await SupabaseAuthBridge.ensureSessionAsync();
      } catch (e) {
        debugPrint('ChatServiceSupabase watchMessages auth: $e');
      }
      if (disposed || gen != generation) return;

      final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'chat_id',
        value: chatId,
      );

      insertChannel = _client
          .channel('chat_messages_ins:$chatId:$topicSuffix')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'chat_messages',
            filter: filter,
            callback: (p) => handleRow(p, isInsert: true),
          )
          .subscribe((status, [error]) => onStatus('insert', gen, status, error));

      updateChannel = _client
          .channel('chat_messages_upd:$chatId:$topicSuffix')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'chat_messages',
            filter: filter,
            callback: (p) => handleRow(p, isInsert: false),
          )
          .subscribe((status, [error]) => onStatus('update', gen, status, error));
    };

    unawaited(resync());
    unawaited(subscribeAll());

    controller.onCancel = () {
      disposed = true;
      retryTimer?.cancel();
      retryTimer = null;
      stabilityTimer?.cancel();
      stabilityTimer = null;
      teardownChannels();
    };

    return controller.stream;
  }

  /// Send text message.
  static Future<Message> sendMessage({
    required String chatIdParam,
    required String senderId,
    required String content,
    String? replyToId,
    String? replyToSender,
    String? replyToPreview,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ChatServiceException('Message cannot be empty');
    try {
      final insert = <String, dynamic>{
        'chat_id': chatIdParam,
        'sender_id': senderId,
        'content': text,
        'type': 'text',
        if (replyToId      != null) 'reply_to_id':      replyToId,
        if (replyToSender  != null) 'reply_to_sender':  replyToSender,
        if (replyToPreview != null) 'reply_to_preview': replyToPreview,
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('[CHAT_NOTIFY][SEND] chat_id=$chatIdParam sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': _truncate(text),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatIdParam);
      // Fire-and-forget push notification to recipient.
      unawaited(_notifyBackend(chatId: chatIdParam, senderId: senderId, preview: text));
      return _messageFromRow(row, chatIdParam, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendMessage: $e');
      rethrow;
    }
  }

  /// Send image or file message with attachment URL (upload to Storage first, then call this).
  static Future<Message> sendAttachmentMessage({
    required String chatIdParam,
    required String senderId,
    required String type,
    required String attachmentUrl,
    String caption = '',
  }) async {
    if (type != 'image' && type != 'file') throw ChatServiceException('Type must be image or file');
    try {
      final content = caption.trim().isNotEmpty ? caption.trim() : (type == 'image' ? 'Image' : 'File');
      final insert = {
        'chat_id': chatIdParam,
        'sender_id': senderId,
        'content': content,
        'type': type,
        'attachment_url': attachmentUrl,
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('[CHAT_NOTIFY][SEND] attachment type=$type chat_id=$chatIdParam sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': content,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatIdParam);
      unawaited(_notifyBackend(chatId: chatIdParam, senderId: senderId, preview: content));
      return _messageFromRow(row, chatIdParam, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendAttachmentMessage: $e');
      rethrow;
    }
  }

  /// Send a place (static pin). [label] is the user's human name for the spot
  /// ("Black gate next to the kiosk"); it becomes the message content so chat
  /// previews and reply quotes read naturally. Falls back to 'Location'.
  static Future<Message> sendLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    String? label,
  }) async {
    final content = (label != null && label.trim().isNotEmpty) ? label.trim() : 'Location';
    try {
      final insert = {
        'chat_id': chatId,
        'sender_id': senderId,
        'content': content,
        'type': 'location',
        'latitude': latitude,
        'longitude': longitude,
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendLocation: inserted chat_message id=${row['id']} chat_id=$chatId sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': _truncate(content == 'Location' ? 'Location' : '📍 $content'),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatId);
      // Fire-and-forget push to recipient (NestJS — same path as text/attachments).
      unawaited(_notifyBackend(chatId: chatId, senderId: senderId, preview: '📍 $content'));
      return _messageFromRow(row, chatId, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendLocation: $e');
      rethrow;
    }
  }

  /// Start live location sharing. [content] is the human-readable intent shown
  /// in previews and as the card title: 'On my way' for journeys (default) —
  /// legacy rows carry 'Live location'.
  static Future<Message> sendLiveLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    required int durationMinutes,
    String content = 'On my way',
  }) async {
    // UTC: timestamptz round-trips a naive-local string as UTC (+offset).
    final liveUntil = DateTime.now().toUtc().add(Duration(minutes: durationMinutes));
    try {
      final insert = {
        'chat_id': chatId,
        'sender_id': senderId,
        'content': content,
        'type': 'live_location',
        'latitude': latitude,
        'longitude': longitude,
        'live_until': liveUntil.toIso8601String(),
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendLiveLocation: inserted chat_message id=${row['id']} chat_id=$chatId sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': '🚗 $content',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatId);
      // Fire-and-forget push to recipient (NestJS — same path as text/attachments).
      unawaited(_notifyBackend(chatId: chatId, senderId: senderId, preview: '🚗 $content'));
      return _messageFromRow(row, chatId, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendLiveLocation: $e');
      rethrow;
    }
  }

  /// Ask the other participant for their location. Renders as a Request Card
  /// with an inline "Share now" action on the recipient side. No coordinates
  /// are attached — this is a prompt, not a share.
  static Future<Message> sendLocationRequest({
    required String chatId,
    required String senderId,
  }) async {
    try {
      final insert = {
        'chat_id': chatId,
        'sender_id': senderId,
        'content': 'Location requested',
        'type': 'location_request',
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendLocationRequest: inserted chat_message id=${row['id']} chat_id=$chatId');
      await _client.from('chats').update({
        'last_message': '📍 Location requested',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatId);
      unawaited(_notifyBackend(chatId: chatId, senderId: senderId, preview: '📍 Location requested'));
      return _messageFromRow(row, chatId, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendLocationRequest: $e');
      rethrow;
    }
  }

  /// End a journey as ARRIVED: closes the live window and stamps the message
  /// so both sides render the "Arrived" state (content is the render flag —
  /// same row-update RLS path as stopLiveLocation/updateMessageLocation).
  static Future<void> markJourneyArrived(String messageId) async {
    try {
      await _client.from('chat_messages').update({
        'content': 'Arrived',
        // UTC: live_until is timestamptz; a naive-local string round-trips as
        // UTC and displays +offset (the arrival receipt showed +3h in EAT).
        'live_until': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('ChatServiceSupabase markJourneyArrived: $e');
      rethrow;
    }
  }

  /// Push the traveller's current position onto the live journey row.
  ///
  /// Best-effort by design and therefore NEVER throws: this is a periodic beat
  /// (every 8s) fired from a stream listener that cannot await it, so a rethrow
  /// surfaced as an unhandled async exception on every transient network blip —
  /// observed in the field as repeated
  /// `ClientException: SSLV3_ALERT_BAD_RECORD_MAC` crashing out of the journey
  /// loop. A dropped beat is harmless: the next one carries a fresher position
  /// and supersedes it. Returns false so a caller can react if it wants to.
  static Future<bool> updateMessageLocation({
    required String messageId,
    required double latitude,
    required double longitude,
  }) async {
    try {
      await _client.from('chat_messages').update({
        'latitude': latitude,
        'longitude': longitude,
      }).eq('id', messageId);
      return true;
    } catch (e) {
      debugPrint('ChatServiceSupabase updateMessageLocation (beat dropped): $e');
      return false;
    }
  }

  /// End live location (set live_until to now or clear).
  static Future<void> stopLiveLocation(String messageId) async {
    try {
      await _client.from('chat_messages').update({
        // UTC: timestamptz round-trips a naive-local string as UTC (+offset).
        'live_until': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('ChatServiceSupabase stopLiveLocation: $e');
      rethrow;
    }
  }

  /// Soft-delete a message for everyone. The outcome distinguishes the
  /// 15-minute sender window from a server/RLS failure so the UI never blames
  /// the window for a fresh message that failed for another reason.
  static Future<DeleteForEveryoneResult> deleteMessageForEveryone(
    String messageId,
    DateTime messageTimestamp,
  ) async {
    if (DateTime.now().difference(messageTimestamp).inMinutes > 15) {
      return DeleteForEveryoneResult.windowExpired;
    }
    try {
      // .select() after .update() returns the rows that were actually mutated.
      // An empty list means 0 rows updated — RLS blocked the write silently.
      final rows = await _client.from('chat_messages').update({
        'deleted_for_everyone': true,
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', messageId).select();
      if ((rows as List).isEmpty) {
        debugPrint('ChatServiceSupabase deleteMessageForEveryone: 0 rows updated (RLS?)');
        return DeleteForEveryoneResult.failed;
      }
      return DeleteForEveryoneResult.success;
    } catch (e) {
      debugPrint('ChatServiceSupabase deleteMessageForEveryone: $e');
      return DeleteForEveryoneResult.failed;
    }
  }

  static Future<({String name, String avatarUrl})> _getUserProfile(String userId) async {
    if (userId.isEmpty) return (name: '?', avatarUrl: '');
    try {
      final r = await _client
          .from('users')
          .select('name, email, avatar_url, profile_image')
          .eq('id', userId)
          .maybeSingle();
      if (r != null) {
        final name = r['name']?.toString()?.trim();
        final email = r['email']?.toString()?.trim();
        String displayName = (name != null && name.isNotEmpty)
            ? name
            : (email != null && email.isNotEmpty
                ? (email.split('@').first.trim().isNotEmpty ? email.split('@').first.trim() : '?')
                : '?');
        final avatar = r['avatar_url']?.toString()?.trim();
        final profileImage = r['profile_image']?.toString()?.trim();
        return (
          name: displayName,
          avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : (profileImage ?? ''),
        );
      }
    } catch (e) {
      debugPrint('ChatServiceSupabase _getUserProfile: $e');
    }
    return (name: '?', avatarUrl: '');
  }

  /// Fire-and-forget: tell the backend to push a notification to the
  /// recipient of this chat message. Non-blocking — errors are logged only.
  static Future<void> _notifyBackend({
    required String chatId,
    required String senderId,
    required String preview,
  }) async {
    try {
      debugPrint('[CHAT_NOTIFY][GROUPED] posting to backend chatId=$chatId');
      final response = await http.post(
        Uri.parse(ApiConfig.chatNotify),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chatId':          chatId,
          'senderId':        senderId,
          'messagePreview':  preview.length > 100 ? '${preview.substring(0, 100)}…' : preview,
        }),
      ).timeout(const Duration(seconds: 8));
      debugPrint('[CHAT_NOTIFY][UPDATE_EXISTING] backend status=${response.statusCode}');
    } catch (e) {
      // Never let notification failure affect the message send.
      debugPrint('[CHAT_NOTIFY][ERROR] $e');
    }
  }
}

class ChatServiceException implements Exception {
  final String message;
  ChatServiceException(this.message);
  @override
  String toString() => 'ChatServiceException: $message';
}