import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';

/// Supabase-only messaging: chats + chat_messages (fetch + polling, no Realtime).
/// Use this for "Contact Provider" and Messages tab.
class ChatServiceSupabase {
  static SupabaseClient get _client => SupabaseConfig.client;

  /// Get or create a chat by (user1, user2, post_id). postId and jobId map to post_id (uuid or null).
  static Future<Conversation> createChat({
    required String user1Id,
    required String user2Id,
    required String currentUserId,
    String initialMessage = '',
    String? postId,
    String? jobId,
  }) async {
    final u1 = user1Id.compareTo(user2Id) <= 0 ? user1Id : user2Id;
    final u2 = user1Id.compareTo(user2Id) <= 0 ? user2Id : user1Id;
    final postIdUuid = _parseUuid(postId ?? jobId);

    try {
      // Find existing chat
      var query = _client
          .from('chats')
          .select()
          .eq('user1', u1)
          .eq('user2', u2);
      if (postIdUuid != null) {
        query = query.eq('post_id', postIdUuid);
      } else {
        query = query.isFilter('post_id', null);
      }
      final existing = await query.maybeSingle();

      final Map<String, dynamic> row;
      final String chatId;
      if (existing != null) {
        row = existing as Map<String, dynamic>;
        chatId = (row['id'] ?? '').toString();
      } else {
        final insert = <String, dynamic>{
          'user1': u1,
          'user2': u2,
          'last_message': initialMessage.isEmpty ? '' : _truncate(initialMessage),
          'updated_at': DateTime.now().toIso8601String(),
        };
        if (postIdUuid != null) insert['post_id'] = postIdUuid;
        final res = await _client.from('chats').insert(insert).select().single();
        row = res as Map<String, dynamic>;
        chatId = (row['id'] ?? '').toString();
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
    final response = await _client
        .from('chats')
        .select()
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
    };
    if (row['latitude'] != null) map['latitude'] = (row['latitude'] as num).toDouble();
    if (row['longitude'] != null) map['longitude'] = (row['longitude'] as num).toDouble();
    if (row['live_until'] != null) map['live_until'] = row['live_until'].toString();
    if (row['attachment_url'] != null) map['attachment_url'] = row['attachment_url'].toString();
    return Message.fromJson(map, currentUserId);
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
