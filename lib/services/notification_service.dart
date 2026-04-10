import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/firebase_config.dart';
import 'auth_service.dart';
import 'user_profile_service.dart';

/// Handles FCM: permission, token save to Supabase users (when notificationsEnabled),
/// foreground in-app banner, background/opened navigation.
///
/// Push notifications for new messages (must be sent from backend):
/// When a new row is inserted into chat_messages:
/// 1. Resolve recipient: chat has user1, user2 — recipient is the one who is not sender_id.
/// 2. Load recipient fcm_tokens from public.users (column fcm_tokens jsonb).
/// 3. If notifications_enabled and tokens non-empty, send FCM to each token:
///    title: sender name (e.g. from users.name where id = sender_id)
///    body: message preview (e.g. content truncated to 80 chars)
///    data: { "chatId": "<chat_id uuid>", "postId": "<optional post_id>" }
/// 4. On tap, app opens ChatScreen with conversation.id = data.chatId (see main.dart _onNotificationTap).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('NotificationService background: ${message.messageId}');
}

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static String? _currentToken;
  static VoidCallback? _onForegroundNotification;
  static GlobalKey<NavigatorState>? _navigatorKey;
  static bool _tokenRefreshListenerAttached = false;

  static String? get currentToken => _currentToken;

  /// Call from main: pass navigator key for opening chat/post when notification is tapped.
  static void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  /// Call from main after MaterialApp has a ScaffoldMessenger: pass callback to show in-app banner when app in foreground.
  static void setForegroundDisplayCallback(VoidCallback? callback) {
    _onForegroundNotification = callback;
  }

  /// Show a foreground notification (title, body, data). Call this from your callback with RemoteMessage.
  static void showForegroundBanner({
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) {
    _onForegroundNotification?.call();
    // Actual display is done by the widget that registered the callback (e.g. overlay or SnackBar).
  }

  /// Initialize FCM: request permission, get token, register background handler.
  /// Does not throw; logs and returns on any failure (e.g. web without service worker, permission denied).
  static Future<void> initialize() async {
    if (!FirebaseConfig.isConfigured) return;
    try {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await _requestPermissionAndToken();
      _attachTokenRefreshListener();
    } catch (e, st) {
      debugPrint('NotificationService initialize: $e');
      if (kDebugMode) debugPrint(st.toString());
    }
  }

  static Future<bool> _requestPermission() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('NotificationService permission status: ${settings.authorizationStatus}');
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('NotificationService permission: $e');
      return false;
    }
  }

  static Future<void> _requestPermissionAndToken() async {
    final granted = await _requestPermission();
    if (!granted) {
      debugPrint('NotificationService: permission not granted, skipping token registration');
      return;
    }
    try {
      if (Platform.isAndroid) {
        // Optional: create channel for Android
        // await FirebaseMessaging.instance.setDeliveryMetricsExportToBigQuery(true);
      }
      _currentToken = await _messaging.getToken();
      debugPrint('NotificationService token fetch: ${_currentToken != null ? "ok" : "null"}');
      final uid = AuthService.currentUserId;
      if (uid != null && _currentToken != null) {
        final prefs = await UserProfileService.getNotificationPrefs(uid);
        if (prefs.notificationsEnabled) {
          await UserProfileService.addFcmToken(uid, _currentToken!);
          debugPrint('NotificationService: token saved to users.fcm_tokens for uid=$uid');
        } else {
          debugPrint('NotificationService: notifications disabled for uid=$uid, token not saved');
        }
      } else {
        debugPrint('NotificationService: token save skipped (uid=${uid ?? "null"}, token=${_currentToken == null ? "null" : "set"})');
      }
    } catch (e) {
      debugPrint('NotificationService getToken: $e');
    }
  }

  /// Call after login: if notificationsEnabled, save FCM token to Supabase users.fcm_tokens.
  static Future<void> onLogin(String uid) async {
    if (!FirebaseConfig.isConfigured || uid.isEmpty) return;
    try {
      _currentToken = await _messaging.getToken();
      if (_currentToken == null) await _requestPermissionAndToken();
      _currentToken ??= await _messaging.getToken();
      if (_currentToken == null) return;
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (prefs.notificationsEnabled) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
        debugPrint('NotificationService onLogin: token saved for uid=$uid');
      } else {
        debugPrint('NotificationService onLogin: notifications disabled for uid=$uid');
      }
    } catch (e) {
      debugPrint('NotificationService onLogin: $e');
    }
  }

  /// Call when user enables notifications in settings: update Supabase first so UI shows On,
  /// then try to get/save token (may fail on web or if permission denied).
  static Future<void> enableAndSaveToken(String uid) async {
    if (!FirebaseConfig.isConfigured || uid.isEmpty) return;
    try {
      await UserProfileService.setNotificationsEnabled(uid, true);
      final granted = await _requestPermission();
      if (!granted) return;
      _currentToken = await _messaging.getToken();
      if (_currentToken != null) {
        await UserProfileService.addFcmToken(uid, _currentToken!);
      }
    } catch (e) {
      debugPrint('NotificationService enableAndSaveToken: $e');
    }
  }

  /// Call when user disables notifications: update Supabase first so UI shows Off, then remove token.
  static Future<void> disableAndRemoveToken(String uid) async {
    if (uid.isEmpty) return;
    try {
      await UserProfileService.setNotificationsEnabled(uid, false);
      if (_currentToken != null) {
        await UserProfileService.removeFcmToken(uid, _currentToken!);
      }
    } catch (e) {
      debugPrint('NotificationService disableAndRemoveToken: $e');
    }
  }

  /// Set up foreground/opened handlers. Call after MaterialApp is built. Never throws; logs on FCM errors.
  static void setupMessageHandlers({
    required void Function(RemoteMessage message) onForegroundMessage,
    required void Function(RemoteMessage message) onNotificationTap,
  }) {
    try {
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('NotificationService onMessage: ${message.notification?.title}');
        onForegroundMessage(message);
      }, onError: (e) {
        debugPrint('NotificationService onMessage error: $e');
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('NotificationService onMessageOpenedApp: ${message.data}');
        onNotificationTap(message);
      }, onError: (e) {
        debugPrint('NotificationService onMessageOpenedApp error: $e');
      });

      FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
        if (message != null) onNotificationTap(message);
      }).catchError((e) {
        debugPrint('NotificationService getInitialMessage: $e');
      });
    } catch (e) {
      debugPrint('NotificationService setupMessageHandlers: $e');
    }
  }

  static void _attachTokenRefreshListener() {
    if (_tokenRefreshListenerAttached) return;
    _tokenRefreshListenerAttached = true;
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      _currentToken = token;
      final uid = AuthService.currentUserId;
      debugPrint('NotificationService onTokenRefresh: received new token');
      if (uid == null || uid.isEmpty) {
        debugPrint('NotificationService onTokenRefresh: no logged-in user, skipping save');
        return;
      }
      final prefs = await UserProfileService.getNotificationPrefs(uid);
      if (!prefs.notificationsEnabled) {
        debugPrint('NotificationService onTokenRefresh: notifications disabled, skipping save');
        return;
      }
      await UserProfileService.addFcmToken(uid, token);
      debugPrint('NotificationService onTokenRefresh: token saved for uid=$uid');
    }, onError: (e) {
      debugPrint('NotificationService onTokenRefresh error: $e');
    });
  }

  /// Navigate to chat or post based on notification data. Call from onNotificationTap.
  static void handleNotificationTap(RemoteMessage message, BuildContext context) {
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final postId = (data['postId'] ?? data['post_id']) as String?;
    if (context.mounted) {
      if (chatId != null && chatId.isNotEmpty) {
        _navigateToChat(context, chatId);
      } else if (postId != null && postId.isNotEmpty) {
        _navigateToPost(context, postId);
      }
    }
  }

  static void _navigateToChat(BuildContext context, String chatId) {
    // Navigate to Messages and open this chat. Requires conversation in app state or push route with chatId.
    final nav = Navigator.of(context);
    // Pop until home then switch to messages tab and push chat. App-specific: adjust to your routes.
    nav.popUntil((route) => route.isFirst);
    // Dispatch to open Messages tab and ChatScreen(conversation with id == chatId). AppProvider may need openChat(chatId).
    // For simplicity we push a named route or use a global key. Here we just push a generic chat route if you have one.
    // If you don't have a direct ChatScreen route, you'll need to use AppProvider or a callback to switch tab and open chat.
    debugPrint('NotificationService: open chat $chatId');
    // Example: Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, ...)));
  }

  static void _navigateToPost(BuildContext context, String postId) {
    debugPrint('NotificationService: open post $postId');
    // Example: Navigator.push(context, MaterialPageRoute(builder: (_) => PostDetailScreen(postId: postId)));
  }
}
