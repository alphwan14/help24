import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../firebase_options.dart';
import 'supabase_auth_bridge.dart';

/// DELIVERED RECEIPTS — the second tick.
///
/// A message is DELIVERED when it has reached the recipient's phone. Only that
/// phone can know, so it is the RECIPIENT'S app that says so, by stamping
/// `chat_messages.delivered_at` on every message it has received — the same
/// way it already marks messages read (`status = 'seen'`), under the same
/// participant RLS policy, and seen by the sender through the same realtime
/// UPDATE feed.
///
/// It acknowledges at the three moments a message can land on this device:
///   * the conversation list loads and a chat has unread messages,
///   * a chat push arrives while the app is open, and
///   * a chat push arrives while the app is closed — in the FCM background
///     isolate, which has no Supabase session, so [acknowledgeFromPush] makes
///     its own: Firebase ID token → `exchange-firebase-token` → one PATCH.
///
/// Read outranks delivered (`chatSendStateOf`), so a late acknowledgement can
/// never turn a read message grey again; and the server guard in migration 120
/// keeps the first time and ignores the sender stamping their own message.
///
/// BEFORE MIGRATION 120 IS APPLIED the column does not exist and every
/// acknowledgement is refused (42703 / PGRST204). That is remembered on disk
/// for [recheckAfter], so neither isolate keeps asking, and sent messages stay
/// at one tick — the honest state.
class DeliveryReceipts {
  DeliveryReceipts._();

  static const String column = 'delivered_at';
  static const Duration recheckAfter = Duration(hours: 6);
  static const String _unavailableKey = 'chat.delivered_receipts.unavailable_at';

  /// chatId → the newest message time already acknowledged, so a list that
  /// refreshes every 15–60 s does not re-send the same acknowledgement.
  static final Map<String, DateTime> _ackedThrough = {};

  /// Test seam: the network write of the main-isolate path.
  @visibleForTesting
  static Future<void> Function(String uid, List<String> chatIds, DateTime at)? writeOverride;

  // ── Main isolate ───────────────────────────────────────────────────────────

  /// Acknowledge everything [uid] has received in [chatIds].
  ///
  /// [newest] (chatId → newest message time) lets a caller that only knows
  /// "this chat changed" skip chats it acknowledged already. Never throws.
  static Future<void> acknowledge({
    required String uid,
    required Iterable<String> chatIds,
    Map<String, DateTime>? newest,
  }) async {
    if (uid.isEmpty) return;
    final due = <String>[];
    for (final id in chatIds) {
      if (id.isEmpty) continue;
      final latest = newest?[id];
      final done = _ackedThrough[id];
      if (latest != null && done != null && !latest.isAfter(done)) continue;
      due.add(id);
    }
    if (due.isEmpty) return;
    if (!await _enabled()) return;
    final now = DateTime.now().toUtc();
    try {
      final write = writeOverride;
      if (write != null) {
        await write(uid, due, now);
      } else {
        await SupabaseAuthBridge.ensureSessionAsync();
        await Supabase.instance.client
            .from('chat_messages')
            .update({column: now.toIso8601String()})
            .inFilter('chat_id', due)
            .neq('sender_id', uid)
            .isFilter(column, null);
      }
      for (final id in due) {
        _ackedThrough[id] = newest?[id] ?? now;
      }
      debugPrint('[RECEIPTS] delivered ack chats=${due.length}');
    } on PostgrestException catch (e) {
      if (isMissingColumn(code: e.code, message: e.message)) {
        await _markUnavailable();
      } else {
        debugPrint('[RECEIPTS] delivered ack failed: ${e.code} ${e.message}');
      }
    } catch (e) {
      debugPrint('[RECEIPTS] delivered ack failed: $e');
    }
  }

  // ── Background isolate (app closed) ──────────────────────────────────────

  /// Acknowledge a chat whose push just arrived while the app was not running.
  ///
  /// Runs in the FCM background isolate: no Supabase client, no bridge token.
  /// Three requests, each bounded, and never throws — a notification must
  /// show whether or not this succeeds.
  static Future<void> acknowledgeFromPush(
    String chatId, {
    @visibleForTesting http.Client? client,
    @visibleForTesting Future<({String uid, String idToken})?> Function()? identity,
    /// A session the caller already started ([backgroundSession]) — so the
    /// push that both acknowledges and stores its message pays for ONE token
    /// exchange, not two.
    Future<BackgroundSession?>? session,
  }) async {
    if (chatId.isEmpty) return;
    final http.Client c = client ?? http.Client();
    try {
      if (!await _enabled()) return;
      final s = await (session ?? backgroundSession(client: c, identity: identity));
      if (s == null) return;

      final response = await c
          .patch(ackUri(chatId: chatId, uid: s.uid),
              headers: {..._headers(s.jwt), 'Prefer': 'return=minimal'},
              body: jsonEncode({column: DateTime.now().toUtc().toIso8601String()}))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('[RECEIPTS][BG] delivered ack chat=$chatId');
        return;
      }
      String? code;
      String message = response.body;
      try {
        final body = jsonDecode(response.body);
        if (body is Map) {
          code = body['code']?.toString();
          message = body['message']?.toString() ?? message;
        }
      } catch (_) {}
      if (isMissingColumn(code: code, message: message)) {
        await _markUnavailable();
      } else {
        debugPrint('[RECEIPTS][BG] delivered ack refused ${response.statusCode} $code');
      }
    } catch (e) {
      debugPrint('[RECEIPTS][BG] delivered ack failed: $e');
    } finally {
      if (client == null) c.close();
    }
  }

  /// A Supabase session for the FCM background isolate, which has no client
  /// and no bridge token: Firebase ID token → `exchange-firebase-token`.
  /// Bounded and never throws; null when there is no signed-in user or the
  /// exchange is refused.
  static Future<BackgroundSession?> backgroundSession({
    http.Client? client,
    Future<({String uid, String idToken})?> Function()? identity,
  }) async {
    final http.Client c = client ?? http.Client();
    try {
      final who = await (identity ?? _firebaseIdentity)();
      if (who == null) return null;
      final exchange = await c
          .post(
            Uri.parse('${SupabaseConfig.supabaseUrl}/functions/v1/exchange-firebase-token'),
            headers: _headers(SupabaseConfig.supabaseAnonKey),
            body: jsonEncode({'id_token': who.idToken}),
          )
          .timeout(const Duration(seconds: 8));
      if (exchange.statusCode != 200) {
        debugPrint('[RECEIPTS][BG] exchange refused ${exchange.statusCode}');
        return null;
      }
      final jwt = (jsonDecode(exchange.body) as Map)['access_token'] as String?;
      if (jwt == null || jwt.isEmpty) return null;
      return (uid: who.uid, jwt: jwt);
    } catch (e) {
      debugPrint('[RECEIPTS][BG] no session: $e');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Headers for a PostgREST call made with a [backgroundSession] token.
  static Map<String, String> headersFor(String jwt) => _headers(jwt);

  /// The PATCH that marks [uid]'s received, unacknowledged messages in
  /// [chatId] as delivered. Exposed so the filter can be checked: it must
  /// never touch the recipient's OWN messages, nor overwrite a stamp.
  @visibleForTesting
  static Uri ackUri({required String chatId, required String uid}) => Uri.parse(
        '${SupabaseConfig.supabaseUrl}/rest/v1/chat_messages'
        '?chat_id=eq.${Uri.encodeQueryComponent(chatId)}'
        '&sender_id=neq.${Uri.encodeQueryComponent(uid)}'
        '&$column=is.null',
      );

  static Map<String, String> _headers(String bearer) => {
        'apikey': SupabaseConfig.supabaseAnonKey,
        'Authorization': 'Bearer $bearer',
        'Content-Type': 'application/json',
      };

  static Future<({String uid, String idToken})?> _firebaseIdentity() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
            .timeout(const Duration(seconds: 8));
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;
      final token = await user.getIdToken().timeout(const Duration(seconds: 8));
      if (token == null || token.isEmpty) return null;
      return (uid: user.uid, idToken: token);
    } catch (e) {
      debugPrint('[RECEIPTS][BG] no identity: $e');
      return null;
    }
  }

  // ── Server support ─────────────────────────────────────────────────────────

  /// The server has no `delivered_at` yet: PostgREST names an unknown body
  /// column PGRST204, Postgres an unknown filter column 42703.
  @visibleForTesting
  static bool isMissingColumn({String? code, String? message}) {
    if (code == '42703' || code == 'PGRST204') return true;
    final m = (message ?? '').toLowerCase();
    return m.contains(column) && (m.contains('does not exist') || m.contains('could not find'));
  }

  static Future<bool> _enabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // the other isolate may have written it
      final at = prefs.getInt(_unavailableKey);
      if (at == null) return true;
      final since = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
      if (since < recheckAfter) return false;
      await prefs.remove(_unavailableKey);
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> _markUnavailable() async {
    debugPrint('[RECEIPTS] server has no $column yet (migration 120) — '
        'pausing delivered receipts for ${recheckAfter.inHours}h');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_unavailableKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _ackedThrough.clear();
    writeOverride = null;
  }
}

/// A signed-in user and their Supabase token, minted in the FCM background
/// isolate ([DeliveryReceipts.backgroundSession]).
typedef BackgroundSession = ({String uid, String jwt});
