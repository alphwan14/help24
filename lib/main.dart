import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/app_urls.dart';
import 'config/firebase_config.dart';
// import 'config/supabase_config.dart'; // REMOVE THIS - NOT NEEDED
import 'l10n/app_localizations.dart';
import 'models/post_model.dart';
import 'providers/app_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/location_provider.dart';
import 'widgets/loading_empty_offline.dart';
import 'screens/home_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/web_view_screen.dart';
import 'services/diagnostic_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://taohzhnvaitrpxcyjflq.supabase.co',
    anonKey: 'sb_publishable_WQYHVfGzH-VKqkM2WLT-8A_NjQ6WeZD',
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
      await FirebaseConfig.initialize();
      if (FirebaseConfig.isConfigured) {
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
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message.notification?.body ?? message.notification?.title ?? 'New notification'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onNotificationTap(RemoteMessage message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final postId = (data['postId'] ?? data['post_id']) as String?;
    debugPrint('main._onNotificationTap payload: $data');
    final uid = context.read<AuthProvider>().currentUserId;
    if (chatId != null && chatId.isNotEmpty && uid != null) {
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
    // Firebase + notifications bootstrap runs in background.
    // AuthProvider is already initialized via ChangeNotifierProvider; re-init
    // here so it picks up Firebase messaging token after bootstrap completes.
    unawaited(widget.bootstrapFuture?.then((_) async {
      if (!mounted) return;
      await context.read<AuthProvider>().initialize();
    }) ?? Future<void>.value());
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