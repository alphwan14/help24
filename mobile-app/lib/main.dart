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
import 'screens/home_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/web_view_screen.dart';
import 'services/diagnostic_service.dart';
import 'services/notification_service.dart';
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
    _bootstrapFuture = _runBackgroundBootstrap();
  }

  Future<void> _runBackgroundBootstrap() async {
    try {
      // ✅ Supabase is already initialized in main() - don't reinitialize!
      // Just initialize Firebase
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

  void _onForegroundMessage(RemoteMessage message) {
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final type = (data['type'] as String?) ?? '';

    // Suppress if the user is actively viewing this chat.
    final ctx = _navigatorKey.currentContext;
    final activeChatId = ctx != null ? ctx.read<AppProvider>().activeChatId : _activeChatId;
    if (chatId != null && chatId.isNotEmpty && chatId == activeChatId) {
      debugPrint('main: suppressing foreground notification for active chat $chatId');
      return;
    }

    final title = message.notification?.title ??
        (data['title'] as String?) ??
        'Help24';
    final body = message.notification?.body ??
        (data['body'] as String?) ??
        'You have a new message';

    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    const lifecycleTypes = {
      'completion_requested',
      'job_approved',
      'dispute_opened',
      'payout_released',
      'payment_secured',
      'dispute_resolved_release',
      'dispute_resolved_refund',
      'dispute_resolved_partial',
      'escrow_released',  // new: payout confirmed after B2C callback
    };

    void Function()? onTap;
    if (chatId != null && chatId.isNotEmpty) {
      onTap = () => _openChat(context, chatId);
    } else if (lifecycleTypes.contains(type)) {
      onTap = () {
        final uid = context.read<AuthProvider>().currentUserId;
        if (uid != null && uid.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NotificationsScreen(userId: uid),
            ),
          );
        }
      };
    }

    NotificationBannerOverlay.show(
      context: context,
      title: title,
      body: body,
      onTap: onTap,
    );
  }

  void _openChat(BuildContext context, String chatId) {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null) return;
    final conv = Conversation(
      id: chatId,
      userName: 'Chat',
      lastMessage: '',
      lastMessageTime: DateTime.now(),
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: conv, currentUserId: uid),
      ),
    );
  }

  void _onNotificationTap(RemoteMessage message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final postId = (data['postId'] ?? data['post_id']) as String?;
    final type = (data['type'] as String?) ?? '';
    debugPrint('main._onNotificationTap payload: $data');

    // Lifecycle notifications: route to the in-app notifications inbox
    // so users can see the full message and then navigate from there.
    const lifecycleTypes = {
      'completion_requested',
      'job_approved',
      'dispute_opened',
      'payout_released',
      'payment_secured',
      'dispute_resolved_release',
      'dispute_resolved_refund',
      'dispute_resolved_partial',
      'escrow_released',  // new: payout confirmed after B2C callback
    };

    if (lifecycleTypes.contains(type)) {
      final uid = context.read<AuthProvider>().currentUserId;
      if (uid != null && uid.isNotEmpty) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NotificationsScreen(userId: uid),
          ),
        );
      }
      return;
    }

    if (chatId != null && chatId.isNotEmpty) {
      _openChat(context, chatId);
    } else if (postId != null && postId.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WebViewScreen(
            title: 'Post',
            url: 'https://help24-24410.web.app/post.html?id=$postId',
          ),
        ),
      );
    }
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