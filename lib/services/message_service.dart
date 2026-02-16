import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';

/// Real-time messaging with Supabase: conversations + messages tables.
/// Conversations are created only when a request/application is accepted.
class MessageService {
  static SupabaseClient get _client => SupabaseConfig.client;

  static const int pageSize = 50;

  /// Fetch conversations for current user (user1_id or user2_id = currentUserId).
  /// Returns list ordered by updated_at desc. Participant name from users table when available.
  static Future<List<Conversation>> getConversations(String currentUserId) async {
    if (currentUserId.isEmpty) return [];
    try {
      final response = await _client
          .from('conversations')
          .select()
          .or('user1_id.eq.$currentUserId,user2_id.eq.$currentUserId')
          .order('updated_at', ascending: false);

      final list = response as List;
      final conversations = <Conversation>[];
      for (final row in list) {
        final map = row as Map<String, dynamic>;
        final user1 = map['user1_id'] as String? ?? '';
        final user2 = map['user2_id'] as String? ?? '';
        final otherId = user1 == currentUserId ? user2 : user1;
        final name = await _getUserName(otherId);
        conversations.add(Conversation(
          id: (map['id'] ?? '').toString(),
          participantId: otherId,
          userName: name,
          userAvatar: '',
          lastMessage: map['last_message'] as String? ?? '',
          lastMessageTime: map['updated_at'] != null
              ? DateTime.parse(map['updated_at'].toString())
              : DateTime.now(),
          unreadCount: 0,
        ));
      }
      return conversations;
    } catch (e) {
      debugPrint('MessageService getConversations: $e');
      rethrow;
    }
  }

  /// Get messages for a conversation with pagination (oldest first).
  /// [before] = created_at cursor for loading older messages; null = latest page.
  static Future<List<Message>> getMessages(
    String conversationId,
    String currentUserId, {
    int limit = pageSize,
    DateTime? before,
  }) async {
    try {
      var query = _client
          .from('messages')
          .select()
          .eq('conversation_id', conversationId);

      if (before != null) {
        query = query.lt('created_at', before.toIso8601String());
      }
      final response = await query.order('created_at', ascending: true).limit(limit);

      return (response as List)
          .map((json) => Message.fromJson(json as Map<String, dynamic>, currentUserId))
          .toList();
    } catch (e) {
      debugPrint('MessageService getMessages: $e');
      rethrow;
    }
  }

  /// Load initial page (latest messages). Returns messages in ascending created_at order.
  static Future<List<Message>> getMessagesLatest(
    String conversationId,
    String currentUserId, {
    int limit = pageSize,
  }) async {
    try {
      final response = await _client
          .from('messages')
          .select()
          .eq('conversation_id', conversationId)
          .order('created_at', ascending: false)
          .limit(limit);

      final list = (response as List)
          .map((json) => Message.fromJson(json as Map<String, dynamic>, currentUserId))
          .toList();
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return list;
    } catch (e) {
      debugPrint('MessageService getMessagesLatest: $e');
      rethrow;
    }
  }

  /// Send a text message: insert with type 'text', update conversation.
  static Future<Message> sendMessage({
    required String conversationId,
    required String senderId,
    required String content,
  }) async {
    if (content.trim().isEmpty) {
      throw MessageServiceException('Message cannot be empty');
    }
    try {
      final insert = {
        'conversation_id': conversationId,
        'sender_id': senderId,
        'message': content.trim(),
        'type': 'text',
      };
      final response = await _client.from('messages').insert(insert).select().single();
      final message = Message.fromJson(response as Map<String, dynamic>, senderId);

      await _client.from('conversations').update({
        'last_message': content.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', conversationId);

      return message;
    } catch (e) {
      debugPrint('MessageService sendMessage: $e');
      throw MessageServiceException('Failed to send message: $e');
    }
  }

  /// Send a one-time location message (type 'location').
  static Future<Message> sendLocation({
    required String conversationId,
    required String senderId,
    required double latitude,
    required double longitude,
  }) async {
    try {
      final insert = {
        'conversation_id': conversationId,
        'sender_id': senderId,
        'message': 'Location',
        'type': 'location',
        'latitude': latitude,
        'longitude': longitude,
      };
      final response = await _client.from('messages').insert(insert).select().single();
      final message = Message.fromJson(response as Map<String, dynamic>, senderId);
      await _client.from('conversations').update({
        'last_message': 'Location',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', conversationId);
      return message;
    } catch (e) {
      debugPrint('MessageService sendLocation: $e');
      throw MessageServiceException('Failed to send location: $e');
    }
  }

  /// Start live location: insert message with type 'live_location' and live_until.
  static Future<Message> sendLiveLocation({
    required String conversationId,
    required String senderId,
    required double latitude,
    required double longitude,
    required int durationMinutes,
  }) async {
    try {
      final liveUntil = DateTime.now().add(Duration(minutes: durationMinutes));
      final insert = {
        'conversation_id': conversationId,
        'sender_id': senderId,
        'message': 'Live location',
        'type': 'live_location',
        'latitude': latitude,
        'longitude': longitude,
        'live_until': liveUntil.toIso8601String(),
      };
      final response = await _client.from('messages').insert(insert).select().single();
      final message = Message.fromJson(response as Map<String, dynamic>, senderId);
      await _client.from('conversations').update({
        'last_message': 'Live location',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', conversationId);
      return message;
    } catch (e) {
      debugPrint('MessageService sendLiveLocation: $e');
      throw MessageServiceException('Failed to start live location: $e');
    }
  }

  /// Update location for a message (used for live location updates).
  static Future<void> updateMessageLocation({
    required String messageId,
    required double latitude,
    required double longitude,
  }) async {
    try {
      await _client.from('messages').update({
        'latitude': latitude,
        'longitude': longitude,
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('MessageService updateMessageLocation: $e');
      rethrow;
    }
  }

  /// Stop live location: set live_until to now so it no longer updates; optionally set type to 'location'.
  static Future<void> stopLiveLocation(String messageId) async {
    try {
      await _client.from('messages').update({
        'live_until': DateTime.now().toIso8601String(),
        'type': 'location',
      }).eq('id', messageId);
    } catch (e) {
      debugPrint('MessageService stopLiveLocation: $e');
      rethrow;
    }
  }

  /// Create a conversation between two users (canonical order: user1_id < user2_id).
  /// [currentUserId] = who is creating/accepting; returned Conversation has participant = the other user.
  /// Returns existing conversation if one already exists for this pair.
  static Future<Conversation> createConversation({
    required String user1Id,
    required String user2Id,
    required String currentUserId,
  }) async {
    final u1 = user1Id.compareTo(user2Id) <= 0 ? user1Id : user2Id;
    final u2 = user1Id.compareTo(user2Id) <= 0 ? user2Id : user1Id;
    try {
      final existing = await _client
          .from('conversations')
          .select()
          .eq('user1_id', u1)
          .eq('user2_id', u2)
          .maybeSingle();

      final Map<String, dynamic> map;
      final String id;
      if (existing != null) {
        map = existing as Map<String, dynamic>;
        id = (map['id'] ?? '').toString();
      } else {
        final insert = {
          'user1_id': u1,
          'user2_id': u2,
          'last_message': '',
          'updated_at': DateTime.now().toIso8601String(),
        };
        final response = await _client.from('conversations').insert(insert).select().single();
        map = response as Map<String, dynamic>;
        id = (map['id'] ?? '').toString();
      }

      final otherId = u1 == currentUserId ? u2 : u1;
      final name = await _getUserName(otherId);
      return Conversation(
        id: id,
        participantId: otherId,
        userName: name,
        userAvatar: '',
        lastMessage: map['last_message'] as String? ?? '',
        lastMessageTime: map['updated_at'] != null
            ? DateTime.parse(map['updated_at'].toString())
            : DateTime.now(),
        unreadCount: 0,
      );
    } catch (e) {
      debugPrint('MessageService createConversation: $e');
      throw MessageServiceException('Failed to create conversation: $e');
    }
  }

  /// Subscribe to new and updated messages for a single conversation (Realtime INSERT + UPDATE).
  /// [onMessage] for new messages; [onMessageUpdated] for live location updates (same message id, new lat/lng).
  static RealtimeChannel subscribeToMessages(
    String conversationId,
    String currentUserId, {
    required void Function(Message message) onMessage,
    void Function(Message message)? onMessageUpdated,
  }) {
    if (conversationId.isEmpty) {
      debugPrint('MessageService: skipped subscription — empty conversationId');
      return _client.channel('noop:empty').subscribe();
    }
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    var channel = _client
        .channel('messages:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: filter,
          callback: (payload) {
            try {
              final newRecord = payload.newRecord;
              if (newRecord != null && newRecord.isNotEmpty) {
                final msg = Message.fromJson(
                  Map<String, dynamic>.from(newRecord),
                  currentUserId,
                );
                onMessage(msg);
              }
            } catch (e) {
              debugPrint('Realtime message parse error: $e');
            }
          },
        );
    if (onMessageUpdated != null) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'messages',
        filter: filter,
        callback: (payload) {
          try {
            final newRecord = payload.newRecord;
            if (newRecord != null && newRecord.isNotEmpty) {
              final msg = Message.fromJson(
                Map<String, dynamic>.from(newRecord),
                currentUserId,
              );
              onMessageUpdated(msg);
            }
          } catch (e) {
            debugPrint('Realtime message update parse error: $e');
          }
        },
      );
    }
    return channel.subscribe();
  }

  static Future<void> unsubscribe(RealtimeChannel channel) async {
    await _client.removeChannel(channel);
  }

  static Future<String> _getUserName(String userId) async {
    if (userId.isEmpty) return 'User';
    try {
      final r = await _client.from('users').select('name').eq('id', userId).maybeSingle();
      if (r != null && r['name'] != null) return r['name'] as String;
    } catch (_) {}
    return 'User ${userId.length > 8 ? userId.substring(0, 8) : userId}';
  }
}

class MessageServiceException implements Exception {
  final String message;
  MessageServiceException(this.message);
  @override
  String toString() => 'MessageServiceException: $message';
}
