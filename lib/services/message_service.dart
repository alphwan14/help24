import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';
import '../utils/guest_id.dart';

/// Service for handling messaging operations with Supabase
class MessageService {
  static final _client = SupabaseConfig.client;

  /// Fetch all conversations for the current guest user
  /// Groups messages by conversation_id and returns latest message info
  static Future<List<Conversation>> getConversations() async {
    try {
      final guestId = GuestId.currentId;

      // Get all messages where user is sender or receiver
      final response = await _client
          .from('messages')
          .select()
          .or('sender_temp_id.eq.$guestId,receiver_temp_id.eq.$guestId')
          .order('created_at', ascending: false);

      if ((response as List).isEmpty) {
        return [];
      }

      // Group messages by conversation_id
      final Map<String, List<Map<String, dynamic>>> conversationMap = {};
      for (final msg in response) {
        final convId = msg['conversation_id'] as String;
        conversationMap.putIfAbsent(convId, () => []);
        conversationMap[convId]!.add(msg);
      }

      // Create Conversation objects
      final conversations = <Conversation>[];
      for (final entry in conversationMap.entries) {
        final messages = entry.value;
        if (messages.isEmpty) continue;

        // Get the latest message
        final latestMsg = messages.first;
        
        // Determine the other participant
        final senderId = latestMsg['sender_temp_id'] as String;
        final receiverId = latestMsg['receiver_temp_id'] as String;
        final otherParticipantId = senderId == guestId ? receiverId : senderId;

        // Count unread messages (messages from other user)
        final unreadCount = messages.where((m) => 
          m['sender_temp_id'] != guestId
        ).length;

        // Generate a display name from the participant ID
        final displayName = _getDisplayName(otherParticipantId);

        conversations.add(Conversation(
          id: entry.key,
          participantId: otherParticipantId,
          userName: displayName,
          lastMessage: latestMsg['content'] as String,
          lastMessageTime: DateTime.parse(latestMsg['created_at']),
          unreadCount: unreadCount,
        ));
      }

      // Sort by last message time
      conversations.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
      return conversations;
    } catch (e) {
      throw MessageServiceException('Failed to fetch conversations: $e');
    }
  }

  /// Get all messages for a specific conversation
  static Future<List<Message>> getMessages(String conversationId) async {
    try {
      final guestId = GuestId.currentId;

      final response = await _client
          .from('messages')
          .select()
          .eq('conversation_id', conversationId)
          .order('created_at', ascending: true);

      return (response as List)
          .map((json) => Message.fromJson(json, guestId))
          .toList();
    } catch (e) {
      throw MessageServiceException('Failed to fetch messages: $e');
    }
  }

  /// Send a new message
  static Future<Message> sendMessage({
    required String conversationId,
    required String receiverId,
    required String content,
  }) async {
    try {
      final guestId = GuestId.currentId;

      final messageData = {
        'conversation_id': conversationId,
        'sender_temp_id': guestId,
        'receiver_temp_id': receiverId,
        'content': content,
      };

      final response = await _client
          .from('messages')
          .insert(messageData)
          .select()
          .single();

      return Message.fromJson(response, guestId);
    } catch (e) {
      throw MessageServiceException('Failed to send message: $e');
    }
  }

  /// Start a new conversation with another user
  /// Creates a conversation ID and sends the first message
  static Future<Conversation> startConversation({
    required String otherUserId,
    required String otherUserName,
    required String initialMessage,
  }) async {
    try {
      final conversationId = GuestId.generateConversationId(otherUserId);
      
      final message = await sendMessage(
        conversationId: conversationId,
        receiverId: otherUserId,
        content: initialMessage,
      );

      return Conversation(
        id: conversationId,
        participantId: otherUserId,
        userName: otherUserName,
        lastMessage: initialMessage,
        lastMessageTime: message.timestamp,
        unreadCount: 0,
        messages: [message],
      );
    } catch (e) {
      throw MessageServiceException('Failed to start conversation: $e');
    }
  }

  /// Subscribe to real-time message updates for a conversation
  /// Returns a StreamSubscription that should be cancelled when done
  static RealtimeChannel subscribeToMessages(
    String conversationId,
    void Function(Message message) onMessage,
  ) {
    final guestId = GuestId.currentId;

    return _client
        .channel('messages:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) {
            final newMessage = Message.fromJson(payload.newRecord, guestId);
            onMessage(newMessage);
          },
        )
        .subscribe();
  }

  /// Unsubscribe from a real-time channel
  static Future<void> unsubscribe(RealtimeChannel channel) async {
    await _client.removeChannel(channel);
  }

  /// Subscribe to all new messages for the current user
  static RealtimeChannel subscribeToAllMessages(
    void Function(Message message) onMessage,
  ) {
    final guestId = GuestId.currentId;

    return _client
        .channel('user_messages:$guestId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_temp_id',
            value: guestId,
          ),
          callback: (payload) {
            final newMessage = Message.fromJson(payload.newRecord, guestId);
            onMessage(newMessage);
          },
        )
        .subscribe();
  }

  /// Generate a display name from a user ID
  static String _getDisplayName(String tempId) {
    // For now, generate a simple display name
    // In a real app, you might fetch this from a users table
    final shortId = tempId.substring(0, 8);
    return 'User $shortId';
  }

  /// Get or create a conversation with a post author
  static Future<Conversation> getOrCreateConversation({
    required String postAuthorId,
    required String postAuthorName,
    String? initialMessage,
  }) async {
    try {
      final conversationId = GuestId.generateConversationId(postAuthorId);
      
      // Check if conversation exists
      final existingMessages = await getMessages(conversationId);
      
      if (existingMessages.isEmpty && initialMessage != null) {
        // Create new conversation with initial message
        return startConversation(
          otherUserId: postAuthorId,
          otherUserName: postAuthorName,
          initialMessage: initialMessage,
        );
      }

      // Return existing conversation
      final lastMsg = existingMessages.isNotEmpty 
          ? existingMessages.last 
          : null;

      return Conversation(
        id: conversationId,
        participantId: postAuthorId,
        userName: postAuthorName,
        lastMessage: lastMsg?.text ?? '',
        lastMessageTime: lastMsg?.timestamp ?? DateTime.now(),
        unreadCount: 0,
        messages: existingMessages,
      );
    } catch (e) {
      throw MessageServiceException('Failed to get or create conversation: $e');
    }
  }
}

/// Exception for message service errors
class MessageServiceException implements Exception {
  final String message;
  MessageServiceException(this.message);
  
  @override
  String toString() => 'MessageServiceException: $message';
}
