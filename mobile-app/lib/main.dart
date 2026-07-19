import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/app_firebase.dart';
import 'http_client_with_token.dart';
import 'l10n/app_localizations.dart';
import 'models/post_model.dart';
import 'providers/app_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/location_provider.dart';
import 'screens/applications_screen.dart';
import 'screens/approve_or_dispute_screen.dart';
import 'screens/dispute_thread_screen.dart';
import 'screens/job_lifecycle_screen.dart';
import 'screens/review_submission_screen.dart';
import 'screens/home_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/notifications_screen.dart';
import 'services/category_schema_service.dart';
import 'services/chat_local_prefs.dart';
import 'services/diagnostic_service.dart';
import 'services/journey_engine.dart';
import 'services/notification_service.dart';
import 'services/startup_prefetch.dart';
import 'services/supabase_auth_bridge.dart';
import 'theme/app_theme.dart';
import 'widgets/notification_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Tracks which chatId the user is currently viewing so foreground
/// notifications for that specific chat are suppressed (they already see it).
/// Updated by ChatScreen via AppProvider.setActiveChatId().
String? _activeChatId;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase with the custom HTTP client so Firebase-exchanged JWTs
  // are injected into every PostgREST request — this gives the `authenticated`
  // role after login (required for RLS-protected tables like notifications).
  await Supabase.initialize(
    url: 'https://taohzhnvaitrpxcyjflq.supabase.co',
    anonKey: 'sb_publishable_WQYHVfGzH-VKqkM2WLT-8A_NjQ6WeZD',
    httpClient: HttpClientWithToken(),
  );

  // Use the time the native splash is still on screen: start Firebase init
  // (auth/session restore depends on it — the background bootstrap awaits the
  // SAME memoized future) and fire the first-screen data fetches NOW instead
  // of after the first frame. Both are unawaited: startup time is unchanged,
  // and on failure the app falls back to its existing load paths.
  unawaited(AppFirebase.initialize());
  StartupPrefetch.begin();
  // Warm the muted-chats set for synchronous reads in list tiles and menus.
  unawaited(ChatLocalPrefs.ensureLoaded());

  // Journey recovery: if the process died mid-journey, silently re-own it so
  // the traveller never has to notice. Short delay lets Firebase restore the
  // session first; if auth lands later anyway, the engine's keepalive beats
  // heal the journey on their own (interrupted → travelling).
  unawaited(Future.delayed(const Duration(seconds: 4), () async {
    await SupabaseAuthBridge.ensureSessionAsync();
    await JourneyEngine.instance.resumePersisted();
  }));

  // Load persisted theme before first frame — prevents any dark/light flicker.
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('isDarkMode') ?? true;

  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
    systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
  ));

  runApp(Help24App(initialDarkMode: isDark));
}

class Help24App extends StatefulWidget {
  final bool initialDarkMode;

  const Help24App({super.key, this.initialDarkMode = true});

  @override
  State<Help24App> createState() => _Help24AppState();
}

class _Help24AppState extends State<Help24App> {
  Future<void>? _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    NotificationService.setNavigatorKey(_navigatorKey);
    NotificationService.setupMessageHandlers(
      onForegroundMessage: _onForegroundMessage,
      onNotificationTap: _onNotificationTap,
    );
    // Route taps on local notifications (produced while app is in foreground)
    // through the same handler as FCM opened-app taps.
    NotificationService.setOnLocalNotificationTap((data) {
      _onNotificationTap(RemoteMessage(data: data));
    });
    _bootstrapFuture = _runBackgroundBootstrap();
  }

  Future<void> _runBackgroundBootstrap() async {
    try {
      // Warm the category registry (cache-first, 24h TTL) so feed cards can
      // resolve highlight chips without opening the Post screen. Fire-and-
      // forget: never blocks startup, never throws.
      unawaited(CategorySchemaService.instance.warmUp());
      // ✅ Supabase is already initialized in main() - don't reinitialize!
      // Join the Firebase init started in main() (memoized — never runs twice).
      await AppFirebase.initialize();
      if (AppFirebase.isReady) {
        await NotificationService.initialize();
      }
      if (kDebugMode) {
        unawaited(DiagnosticService.runDiagnostics());
        unawaited(DiagnosticService.testUpload());
      }
    } catch (e) {
      debugPrint('Background bootstrap error: $e');
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final type = (data['type'] as String?) ?? '';
    final postId = (data['post_id'] ?? data['postId']) as String?;

    // Suppress if the user is actively viewing this chat.
    final ctx = _navigatorKey.currentContext;
    final activeChatId = ctx != null ? ctx.read<AppProvider>().activeChatId : _activeChatId;
    if (chatId != null && chatId.isNotEmpty && chatId == activeChatId) {
      debugPrint('main: suppressing foreground notification for active chat $chatId');
      return;
    }

    // Muted chats: no banner (the unread badge still updates via the list).
    if (type == 'chat_message' &&
        chatId != null &&
        chatId.isNotEmpty &&
        await ChatLocalPrefs.isMuted(chatId)) {
      debugPrint('main: suppressing foreground notification for muted chat $chatId');
      return;
    }

    // Chat data-only payloads carry sender_name / message_preview — not
    // title / body — because the notification field is intentionally absent
    // (we want MessagingStyle, not FCM auto-display).  Use the right keys.
    final String title;
    final String body;
    if (type == 'chat_message') {
      title = (data['sender_name'] as String?) ??
              message.notification?.title ??
              'New message';
      body  = (data['message_preview'] as String?) ??
              message.notification?.body ??
              '';
    } else {
      title = message.notification?.title ??
              (data['title'] as String?) ??
              'Help24';
      body  = message.notification?.body ??
              (data['body'] as String?) ??
              'You have a new notification';
    }

    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      debugPrint('main: foreground context unavailable — OS notification shown by NotificationService');
      return;
    }

    // Banner tap → route to the exact destination (same router as push notification taps).
    final onTap = () => unawaited(
      _routeNotification(context, type: type, chatId: chatId, postId: postId, data: data),
    );

    NotificationBannerOverlay.show(
      context: context,
      title: title,
      body: body,
      onTap: onTap,
    );
  }

  Future<void> _openChat(BuildContext context, String chatId) async {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null) return;
    debugPrint('[NAV][OPEN_CHAT] chatId=$chatId');

    // Load the partner's name and avatar so the chat header shows the real user.
    String userName = 'Chat';
    String userAvatar = '';
    String participantId = '';
    String? postId;
    String? postTitle;
    try {
      final chatRow = await Supabase.instance.client
          .from('chats')
          .select('user1, user2, post_id, posts!chats_post_id_fkey(title)')
          .eq('id', chatId)
          .maybeSingle();
      if (chatRow != null) {
        final u1 = chatRow['user1'] as String? ?? '';
        final u2 = chatRow['user2'] as String? ?? '';
        postId = chatRow['post_id']?.toString();
        final postsData = chatRow['posts'];
        postTitle = postsData is Map<String, dynamic> ? postsData['title'] as String? : null;
        participantId = (u1 == uid) ? u2 : u1;
        if (participantId.isNotEmpty) {
          // Same columns the chat list resolves avatars from (avatar_url with
          // profile_image fallback) — profile_picture_url does not exist.
          final userRow = await Supabase.instance.client
              .from('users')
              .select('name, avatar_url, profile_image')
              .eq('id', participantId)
              .maybeSingle();
          userName = (userRow?['name'] as String?) ?? 'Chat';
          final avatar = (userRow?['avatar_url'] as String?)?.trim() ?? '';
          final profileImage = (userRow?['profile_image'] as String?)?.trim() ?? '';
          userAvatar = avatar.isNotEmpty ? avatar : profileImage;
        }
      }
    } catch (e) {
      debugPrint('[NAV][OPEN_CHAT] partner name load failed: $e');
    }

    if (!context.mounted) return;
    final conv = Conversation(
      id: chatId,
      participantId: participantId,
      userName: userName,
      userAvatar: userAvatar,
      lastMessage: '',
      lastMessageTime: DateTime.now(),
      postId: postId,
      postTitle: postTitle,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: conv, currentUserId: uid),
      ),
    );
  }

  void _openNotificationsScreen(BuildContext context) {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null || uid.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NotificationsScreen(userId: uid)),
    );
  }

  /// Centralized deep-link router. Every notification type maps to a specific screen.
  Future<void> _routeNotification(
    BuildContext context, {
    required String type,
    String? chatId,
    String? postId,
    required Map<String, dynamic> data,
  }) async {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null || uid.isEmpty) return;

    switch (type) {
      // ── Chat message → open the exact conversation ─────────────────────────
      case 'chat_message':
        if (chatId != null && chatId.isNotEmpty) {
          await _openChat(context, chatId);
        }
        break;

      // ── Provider selected → open the job chat (next step: secure payment) ──
      case 'provider_selected':
        if (chatId != null && chatId.isNotEmpty) {
          await _openChat(context, chatId);
        } else if (postId != null && postId.isNotEmpty) {
          await _findAndOpenChat(context, postId: postId, uid: uid);
        }
        break;

      // ── Money + dispute lifecycle → unified Job Lifecycle Detail ───────────
      case 'payment_secured':
      case 'payout_released':
      case 'escrow_released':
      case 'job_approved':
      case 'dispute_opened':
      case 'dispute_resolved_release':
      case 'dispute_resolved_refund':
      case 'dispute_resolved_partial':
        if (postId != null && postId.isNotEmpty) {
          _openLifecycleScreen(context, postId: postId);
        } else {
          _openNotificationsScreen(context);
        }
        break;

      // ── Dispute communication → open the dispute conversation thread ───────
      case 'dispute_message':
      case 'dispute_evidence_requested':
      case 'dispute_evidence_uploaded':
        final disputeId = data['dispute_id'] as String?;
        if (disputeId != null && disputeId.isNotEmpty) {
          _openDisputeThread(context, disputeId: disputeId);
        } else if (postId != null && postId.isNotEmpty) {
          _openLifecycleScreen(context, postId: postId);
        } else {
          _openNotificationsScreen(context);
        }
        break;

      // ── Completion requested → open approve/dispute screen ─────────────────
      case 'completion_requested':
        if (postId != null && postId.isNotEmpty) {
          await _openApprovalScreen(context, postId: postId, clientUserId: uid);
        }
        break;

      // ── Review requested → open review submission (entry point 3) ──────────
      case 'review_requested':
        if (postId != null && postId.isNotEmpty) {
          debugPrint('[NAV][OPEN_REVIEW] postId=$postId');
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ReviewSubmissionScreen(postId: postId, clientUserId: uid),
          ));
        }
        break;

      // ── Provider applied → open applications screen ────────────────────────
      case 'provider_applied':
        if (postId != null && postId.isNotEmpty) {
          await _openApplicationsScreen(context, postId: postId);
        } else {
          _openNotificationsScreen(context);
        }
        break;

      default:
        debugPrint('[NAV][NOTIFICATION_OPEN] unhandled type=$type → NotificationsScreen');
        _openNotificationsScreen(context);
        break;
    }
  }

  /// Open the unified Job Lifecycle Detail screen (the destination for all
  /// money + dispute lifecycle notifications). The screen loads its own state.
  void _openLifecycleScreen(BuildContext context, {required String postId}) {
    debugPrint('[NAV][OPEN_LIFECYCLE] postId=$postId');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JobLifecycleScreen(postId: postId),
    ));
  }

  /// Open the participant dispute conversation. Destination for all
  /// dispute_message / dispute_evidence_* notifications (deep-linked by dispute_id).
  void _openDisputeThread(BuildContext context, {required String disputeId}) {
    debugPrint('[NAV][OPEN_DISPUTE_THREAD] disputeId=$disputeId');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DisputeThreadScreen(disputeId: disputeId),
    ));
  }

  /// Find and open the chat for a post, querying Supabase if chatId not in payload.
  Future<void> _findAndOpenChat(
    BuildContext context, {
    required String postId,
    required String uid,
  }) async {
    try {
      final res = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('post_id', postId)
          .or('user1.eq.$uid,user2.eq.$uid')
          .maybeSingle();
      final foundChatId = res?['id'] as String?;
      if (foundChatId != null && foundChatId.isNotEmpty && context.mounted) {
        debugPrint('[NAV][OPEN_CHAT] resolved chatId=$foundChatId for postId=$postId');
        await _openChat(context, foundChatId);
      } else if (context.mounted) {
        debugPrint('[NAV][OPEN_CHAT] no chat found for postId=$postId — fallback');
        _openNotificationsScreen(context);
      }
    } catch (e) {
      debugPrint('[NAV][OPEN_CHAT][ERROR] $e');
      if (context.mounted) _openNotificationsScreen(context);
    }
  }

  /// Open the self-loading ApproveOrDisputeScreen. Routing requires only post_id
  /// + current user; the screen loads its own data from GET /jobs/:postId/lifecycle.
  /// No Supabase reads here, so navigation never depends on RLS and never falls
  /// back to Messages/Notifications.
  Future<void> _openApprovalScreen(
    BuildContext context, {
    required String postId,
    required String clientUserId,
  }) async {
    debugPrint('[NAV][OPEN_APPROVAL] postId=$postId');
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ApproveOrDisputeScreen(
        postId: postId,
        clientUserId: clientUserId,
      ),
    ));
  }

  /// Open ApplicationsScreen by fetching post data for the given postId.
  Future<void> _openApplicationsScreen(
    BuildContext context, {
    required String postId,
  }) async {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null) return;
    try {
      final post = await Supabase.instance.client
          .from('posts')
          .select('id, title, author_user_id')
          .eq('id', postId)
          .maybeSingle();

      if (!context.mounted) return;
      if (post == null) {
        _openNotificationsScreen(context);
        return;
      }

      debugPrint('[NAV][OPEN_APPLICATIONS] postId=$postId');
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ApplicationsScreen(
          postId: postId,
          postTitle: post['title'] as String? ?? 'Job',
          authorUserId: post['author_user_id'] as String? ?? uid,
        ),
      ));
    } catch (e) {
      debugPrint('[NAV][OPEN_APPLICATIONS][ERROR] $e');
      if (context.mounted) _openNotificationsScreen(context);
    }
  }

  void _onNotificationTap(RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] as String?) ?? '';
    final chatId = (data['chat_id'] ?? data['chatId']) as String?;
    final postId = (data['post_id'] ?? data['postId']) as String?;
    debugPrint('[NAV][NOTIFICATION_OPEN] type=$type chatId=$chatId postId=$postId');

    // Defer navigation until the navigator context is available.
    // getInitialMessage() fires before the widget tree is built on terminated-app launches.
    void navigate() {
      final context = _navigatorKey.currentContext;
      if (context == null || !context.mounted) {
        debugPrint('[NAV][NOTIFICATION_OPEN] context not ready — deferring to next frame');
        WidgetsBinding.instance.addPostFrameCallback((_) => navigate());
        return;
      }
      debugPrint('[NAV][ROUTE_RESOLVED] type=$type');
      unawaited(_routeNotification(context, type: type, chatId: chatId, postId: postId, data: data));
    }

    navigate();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider(initialDarkMode: widget.initialDarkMode)),
        ChangeNotifierProvider(create: (_) => AuthProvider()..initialize()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (_) => LocationProvider()),
      ],
      child: _SyncOnReconnect(
        child: Consumer2<AppProvider, LocaleProvider>(
          builder: (context, appProvider, localeProvider, _) {
            SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness:
                  appProvider.isDarkMode ? Brightness.light : Brightness.dark,
              systemNavigationBarColor:
                  appProvider.isDarkMode ? AppTheme.darkSurface : AppTheme.lightSurface,
              systemNavigationBarIconBrightness:
                  appProvider.isDarkMode ? Brightness.light : Brightness.dark,
            ));

            return AppLocalizationsLoader(
              child: MaterialApp(
                navigatorKey: _navigatorKey,
                scaffoldMessengerKey: _scaffoldMessengerKey,
                title: 'Help24',
                debugShowCheckedModeBanner: false,
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: appProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
                locale: const Locale('en'),
                localizationsDelegates: const [appLocalizationsDelegate],
                supportedLocales: const [
                  Locale('en'),
                  Locale('sw'),
                ],
                home: StartupGate(bootstrapFuture: _bootstrapFuture),
              ),
            );
          },
        ),
      ),
    );
  }
}

class StartupGate extends StatefulWidget {
  final Future<void>? bootstrapFuture;

  const StartupGate({super.key, this.bootstrapFuture});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  @override
  void initState() {
    super.initState();
    unawaited(
      (widget.bootstrapFuture ?? Future<void>.value()).then((_) async {
        if (!mounted) return;
        await context.read<AuthProvider>().initialize();
      }),
    );
  }

  @override
  Widget build(BuildContext context) => const HomeScreen();
}

class _SyncOnReconnect extends StatefulWidget {
  final Widget child;

  const _SyncOnReconnect({required this.child});

  @override
  State<_SyncOnReconnect> createState() => _SyncOnReconnectState();
}

class _SyncOnReconnectState extends State<_SyncOnReconnect> {
  bool _wasOffline = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityProvider>(
      builder: (context, connectivity, _) {
        final isOffline = connectivity.isOffline;
        if (_wasOffline && !isOffline) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            context.read<AppProvider>().refreshAll();
            final uid = context.read<AuthProvider>().currentUserId;
            if (uid != null && uid.isNotEmpty) {
              context.read<AppProvider>().loadConversations(uid);
            }
          });
        }
        _wasOffline = isOffline;
        return widget.child;
      },
    );
  }
}