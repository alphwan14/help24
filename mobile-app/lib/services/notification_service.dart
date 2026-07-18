import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_firebase.dart';
import 'auth_service.dart';
import 'chat_local_prefs.dart';
import 'user_profile_service.dart';

// ── Channel constants ─────────────────────────────────────────────────────────
// Must match:
//   AndroidManifest.xml → com.google.firebase.messaging.default_notification_channel_id
//   MainActivity.kt     → NotificationChannel id
//   Backend             → android.notification.channelId
const String _kChannelId   = 'help24_high_importance';
const String _kChannelName = 'Help24 Notifications';
const String _kChannelDesc = 'Job updates, payments, and messages';

// ── Persistent chat notification cache ───────────────────────────────────────
// SharedPreferences-backed so the cache survives process kills and is readable
// by both the main isolate (foreground) and the background handler isolate.
// Key: 'help24_cn_<chatId>'  Value: JSON array of {sn, t, ts}
const String _kCachePrefix = 'help24_cn_';
const int    _kMaxCachedMessages = 7;

class _CachedMsg {
  final String senderName;
  final String text;
  final DateTime timestamp;
  _CachedMsg({required this.senderName, required this.text, required this.timestamp});
}

Future<List<_CachedMsg>> _loadCache(String chatId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // reload() forces a disk re-read, bypassing the in-memory cache.
    // Without this, the main isolate never sees writes made by the
    // background handler isolate (they write to the same XML file but
    // each isolate holds its own in-memory snapshot).
    await prefs.reload();
    final raw   = prefs.getString('$_kCachePrefix$chatId');
    if (raw == null) return [];
    final list  = jsonDecode(raw) as List;
    return list.map<_CachedMsg>((m) => _CachedMsg(
      senderName: (m['sn'] as String?) ?? '',
      text:       (m['t']  as String?) ?? '',
      timestamp:  DateTime.fromMillisecondsSinceEpoch((m['ts'] as int?) ?? 0),
    )).toList();
  } catch (_) {
    return [];
  }
}

Future<void> _saveCache(String chatId, List<_CachedMsg> msgs) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final json  = jsonEncode(msgs.map((m) => {
      'sn': m.senderName,
      't':  m.text,
      'ts': m.timestamp.millisecondsSinceEpoch,
    }).toList());
    await prefs.setString('$_kCachePrefix$chatId', json);
  } catch (_) {}
}

/// Parse the backend-supplied `thread` payload (JSON array of {s,t,ts}).
/// This is the AUTHORITATIVE thread source — the backend builds it from the DB
/// on every push, so MessagingStyle renders deterministically regardless of
/// whether the cross-isolate SharedPreferences cache persisted.
List<_CachedMsg> _parseThread(String raw) {
  try {
    final list = jsonDecode(raw) as List;
    return list.map<_CachedMsg>((m) => _CachedMsg(
      senderName: (m['s'] as String?) ?? 'Someone',
      text:       (m['t'] as String?) ?? '',
      timestamp:  DateTime.fromMillisecondsSinceEpoch((m['ts'] as int?) ?? 0),
    )).toList();
  } catch (_) {
    return [];
  }
}

// ── Module-level singletons ───────────────────────────────────────────────────
final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel _androidChannel = AndroidNotificationChannel(
  _kChannelId,
  _kChannelName,
  description: _kChannelDesc,
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

// ── Background handler ────────────────────────────────────────────────────────
// Called by FCM when the app is backgrounded/terminated AND the message is
// data-only (no `notification` field).  Chat messages are sent data-only from
// the backend so we can build MessagingStyle here instead of getting the plain
// replacement behaviour that FCM auto-display with `android.notification.tag`
// would produce.
//
// This runs in a SEPARATE Dart isolate — no access to main-isolate globals.
// SharedPreferences provides the cross-isolate persistent cache.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final type    = message.data['type']    as String? ?? '';
  final chatId  = message.data['chat_id'] as String?;
  final emitter = message.data['emitter'] as String?;
  final hasNotif = message.notification != null;

  // Full lifecycle trace — identifies the EXACT push shape and origin.
  debugPrint('[FCM][REMOTE_RECEIVED] bg id=${message.messageId} type=$type '
      'emitter=$emitter hasNotification=$hasNotif');
  debugPrint('[FCM][FULL_PAYLOAD] ${message.data}');
  debugPrint('[FCM][HAS_NOTIFICATION] ${message.notification != null} '
      'title=${message.notification?.title} body=${message.notification?.body}');
  debugPrint('[FCM][EMITTER_FINGERPRINT] emitter=$emitter '
      'version=${message.data['emitter_version']} service=${message.data['emitter_service']}');
  debugPrint('[FCM][BACKGROUND_HANDLER] id=${message.messageId} type=$type chatId=$chatId');

  // A legitimate chat push is data-only (hasNotification=false) and stamped
  // emitter='nestjs'. Anything else is a FOREIGN emitter (legacy edge function,
  // stale webhook, DB trigger) — log it loudly so the duplicate source is named.
  if (type == 'chat_message' && emitter != 'nestjs') {
    debugPrint('[FCM][FOREIGN_EMITTER] chat push without emitter=nestjs '
        '(emitter=$emitter hasNotification=$hasNotif) — THIS is the duplicate source. '
        'title=${message.notification?.title} body=${message.notification?.body}');
  }
  if (hasNotif) {
    // Data-only chat pushes never carry a notification block. If one does, the
    // OS may also auto-display it → duplicate. Name it.
    debugPrint('[FCM][AUTO_NOTIFICATION_RISK] push carries a notification block '
        'title=${message.notification?.title} — OS may auto-display a second card');
  }

  if (type != 'chat_message' || chatId == null) return;

  // Muted chats: honor the device-local mute even when the app is killed —
  // possible because chat pushes are data-only (we render, not the OS).
  if (await ChatLocalPrefs.isMuted(chatId)) {
    debugPrint('[CHAT_NOTIFY][MUTED] chatId=$chatId — notification suppressed');
    return;
  }

  // flutter_local_notifications requires bindings + channel setup in every isolate.
  WidgetsFlutterBinding.ensureInitialized();
  await _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_androidChannel);
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _localNotifications.initialize(
    const InitializationSettings(android: androidInit),
  );

  final senderName = message.data['sender_name']      as String? ?? 'Someone';
  final body       = message.data['message_preview']  as String? ?? '';
  final threadRaw  = message.data['thread']           as String?;

  // Prefer the backend-supplied thread (authoritative, DB-built). Fall back to
  // the local cross-isolate cache only when the payload omits it (older backend).
  List<_CachedMsg> cache;
  if (threadRaw != null && threadRaw.isNotEmpty) {
    cache = _parseThread(threadRaw);
    debugPrint('[CHAT_NOTIFY][THREAD_FROM_BACKEND] chatId=$chatId count=${cache.length}');
    // Mirror to local cache so foreground history stays consistent.
    await _saveCache(chatId, cache);
  } else {
    cache = await _loadCache(chatId);
    final isNewThread = cache.isEmpty;
    debugPrint('[CHAT_NOTIFY][${isNewThread ? 'THREAD_CREATED' : 'THREAD_FOUND'}] chatId=$chatId historyCount=${cache.length}');
    cache.add(_CachedMsg(senderName: senderName, text: body, timestamp: DateTime.now()));
    if (cache.length > _kMaxCachedMessages) cache.removeAt(0);
    await _saveCache(chatId, cache);
    debugPrint('[CHAT_NOTIFY][MESSAGE_APPENDED] chatId=$chatId totalCount=${cache.length}');
  }

  await _showMessagingStyleNotif(
    chatId: chatId,
    latestSender: senderName,
    latestBody:   body,
    cache:        cache,
    data:         Map<String, dynamic>.from(message.data),
  );
  debugPrint('[CHAT_NOTIFY][THREAD_REBUILT] chatId=$chatId totalMessages=${cache.length}');
}

// ── Shared notification builder ───────────────────────────────────────────────
// Used by both the foreground handler and the background handler so both paths
// produce identical MessagingStyle notifications.
Future<void> _showMessagingStyleNotif({
  required String chatId,
  required String latestSender,
  required String latestBody,
  required List<_CachedMsg> cache,
  required Map<String, dynamic> data,
}) async {
  final int    notifId  = chatId.hashCode.abs() & 0x7FFFFFFF;
  final String groupKey = 'chat_$chatId';

  debugPrint('[CHAT_NOTIFY][THREAD_REUSED] chatId=$chatId notifId=$notifId groupKey=$groupKey');
  debugPrint('[CHAT_NOTIFY][THREAD_HISTORY_COUNT] chatId=$chatId count=${cache.length}');
  debugPrint('[CHAT_NOTIFY][APPEND_MESSAGE] chatId=$chatId sender=$latestSender preview=$latestBody');
  // The ONLY place chat notifications are rendered. If you ever see TWO cards but
  // only ONE [FCM][LOCAL_RENDER] per message, the second card is an OS auto-display
  // from a foreign emitter (push with a notification block), not this code.
  debugPrint('[FCM][LOCAL_RENDER] chatId=$chatId notifId=$notifId sender=$latestSender messages=${cache.length}');

  try {
    final messages = cache.map((m) => Message(
      m.text,
      m.timestamp,
      Person(name: m.senderName, key: m.senderName),
    )).toList();

    await _localNotifications.show(
      notifId,
      latestSender,
      latestBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _kChannelId,
          _kChannelName,
          channelDescription: _kChannelDesc,
          importance:      Importance.max,
          priority:        Priority.high,
          playSound:       true,
          enableVibration: true,
          icon: '@mipmap/ic_launcher',
          groupKey:        groupKey,
          setAsGroupSummary: false,
          styleInformation: MessagingStyleInformation(
            const Person(name: 'You'),
            conversationTitle: latestSender,
            groupConversation: false,
            messages:          messages,
          ),
        ),
      ),
      payload: jsonEncode(data),
    );
  } catch (e) {
    // MessagingStyle is unavailable (old device / missing dependency).
    // Show a plain notification rather than silently dropping it.
    // We log this so it's easy to spot during QA.
    debugPrint('[CHAT_NOTIFY][FALLBACK_BLOCKED] MessagingStyle failed — falling back to plain: $e');
    try {
      await _localNotifications.show(
        notifId, latestSender, latestBody,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _kChannelId, _kChannelName,
            channelDescription: _kChannelDesc,
            importance: Importance.max,
            priority:   Priority.high,
            playSound:       true,
            enableVibration: true,
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (_) {}
  }
}

// ── NotificationService ───────────────────────────────────────────────────────

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static String? _currentToken;
  static GlobalKey<NavigatorState>? _navigatorKey;
  static bool _tokenRefreshListenerAttached = false;
  // Idempotency guards — prevent double listener attachment after hot restart
  // or an accidental second initialize()/setupMessageHandlers() call, which
  // would make onMessage fire (and render) twice per push.
  static bool _initialized = false;
  static bool _handlersAttached = false;

  static void Function(Map<String, dynamic> data)? _onLocalTapCallback;

  static String? get currentToken => _currentToken;

  static void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  static void setOnLocalNotificationTap(
      void Function(Map<String, dynamic> data) callback) {
    _onLocalTapCallback = callback;
  }

  // ── Initialisation ──────────────────────────────────────────────────────────

  static Future<void> initialize() async {
    if (!AppFirebase.isReady) {
      debugPrint('[FCM][INIT] Firebase not ready — skipping');
      return;
    }
    if (_initialized) {
      debugPrint('[FCM][INIT] already initialized — skipping (idempotency guard)');
      return;
    }
    _initialized = true;
    debugPrint('[FCM][INIT] starting');
    try {
      // Create notification channel (idempotent on Android).
      await _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_androidChannel);
      debugPrint('[FCM][CHANNEL] created id=$_kChannelId');

      // Initialise flutter_local_notifications.
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _localNotifications.initialize(
        const InitializationSettings(android: androidInit),
        onDidReceiveNotificationResponse: _onLocalNotificationTap,
      );

      // iOS: suppress OS banner in foreground; in-app overlay handles display.
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: true,
        sound: false,
      );

      // Background handler — must be registered early.
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      await _requestPermissionAndToken();
      _attachTokenRefreshListener();

      debugPrint('[FCM][INIT] complete');
    } catch (e, st) {
      debugPrint('[FCM][INIT][ERROR] $e');
      if (kDebugMode) debugPrint(st.toString());
    }
  }

  // ── Foreground message display ──────────────────────────────────────────────
  //
  // NOTE: there is intentionally NO foreground OS-notification path for chat.
  // Foreground → in-app banner only (main.dart). Background/terminated → the
  // background isolate (_firebaseMessagingBackgroundHandler) is the SOLE OS
  // renderer. The former _showLocalNotification / _showGroupedChatNotification
  // helpers were removed — they were unreferenced and contained a second
  // _localNotifications.show() path plus a "Someone" fallback that could emit a
  // duplicate card. Do not reintroduce a second render path here.

  static void _onLocalNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      debugPrint('[FCM][TAP] local notification tapped data=$data');
      _onLocalTapCallback?.call(data);
    } catch (e) {
      debugPrint('[FCM][TAP][ERROR] $e');
    }
  }

  // ── Message listeners ───────────────────────────────────────────────────────

  static void setupMessageHandlers({
    required void Function(RemoteMessage message) onForegroundMessage,
    required void Function(RemoteMessage message) onNotificationTap,
  }) {
    if (_handlersAttached) {
      debugPrint('[FCM][SETUP] handlers already attached — skipping (idempotency guard)');
      return;
    }
    _handlersAttached = true;
    try {
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final type     = message.data['type'] as String? ?? '';
        final emitter  = message.data['emitter'] as String?;
        final hasNotif = message.notification != null;

        // Full lifecycle trace. In FOREGROUND, EVERY push (even ones with a
        // notification block) is delivered here — so this is the definitive
        // place to count emitters. Send one message with the app open: if you
        // see TWO [FCM][FOREGROUND_HANDLER] logs, there are two emitters, and
        // the one with emitter≠nestjs / hasNotification=true is the duplicate.
        debugPrint('[FCM][REMOTE_RECEIVED] fg id=${message.messageId} type=$type '
            'emitter=$emitter hasNotification=$hasNotif data=${message.data}');
        debugPrint('[FCM][FOREGROUND_HANDLER] type=$type emitter=$emitter '
            'hasNotification=$hasNotif id=${message.messageId}');

        if (type == 'chat_message' && emitter != 'nestjs') {
          debugPrint('[FCM][FOREIGN_EMITTER] foreground chat push without emitter=nestjs '
              '(emitter=$emitter hasNotification=$hasNotif '
              'title=${message.notification?.title} body=${message.notification?.body}) '
              '— THIS is the duplicate source.');
        }

        // Foreground path: the in-app banner is the ONLY notification shown.
        // No _localNotifications.show() here — the OS tray notification is
        // exclusively the background isolate's job. (Showing one here was the
        // original double-notification bug.)
        debugPrint('[FCM][AUTO_NOTIFICATION_BLOCKED] type=$type foreground=true — OS notification suppressed; in-app banner only');
        onForegroundMessage(message);
      }, onError: (e) => debugPrint('[FCM][FG][ERROR] $e'));

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM][OPENED] data=${message.data}');
        onNotificationTap(message);
      }, onError: (e) => debugPrint('[FCM][OPENED][ERROR] $e'));

      FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
        if (message != null) {
          debugPrint('[FCM][INITIAL] data=${message.data}');
          onNotificationTap(message);
        }
      }).catchError((e) => debugPrint('[FCM][INITIAL][ERROR] $e'));
    } catch (e) {
      debugPrint('[FCM][SETUP][ERROR] $e');
    }
  }

  // ── Permission + Token ──────────────────────────────────────────────────────

  static Future<bool> _requestPermission() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true, badge: true, sound: true,
      );
      final status = settings.authorizationStatus;
      debugPrint('[FCM][PERMISSION] status=$status');
      return status == AuthorizationStatus.authorized ||
             status == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('[FCM][PERMISSION][ERROR] $e');
      return false;
    }
  }

  static Future<void> _requestPermissionAndToken() async {
    final granted = await _requestPermission();
    if (!granted) return;
    try {
      _currentToken = await _messaging.getToken();
      if (_currentToken == null) return;
      final uid = AuthService.currentUserId;
      if (uid != null) {
        final prefs = await UserProfileService.getNotificationPrefs(uid);
        if (prefs.notificationsEnabled) {
          await UserProfileService.addFcmToken(uid, _currentToken!);
          debugPrint('[FCM][TOKEN] saved for uid=$uid');
        }
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN][ERROR] $e');
    }
  }

  static void _attachTokenRefreshListener() {
    if (_tokenRefreshListenerAttached) return;
    _tokenRefreshListenerAttached = true;
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      _currentToken = token;
      final uid = AuthService.currentUserId;
      if (uid == null || uid.isEmpty) return;
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (!prefs.notificationsEnabled) return;
      await UserProfileService.addFcmToken(uid, token);
      debugPrint('[FCM][TOKEN_REFRESH] saved for uid=$uid');
    }, onError: (e) => debugPrint('[FCM][TOKEN_REFRESH][ERROR] $e'));
  }

  // ── Login / logout token lifecycle ─────────────────────────────────────────

  static Future<void> onLogin(String uid) async {
    if (!AppFirebase.isReady || uid.isEmpty) return;
    try {
      _currentToken = await _messaging.getToken();
      if (_currentToken == null) {
        await _requestPermissionAndToken();
        return;
      }
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (prefs.notificationsEnabled) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
        debugPrint('[FCM][LOGIN] token saved for uid=$uid');
      }
    } catch (e) {
      debugPrint('[FCM][LOGIN][ERROR] $e');
    }
  }

  static Future<void> enableAndSaveToken(String uid) async {
    if (!AppFirebase.isReady || uid.isEmpty) return;
    try {
      await UserProfileService.setNotificationsEnabled(uid, true);
      final granted = await _requestPermission();
      if (!granted) return;
      _currentToken = await _messaging.getToken();
      if (_currentToken != null) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
      }
    } catch (e) {
      debugPrint('[FCM][ENABLE][ERROR] $e');
    }
  }

  static Future<void> disableAndRemoveToken(String uid) async {
    if (uid.isEmpty) return;
    try {
      await UserProfileService.setNotificationsEnabled(uid, false);
      if (_currentToken != null) {
        await UserProfileService.removeFcmToken(uid, _currentToken!);
      }
    } catch (e) {
      debugPrint('[FCM][DISABLE][ERROR] $e');
    }
  }

  /// Sign-out hygiene: unregister THIS device's token so a signed-out phone
  /// stops receiving the account's pushes. Unlike [disableAndRemoveToken],
  /// the user's notifications PREFERENCE is left untouched — they get pushes
  /// again on their next login (which re-saves a token).
  static Future<void> removeTokenOnLogout(String uid) async {
    if (uid.isEmpty) return;
    try {
      if (_currentToken != null) {
        await UserProfileService.removeFcmToken(uid, _currentToken!);
        debugPrint('[FCM][LOGOUT] device token removed for uid=$uid');
      }
    } catch (e) {
      debugPrint('[FCM][LOGOUT][ERROR] $e');
    }
  }
}
