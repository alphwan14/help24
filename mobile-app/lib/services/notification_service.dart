import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/app_firebase.dart';
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
  /// Does not throw; logs and returns on any failure.
  static Future<void> initialize() async {
    if (!AppFirebase.isReady) {
      debugPrint('[FCM][INIT] Firebase not ready — skipping FCM initialization');
      return;
    }
    debugPrint('[FCM][INIT] starting FCM initialization');
    try {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await _requestPermissionAndToken();
      _attachTokenRefreshListener();
      debugPrint('[FCM][INIT] FCM initialization complete');
    } catch (e, st) {
      debugPrint('[FCM][INIT][ERROR] $e');
      if (kDebugMode) debugPrint(st.toString());
    }
  }

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
      // Log only prefix for security — never log full tokens in production.
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
        debugPrint('[FCM][TOKEN_SAVE] no logged-in user — token not saved (will be saved on login)');
      }
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] $e');
    }
  }

  /// Call after login: save FCM token so the backend can send push notifications.
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
      debugPrint('[FCM][TOKEN_REFRESH] new token received from Firebase');
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
