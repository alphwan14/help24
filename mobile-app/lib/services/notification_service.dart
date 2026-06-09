import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config/app_firebase.dart';
import 'auth_service.dart';
import 'user_profile_service.dart';

// ── Channel constants ─────────────────────────────────────────────────────────
// Must match:
//   AndroidManifest.xml → com.google.firebase.messaging.default_notification_channel_id
//   MainActivity.kt     → NotificationChannel id
//   Backend             → android.notification.channelId
const String _kChannelId   = 'help24_high_importance';
const String _kChannelName = 'Help24 Notifications';
const String _kChannelDesc = 'Job updates, payments, and messages';

// ── Chat message cache for MessagingStyle grouping ───────────────────────────
// Maps chatId → last N messages for grouped Android notification display.
// Lives for the app session; cleared when the app is killed (acceptable).
final Map<String, List<_ChatCachedMessage>> _chatMessageCache = {};

class _ChatCachedMessage {
  final String senderName;
  final String text;
  final DateTime timestamp;
  _ChatCachedMessage({required this.senderName, required this.text, required this.timestamp});
}

// ── Module-level singletons ───────────────────────────────────────────────────
// flutter_local_notifications requires a single plugin instance for the
// entire app lifetime. Creating it here (not inside a class) avoids accidental
// double-initialisation.
final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

// AndroidNotificationChannel must be const so it can be used in show() details
// and in createNotificationChannel() — both places require the same id.
const AndroidNotificationChannel _androidChannel = AndroidNotificationChannel(
  _kChannelId,
  _kChannelName,
  description: _kChannelDesc,
  importance: Importance.max,  // maps to NotificationManager.IMPORTANCE_HIGH on Android 8+
  playSound: true,
  enableVibration: true,
);

// ── Background handler ────────────────────────────────────────────────────────
// Must be a top-level function annotated @pragma('vm:entry-point').
// FCM handles display automatically in background/terminated state using the
// channel declared in AndroidManifest. This handler only does logging.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM][BACKGROUND] id=${message.messageId} type=${message.data['type']}');
}

// ── NotificationService ───────────────────────────────────────────────────────

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static String? _currentToken;
  static GlobalKey<NavigatorState>? _navigatorKey;
  static bool _tokenRefreshListenerAttached = false;

  // Callback registered from main.dart to handle taps on local notifications
  // (produced by _showLocalNotification while app is in foreground).
  static void Function(Map<String, dynamic> data)? _onLocalTapCallback;

  static String? get currentToken => _currentToken;

  static void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  /// Register a callback that receives the FCM data payload when the user taps
  /// a local notification shown while the app is in the foreground.
  /// Call from main.dart before runApp.
  static void setOnLocalNotificationTap(
      void Function(Map<String, dynamic> data) callback) {
    _onLocalTapCallback = callback;
  }

  // ── Initialisation ──────────────────────────────────────────────────────────

  /// One-time startup. Call after Firebase is ready and before any FCM work.
  /// Order matters:
  ///   1. createNotificationChannel  — registers channel with OS (idempotent)
  ///   2. flutter_local_notifications.initialize — must be before first show()
  ///   3. setForegroundNotificationPresentationOptions — iOS only
  ///   4. FirebaseMessaging.onBackgroundMessage — registers isolate entry point
  ///   5. requestPermission + getToken
  static Future<void> initialize() async {
    if (!AppFirebase.isReady) {
      debugPrint('[FCM][INIT] Firebase not ready — skipping FCM initialization');
      return;
    }
    debugPrint('[FCM][INIT] starting FCM initialization');
    try {
      // Step 1: create the Android notification channel.
      // This is idempotent — Android silently ignores duplicate channel creation.
      // Must happen BEFORE any notification is posted so the channel exists.
      await _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_androidChannel);
      debugPrint('[FCM][CHANNEL_CREATED] id=$_kChannelId importance=max playSound=true');

      // Step 2: initialise flutter_local_notifications.
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _localNotifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onLocalNotificationTap,
      );
      debugPrint('[FCM][SOUND_ENABLED] flutter_local_notifications initialized');

      // Step 3: iOS foreground presentation (no-op on Android).
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // Step 4: background handler — must be registered before messages arrive.
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Step 5: permission + token.
      await _requestPermissionAndToken();
      _attachTokenRefreshListener();

      debugPrint('[FCM][INIT] FCM initialization complete');
    } catch (e, st) {
      debugPrint('[FCM][INIT][ERROR] $e');
      if (kDebugMode) debugPrint(st.toString());
    }
  }

  // ── Foreground message presentation ────────────────────────────────────────

  /// Show an OS-level local notification for a message that arrived while the
  /// app is in the foreground. FCM does NOT auto-display on Android when the
  /// app is open — this is the required replacement.
  static Future<void> _showLocalNotification(RemoteMessage message) async {
    final type = message.data['type'] as String? ?? '';

    // Chat messages use MessagingStyle — same notification ID per conversation
    // so messages stack instead of spawning separate cards.
    if (type == 'chat_message') {
      await _showGroupedChatNotification(message);
      return;
    }

    final notification = message.notification;
    if (notification == null) {
      debugPrint('[FCM][LOCAL_NOTIFICATION] no notification payload — nothing to show');
      return;
    }

    final id = ((message.messageId ?? (type.isNotEmpty ? type : 'fcm')).hashCode).abs() & 0x7FFFFFFF;
    final title = notification.title ?? 'Help24';
    final body  = notification.body  ?? '';

    debugPrint('[FCM][LOCAL_NOTIFICATION] id=$id type=$type title="$title"');

    try {
      await _localNotifications.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _kChannelId,
            _kChannelName,
            channelDescription: _kChannelDesc,
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: jsonEncode(message.data),
      );
      debugPrint('[FCM][FOREGROUND_SHOWN] local notification displayed id=$id');
    } catch (e) {
      debugPrint('[FCM][LOCAL_NOTIFICATION][ERROR] $e');
    }
  }

  /// Show a grouped conversation notification using Android MessagingStyle.
  /// All messages from the same chat accumulate under the same notification ID
  /// (chatId.hashCode) so the user sees one card per conversation, not one per message.
  static Future<void> _showGroupedChatNotification(RemoteMessage message) async {
    final chatId     = message.data['chat_id'] as String?;
    final senderName = message.notification?.title ?? 'Someone';
    final body       = message.notification?.body ?? '';

    if (chatId == null) {
      // No chatId — fall back to plain notification.
      await _showLocalNotification(message);
      return;
    }

    debugPrint('[CHAT_NOTIFY][GROUPED] chatId=$chatId sender=$senderName');

    // Accumulate messages in cache (keep last 5 for MessagingStyle display).
    final cache = _chatMessageCache[chatId] ?? [];
    cache.add(_ChatCachedMessage(
      senderName: senderName,
      text: body,
      timestamp: DateTime.now(),
    ));
    if (cache.length > 5) cache.removeAt(0);
    _chatMessageCache[chatId] = cache;

    final int notifId = chatId.hashCode.abs() & 0x7FFFFFFF;
    debugPrint('[CHAT_NOTIFY][UPDATE_EXISTING] id=$notifId messages=${cache.length}');

    try {
      final messages = cache
          .map((m) => Message(m.text, m.timestamp, Person(name: m.senderName)))
          .toList();

      await _localNotifications.show(
        notifId,
        senderName,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _kChannelId,
            _kChannelName,
            channelDescription: _kChannelDesc,
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            icon: '@mipmap/ic_launcher',
            styleInformation: MessagingStyleInformation(
              const Person(name: 'You'),
              messages: messages,
              groupConversation: false,
            ),
          ),
        ),
        payload: jsonEncode(message.data),
      );
      debugPrint('[CHAT_NOTIFY][OPEN_CHAT] notification shown id=$notifId chatId=$chatId');
    } catch (e) {
      debugPrint('[CHAT_NOTIFY][ERROR] MessagingStyle failed, falling back: $e');
      // Fallback: plain notification so the user still gets something.
      final notification = message.notification;
      if (notification != null) {
        await _localNotifications.show(
          notifId,
          notification.title ?? 'Help24',
          notification.body ?? '',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _kChannelId, _kChannelName,
              channelDescription: _kChannelDesc,
              importance: Importance.max,
              priority: Priority.high,
              playSound: true,
              enableVibration: true,
            ),
          ),
          payload: jsonEncode(message.data),
        );
      }
    }
  }

  /// Called when the user taps a local notification produced by _showLocalNotification.
  static void _onLocalNotificationTap(NotificationResponse response) {
    debugPrint('[FCM][TAP] local notification tapped payload=${response.payload}');
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      debugPrint('[FCM][TAP] decoded data=$data');
      _onLocalTapCallback?.call(data);
    } catch (e) {
      debugPrint('[FCM][TAP][ERROR] decode failed: $e');
    }
  }

  // ── Message listeners ───────────────────────────────────────────────────────

  /// Wire up all FCM message listeners. Call once from main.dart (in initState
  /// or during bootstrap), before the app is fully built so no messages are missed.
  static void setupMessageHandlers({
    required void Function(RemoteMessage message) onForegroundMessage,
    required void Function(RemoteMessage message) onNotificationTap,
  }) {
    try {
      // Foreground: FCM delivers but does NOT display on Android.
      // We show a local notification first, then call the app's in-app banner.
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('[FCM][ON_MESSAGE] foreground message type=${message.data['type'] ?? 'unknown'} id=${message.messageId}');
        _showLocalNotification(message);  // OS notification with sound
        onForegroundMessage(message);     // in-app banner (supplementary)
      }, onError: (e) {
        debugPrint('[FCM][ON_MESSAGE][ERROR] $e');
      });

      // Tapped while app was in background (not terminated).
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[FCM][OPENED_APP] notification tapped from background data=${message.data}');
        onNotificationTap(message);
      }, onError: (e) {
        debugPrint('[FCM][OPENED_APP][ERROR] $e');
      });

      // Tapped when app was fully terminated.
      FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
        if (message != null) {
          debugPrint('[FCM][INITIAL_MESSAGE] app opened from terminated state data=${message.data}');
          onNotificationTap(message);
        }
      }).catchError((e) {
        debugPrint('[FCM][INITIAL_MESSAGE][ERROR] $e');
      });
    } catch (e) {
      debugPrint('[FCM][SETUP][ERROR] $e');
    }
  }

  // ── Permission + Token ──────────────────────────────────────────────────────

  static Future<bool> _requestPermission() async {
    debugPrint('[FCM][PERMISSION_REQUEST] requesting notification permission');
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final status = settings.authorizationStatus;
      debugPrint('[FCM][PERMISSION_RESULT] status=$status');
      return status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('[FCM][PERMISSION_REQUEST][ERROR] $e');
      return false;
    }
  }

  static Future<void> _requestPermissionAndToken() async {
    final granted = await _requestPermission();
    if (!granted) {
      debugPrint('[FCM][TOKEN_REQUEST] permission not granted — token registration skipped');
      return;
    }
    debugPrint('[FCM][TOKEN_REQUEST] requesting FCM token');
    try {
      _currentToken = await _messaging.getToken();
      if (_currentToken == null) {
        debugPrint('[FCM][TOKEN_ERROR] getToken() returned null');
        return;
      }
      final preview = _currentToken!.length > 16
          ? '${_currentToken!.substring(0, 16)}…'
          : _currentToken!;
      debugPrint('[FCM][TOKEN_RECEIVED] token=$preview');

      final uid = AuthService.currentUserId;
      if (uid != null) {
        final prefs = await UserProfileService.getNotificationPrefs(uid);
        if (prefs.notificationsEnabled) {
          debugPrint('[FCM][TOKEN_SAVE] saving token for uid=$uid');
          await UserProfileService.addFcmToken(uid, _currentToken!);
          debugPrint('[FCM][TOKEN_SAVE] token saved for uid=$uid');
        } else {
          debugPrint('[FCM][TOKEN_SAVE] notifications disabled for uid=$uid — token not saved');
        }
      } else {
        debugPrint('[FCM][TOKEN_SAVE] no logged-in user — token will be saved on login');
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] $e');
    }
  }

  static void _attachTokenRefreshListener() {
    if (_tokenRefreshListenerAttached) return;
    _tokenRefreshListenerAttached = true;
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      debugPrint('[FCM][TOKEN_REFRESH] new token from Firebase');
      _currentToken = token;
      final uid = AuthService.currentUserId;
      if (uid == null || uid.isEmpty) {
        debugPrint('[FCM][TOKEN_REFRESH] no logged-in user — token not saved');
        return;
      }
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (!prefs.notificationsEnabled) {
        debugPrint('[FCM][TOKEN_REFRESH] notifications disabled for uid=$uid — token not saved');
        return;
      }
      await UserProfileService.addFcmToken(uid, token);
      debugPrint('[FCM][TOKEN_REFRESH] token saved for uid=$uid');
    }, onError: (e) {
      debugPrint('[FCM][TOKEN_ERROR] onTokenRefresh: $e');
    });
  }

  // ── Login / logout token lifecycle ─────────────────────────────────────────

  /// Call after Firebase login: ensure the FCM token is registered for this user.
  static Future<void> onLogin(String uid) async {
    if (!AppFirebase.isReady || uid.isEmpty) return;
    debugPrint('[FCM][TOKEN_SAVE] onLogin uid=$uid — saving token');
    try {
      _currentToken = await _messaging.getToken();
      if (_currentToken == null) {
        debugPrint('[FCM][TOKEN_REQUEST] no cached token — requesting fresh token');
        await _requestPermissionAndToken();
        return;
      }
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (prefs.notificationsEnabled) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
        debugPrint('[FCM][TOKEN_SAVE] token saved on login for uid=$uid');
      } else {
        debugPrint('[FCM][TOKEN_SAVE] notifications disabled for uid=$uid — token not saved');
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] onLogin: $e');
    }
  }

  /// Call when user enables notifications in settings.
  static Future<void> enableAndSaveToken(String uid) async {
    if (!AppFirebase.isReady || uid.isEmpty) return;
    debugPrint('[FCM][TOKEN_SAVE] enableAndSaveToken uid=$uid');
    try {
      await UserProfileService.setNotificationsEnabled(uid, true);
      final granted = await _requestPermission();
      if (!granted) {
        debugPrint('[FCM][TOKEN_SAVE] permission not granted — token not saved');
        return;
      }
      _currentToken = await _messaging.getToken();
      if (_currentToken != null) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
        debugPrint('[FCM][TOKEN_SAVE] token saved after enable for uid=$uid');
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] enableAndSaveToken: $e');
    }
  }

  /// Call when user disables notifications: remove token from Supabase.
  static Future<void> disableAndRemoveToken(String uid) async {
    if (uid.isEmpty) return;
    debugPrint('[FCM][TOKEN_SAVE] disableAndRemoveToken uid=$uid');
    try {
      await UserProfileService.setNotificationsEnabled(uid, false);
      if (_currentToken != null) {
        await UserProfileService.removeFcmToken(uid, _currentToken!);
        debugPrint('[FCM][TOKEN_SAVE] token removed for uid=$uid');
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] disableAndRemoveToken: $e');
    }
  }
}
