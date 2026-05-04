import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';

/// Supabase-only messaging: chats + chat_messages (fetch + polling, no Realtime).
/// Use this for "Contact Provider" and Messages tab.
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
        lastMessageTime: row['updated_at'] != null
            ? DateTime.parse(row['updated_at'].toString())
            : DateTime.now(),
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
      'updated_at': DateTime.now().toIso8601String(),
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

  /// Stream of conversations for current user. Polls periodically (Realtime filter can't do user1 OR user2).
  static Stream<List<Conversation>> watchConversations(String currentUserId) {
    if (currentUserId.isEmpty) return Stream.value([]);

    final controller = StreamController<List<Conversation>>.broadcast();
    Timer? timer;

    Future<void> emit() async {
      try {
        final list = await _fetchConversations(currentUserId);
        if (controller.isClosed) return;
        controller.add(list);
      } catch (e) {
        debugPrint('ChatServiceSupabase watchConversations fetch: $e');
        if (!controller.isClosed) controller.add([]);
      }
    }

    emit();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => emit());
    controller.onCancel = () => timer?.cancel();

    return controller.stream;
  }

  static const int _conversationsPageSize = 20;

  static Future<List<Conversation>> _fetchConversations(
    String currentUserId, {
    int limit = _conversationsPageSize,
    int offset = 0,
  }) async {
    // Join posts(title) via the chats_post_id_fkey FK constraint.
    // FK must exist in DB — see migration 023_chats_post_fkey.sql.
    final response = await _client
        .from('chats')
        .select('*, posts!chats_post_id_fkey(title)')
        .or('user1.eq.$currentUserId,user2.eq.$currentUserId')
        .order('updated_at', ascending: false)
        .range(offset, offset + limit - 1);

    final list = <Conversation>[];
    for (final row in response as List) {
      final map = row as Map<String, dynamic>;
      final user1 = map['user1'] as String? ?? '';
      final user2 = map['user2'] as String? ?? '';
      final otherId = user1 == currentUserId ? user2 : user1;
      final profile = await _getUserProfile(otherId);
      // PostgREST returns the joined row as a Map when FK cardinality is many-to-one,
      // or null when post_id is null. Handle both safely.
      final postsRaw = map['posts'];
      final postsData = postsRaw is Map<String, dynamic> ? postsRaw : null;
      final postTitle = postsData?['title'] as String?;
      list.add(Conversation(
        id: (map['id'] ?? '').toString(),
        participantId: otherId,
        userName: profile.name,
        userAvatar: profile.avatarUrl,
        lastMessage: map['last_message'] as String? ?? '',
        lastMessageTime: map['updated_at'] != null
            ? DateTime.parse(map['updated_at'].toString())
            : DateTime.now(),
        unreadCount: 0,
        postId: map['post_id']?.toString(),
        postTitle: postTitle,
      ));
    }
    return list;
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
    final createdAt = row['created_at'] != null
        ? DateTime.parse(row['created_at'].toString())
        : DateTime.now();
    final map = <String, dynamic>{
      'id': id,
      'conversation_id': chatIdParam,
      'chat_id': chatIdParam,
      'sender_id': senderId,
      'content': content,
      'message': content,
      'type': type,
      'created_at': createdAt.toIso8601String(),
      'status': (row['status'] ?? 'sent').toString(),
      if (row['seen_at'] != null) 'seen_at': row['seen_at'].toString(),
    };
    if (row['latitude'] != null) map['latitude'] = (row['latitude'] as num).toDouble();
    if (row['longitude'] != null) map['longitude'] = (row['longitude'] as num).toDouble();
    if (row['live_until'] != null) map['live_until'] = row['live_until'].toString();
    if (row['attachment_url'] != null) map['attachment_url'] = row['attachment_url'].toString();
    return Message.fromJson(map, currentUserId);
  }

  /// Mark all unread messages (not sent by current user) as seen.
  /// Called when the recipient opens or is actively viewing the chat.
  static Future<void> markMessagesSeen(String chatId, String currentUserId) async {
    if (chatId.isEmpty || currentUserId.isEmpty) return;
    try {
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
      debugPrint('ChatServiceSupabase markMessagesSeen: $e');
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

  /// Send text message.
  static Future<Message> sendMessage({
    required String chatIdParam,
    required String senderId,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ChatServiceException('Message cannot be empty');
    try {
      final insert = {
        'chat_id': chatIdParam,
        'sender_id': senderId,
        'content': text,
        'type': 'text',
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendMessage: inserted chat_message id=${row['id']} chat_id=$chatIdParam sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': _truncate(text),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', chatIdParam);
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
      debugPrint('ChatServiceSupabase sendAttachmentMessage: inserted chat_message id=${row['id']} type=$type chat_id=$chatIdParam sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': content,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', chatIdParam);
      return _messageFromRow(row, chatIdParam, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendAttachmentMessage: $e');
      rethrow;
    }
  }

  /// Send current location (one-time).
  static Future<Message> sendLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
  }) async {
    try {
      final insert = {
        'chat_id': chatId,
        'sender_id': senderId,
        'content': 'Location',
        'type': 'location',
        'latitude': latitude,
        'longitude': longitude,
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendLocation: inserted chat_message id=${row['id']} chat_id=$chatId sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': 'Location',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', chatId);
      return _messageFromRow(row, chatId, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendLocation: $e');
      rethrow;
    }
  }

  /// Start live location sharing.
  static Future<Message> sendLiveLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    required int durationMinutes,
  }) async {
    final liveUntil = DateTime.now().add(Duration(minutes: durationMinutes));
    try {
      final insert = {
        'chat_id': chatId,
        'sender_id': senderId,
        'content': 'Live location',
        'type': 'live_location',
        'latitude': latitude,
        'longitude': longitude,
        'live_until': liveUntil.toIso8601String(),
      };
      final res = await _client.from('chat_messages').insert(insert).select().single();
      final row = res as Map<String, dynamic>;
      debugPrint('ChatServiceSupabase sendLiveLocation: inserted chat_message id=${row['id']} chat_id=$chatId sender_id=$senderId');
      await _client.from('chats').update({
        'last_message': 'Live location',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', chatId);
      return _messageFromRow(row, chatId, senderId);
    } catch (e) {
      debugPrint('ChatServiceSupabase sendLiveLocation: $e');
      rethrow;
    }
  }

  /// Update live location message (same row).
  static Future<void> updateMessageLocation({
    required String messageId,
    required double latitude,
    required double longitude,
  }) async {
    try {
      await _client.from('chat_messages').update({
        'latitude': latitude,
        'longitude': longitude,
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('ChatServiceSupabase updateMessageLocation: $e');
      rethrow;
    }
  }

  /// End live location (set live_until to now or clear).
  static Future<void> stopLiveLocation(String messageId) async {
    try {
      await _client.from('chat_messages').update({
        'live_until': DateTime.now().toIso8601String(),
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('ChatServiceSupabase stopLiveLocation: $e');
      rethrow;
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
}

class ChatServiceException implements Exception {
  final String message;
  ChatServiceException(this.message);
  @override
  String toString() => 'ChatServiceException: $message';
}