import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/supabase_config.dart';
import '../models/chat_person.dart';
import '../models/post_model.dart';
import 'chat_service_supabase.dart';
import 'chat_store.dart';
import 'delivery_receipts.dart';

/// A CHAT PUSH THAT ARRIVES WHILE THE APP IS CLOSED GOES INTO THE DATABASE.
///
/// The push itself carries only a preview. If nothing else happened, the next
/// offline open would show the notification's words in the tray and an older
/// thread in the app. So the FCM background isolate — which has the network
/// right now, because the push just came through it — reads the chat row and
/// its latest messages and writes them into the account's chat database. The
/// app, opened later on a plane, shows the message that woke the phone.
///
/// Runs with no Supabase client (a [DeliveryReceipts.backgroundSession]
/// token over plain HTTP), every request bounded, and never throws: the
/// notification must show whether or not this works.
class ChatPushIngest {
  ChatPushIngest._();

  static const Duration _timeout = Duration(seconds: 8);

  static Future<void> ingest(
    String chatId, {
    required Future<BackgroundSession?> session,
    @visibleForTesting http.Client? client,
  }) async {
    if (chatId.isEmpty) return;
    final http.Client c = client ?? http.Client();
    try {
      final s = await session;
      if (s == null) return;
      final headers = DeliveryReceipts.headersFor(s.jwt);
      const base = SupabaseConfig.supabaseUrl;

      final responses = await Future.wait([
        c.get(chatUri(base, chatId), headers: headers).timeout(_timeout),
        c.get(messagesUri(base, chatId), headers: headers).timeout(_timeout),
      ]);
      if (responses.any((r) => r.statusCode != 200)) {
        debugPrint('[CHAT_PUSH] read refused ${responses.map((r) => r.statusCode).join('/')}');
        return;
      }
      final chats = jsonDecode(responses[0].body) as List;
      if (chats.isEmpty) return;
      final row = ChatServiceSupabase.rowSnapshotOf(
          Map<String, dynamic>.from(chats.first as Map), s.uid);
      final messages = <Message>[
        for (final m in jsonDecode(responses[1].body) as List)
          ChatServiceSupabase.messageFromRow(Map<String, dynamic>.from(m as Map), chatId, s.uid),
      ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // The sender's name, only if this phone has never had it.
      final people = <String, ChatPerson>{};
      final store = ChatStore.instance;
      if ((await store.unnamedPeople(s.uid, [row.participantId])).isNotEmpty) {
        try {
          final r = await c.get(personUri(base, row.participantId), headers: headers).timeout(_timeout);
          if (r.statusCode == 200) {
            for (final u in jsonDecode(r.body) as List) {
              final person = ChatServiceSupabase.personFromUserRow(Map<String, dynamic>.from(u as Map));
              if (person.id.isNotEmpty) people[person.id] = person;
            }
          }
        } catch (_) {
          // The name stays as it was; the next sync fills it in.
        }
      }

      // No cursor: this is ONE conversation, and moving the list cursor to its
      // time would make the next sync skip others that changed meanwhile.
      await store.applyConversationSync(s.uid, rows: [row], people: people);
      await store.upsertMessages(s.uid, chatId, messages);
      await store.setThreadSynced(s.uid, chatId, row.updatedAt.millisecondsSinceEpoch);
      debugPrint('[CHAT_PUSH][STORED] chat=${shortId(chatId)} messages=${messages.length}');
    } catch (e) {
      debugPrint('[CHAT_PUSH] not stored: $e');
    } finally {
      if (client == null) c.close();
    }
  }

  @visibleForTesting
  static Uri chatUri(String base, String chatId) => Uri.parse('$base/rest/v1/chats').replace(
        queryParameters: {'select': _compact(ChatServiceSupabase.chatRowSelect), 'id': 'eq.$chatId'},
      );

  @visibleForTesting
  static Uri messagesUri(String base, String chatId) =>
      Uri.parse('$base/rest/v1/chat_messages').replace(queryParameters: {
        'select': '*',
        'chat_id': 'eq.$chatId',
        'order': 'created_at.desc',
        'limit': '50',
      });

  @visibleForTesting
  static Uri personUri(String base, String userId) => Uri.parse('$base/rest/v1/users').replace(
        queryParameters: {'select': _compact(ChatServiceSupabase.personSelect), 'id': 'eq.$userId'},
      );

  /// The client library strips whitespace from a select before sending it;
  /// over plain HTTP that is ours to do.
  static String _compact(String select) => select.replaceAll(RegExp(r'\s+'), '');
}
