import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/supabase_config.dart';
import '../models/post_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'user_profile_service.dart';

/// Firestore-only messaging. All data in Firestore.
/// Structure: chats/{chatId} with subcollection messages.
/// Chat doc: participants (array of user IDs), lastMessage, updatedAt; optional participantNames, participantAvatars.
/// Message doc: senderId, text, timestamp, status, type (in chats/{chatId}/messages/{messageId}).
class ChatServiceFirestore {
  static FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  static SupabaseClient get _supabase => SupabaseConfig.client;

  /// Deterministic chat id. With [contextId] (postId or jobId): "contextId_uid1_uid2" (one chat per post/job). Without: "uid1_uid2" (sorted).
  static String chatId(String user1Id, String user2Id, {String? jobId, String? postId}) {
    final ids = [user1Id, user2Id]..sort();
    final contextId = postId ?? jobId;
    if (contextId != null && contextId.isNotEmpty) {
      return '${contextId}_${ids[0]}_${ids[1]}';
    }
    return '${ids[0]}_${ids[1]}';
  }

  /// Parse participants from chatId ("uid1_uid2" or "jobId_uid1_uid2").
  static List<String> participantsFromChatId(String chatIdParam) {
    if (chatIdParam.isEmpty) return [];
    final parts = chatIdParam.split('_');
    if (parts.length >= 3) return [parts[1], parts[2]];
    if (parts.length >= 2) return [parts[0], parts[1]];
    return [];
  }

  /// Extract jobId from chatId if present ("jobId_uid1_uid2" → jobId).
  static String? jobIdFromChatId(String chatIdParam) {
    if (chatIdParam.isEmpty) return null;
    final parts = chatIdParam.split('_');
    if (parts.length >= 3) return parts[0];
    return null;
  }

  /// Stream of chats for current user. Reads from chats collection only; real-time via .snapshots().
  static Stream<List<Conversation>> watchConversations(String currentUserId) {
    if (currentUserId.isEmpty) return Stream.value([]);
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: currentUserId)
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map((snap) {
      final list = <Conversation>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final participants = List<String>.from(data['participants'] ?? data['participantIds'] ?? []);
        final otherId = participants.where((id) => id != currentUserId).firstOrNull ?? '';
        if (otherId.isEmpty) continue;
        final names = data['participantNames'] is Map ? Map<String, String>.from(data['participantNames'] as Map) : <String, String>{};
        final avatars = data['participantAvatars'] is Map ? Map<String, String>.from(data['participantAvatars'] as Map) : <String, String>{};
        final updatedAt = data['updatedAt'] is Timestamp
            ? (data['updatedAt'] as Timestamp).toDate()
            : DateTime.now();
        list.add(Conversation(
          id: doc.id,
          participantId: otherId,
          userName: names[otherId] ?? '?',
          userAvatar: avatars[otherId] ?? '',
          lastMessage: data['lastMessage']?.toString() ?? '',
          lastMessageTime: updatedAt,
          unreadCount: 0,
        ));
      }
      return list;
    });
  }

  /// Stream of messages for a chat. Real-time (.snapshots()); cache when offline. Order: old → new.
  static Stream<List<Message>> watchMessages(String chatIdParam, String currentUserId) {
    if (chatIdParam.isEmpty) return Stream.value([]);
    return _firestore
        .collection('chats')
        .doc(chatIdParam)
        .collection('messages')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => _messageFromFirestore(d, chatIdParam, currentUserId))
            .toList());
  }

  static Message _messageFromFirestore(DocumentSnapshot d, String conversationId, String currentUserId) {
    final data = d.data() as Map<String, dynamic>? ?? {};
    final senderId = data['senderId']?.toString() ?? '';
    final text = data['text']?.toString() ?? '';
    final Timestamp? tsStamp = data['createdAt'] is Timestamp
        ? data['createdAt'] as Timestamp
        : data['timestamp'] is Timestamp
            ? data['timestamp'] as Timestamp
            : null;
    final ts = tsStamp != null ? tsStamp.toDate() : DateTime.now();
    return Message(
      id: d.id,
      conversationId: conversationId,
      senderId: senderId,
      receiverId: '',
      text: text,
      timestamp: ts,
      isMe: senderId == currentUserId,
      type: data['type']?.toString() ?? 'text',
      latitude: data['latitude'] != null ? (data['latitude'] as num).toDouble() : null,
      longitude: data['longitude'] != null ? (data['longitude'] as num).toDouble() : null,
      liveUntil: data['liveUntil'] is Timestamp ? (data['liveUntil'] as Timestamp).toDate() : null,
    );
  }

  /// Create or get chat document. Chat doc has participants, lastMessage, updatedAt; optional postId/jobId.
  /// When [postId] or [jobId] is set, chatId is unique per post/job so each opens a different chat.
  static Future<Conversation> createChat({
    required String user1Id,
    required String user2Id,
    required String currentUserId,
    String initialMessage = '',
    String? postId,
    String? jobId,
  }) async {
    final cid = chatId(user1Id, user2Id, postId: postId, jobId: jobId);
    final otherId = user1Id == currentUserId ? user2Id : user1Id;
    final profile = await _getUserProfile(otherId);

    final ref = _firestore.collection('chats').doc(cid);
    final existing = await ref.get();

    final now = DateTime.now();
    final participants = [user1Id, user2Id];
    final names = <String, String>{user1Id: '?', user2Id: '?'};
    final avatars = <String, String>{user1Id: '', user2Id: ''};
    names[otherId] = profile.name;
    avatars[otherId] = profile.avatarUrl;
    if (existing.exists && existing.data() != null) {
      final d = existing.data()!;
      if (d['participantNames'] is Map) names.addAll(Map<String, String>.from(d['participantNames'] as Map));
      if (d['participantAvatars'] is Map) avatars.addAll(Map<String, String>.from(d['participantAvatars'] as Map));
    } else {
      await _fetchAndSetProfile(user1Id, names, avatars);
      await _fetchAndSetProfile(user2Id, names, avatars);
    }

    final lastMsg = initialMessage.isEmpty ? (existing.data()?['lastMessage']?.toString() ?? '') : initialMessage;
    final updatedAt = initialMessage.isNotEmpty ? now : (existing.data()?['updatedAt'] is Timestamp
        ? (existing.data()!['updatedAt'] as Timestamp).toDate()
        : now);

    final data = <String, dynamic>{
      'participants': participants,
      'participantNames': names,
      'participantAvatars': avatars,
      'lastMessage': lastMsg.length > 200 ? '${lastMsg.substring(0, 200)}…' : lastMsg,
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
    if (postId != null && postId.isNotEmpty) data['postId'] = postId;
    if (jobId != null && jobId.isNotEmpty) data['jobId'] = jobId;
    await ref.set(data, SetOptions(merge: true));

    return Conversation(
      id: cid,
      participantId: otherId,
      userName: profile.name,
      userAvatar: profile.avatarUrl,
      lastMessage: lastMsg.length > 200 ? '${lastMsg.substring(0, 200)}…' : lastMsg,
      lastMessageTime: updatedAt,
      unreadCount: 0,
    );
  }

  static Future<void> _fetchAndSetProfile(String uid, Map<String, String> names, Map<String, String> avatars) async {
    final p = await _getUserProfile(uid);
    names[uid] = p.name;
    avatars[uid] = p.avatarUrl;
  }

  /// Update chat preview (e.g. when applicant submits). Ensures chat doc exists with participants.
  static Future<void> updateChatPreview(String chatIdParam, String lastMessage) async {
    if (chatIdParam.isEmpty) return;
    final participants = participantsFromChatId(chatIdParam);
    final msg = lastMessage.length > 200 ? '${lastMessage.substring(0, 200)}…' : lastMessage;
    await _firestore.collection('chats').doc(chatIdParam).set({
      'participants': participants,
      'lastMessage': msg,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    }, SetOptions(merge: true));
  }

  /// Send a text message. Messages stored at chats/{chatId}/messages/{messageId}. Real-time stream reads same path.
  static Future<Message> sendMessage({
    required String chatIdParam,
    required String senderId,
    required String content,
  }) async {
    if (content.trim().isEmpty) throw ChatServiceException('Message cannot be empty');
    final text = content.trim();
    final now = DateTime.now();

    final participants = participantsFromChatId(chatIdParam);
    if (participants.isEmpty) {
      debugPrint('ChatServiceFirestore sendMessage: invalid chatId (no participants): $chatIdParam');
      throw ChatServiceException('Invalid chatId: $chatIdParam');
    }
    if (!participants.contains(senderId)) {
      debugPrint('ChatServiceFirestore sendMessage: sender $senderId not in participants $participants');
      throw ChatServiceException('You are not a participant in this chat');
    }

    final chatRef = _firestore.collection('chats').doc(chatIdParam);
    final messagesRef = chatRef.collection('messages');

    try {
      final docRef = await messagesRef.add({
        'senderId': senderId,
        'text': text,
        'createdAt': Timestamp.fromDate(now),
        'timestamp': Timestamp.fromDate(now),
        'status': 'sent',
        'type': 'text',
      });

      await chatRef.set({
        'participants': participants,
        'lastMessage': text.length > 200 ? '${text.substring(0, 200)}…' : text,
        'updatedAt': Timestamp.fromDate(now),
      }, SetOptions(merge: true));

      return Message(
        id: docRef.id,
        conversationId: chatIdParam,
        senderId: senderId,
        receiverId: '',
        text: text,
        timestamp: now,
        isMe: true,
        type: 'text',
      );
    } catch (e) {
      debugPrint('ChatServiceFirestore sendMessage: $e');
      rethrow;
    }
  }

  /// Get user profile (name, avatar) from Firestore users collection; falls back to Supabase if needed.
  static Future<({String name, String avatarUrl})> _getUserProfile(String userId) async {
    if (userId.isEmpty) return (name: '?', avatarUrl: '');
    try {
      final profile = await UserProfileService.getUser(userId);
      if (profile != null) {
        return (
          name: profile.displayName,
          avatarUrl: profile.profileImage,
        );
      }
    } catch (e) {
      debugPrint('ChatServiceFirestore _getUserProfile: $e');
    }
    try {
      final r = await _supabase
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
      debugPrint('ChatServiceFirestore _getUserProfile Supabase: $e');
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
