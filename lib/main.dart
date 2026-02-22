import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/app_urls.dart';
import 'config/firebase_config.dart';
import 'config/supabase_config.dart';
import 'l10n/app_localizations.dart';
import 'models/post_model.dart';
import 'providers/app_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'screens/home_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/web_view_screen.dart';
import 'services/diagnostic_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SupabaseConfig.initialize();
  await FirebaseConfig.initialize();

  if (FirebaseConfig.isConfigured) {
    await NotificationService.initialize();
  }

  if (kDebugMode) {
    await DiagnosticService.runDiagnostics();
    await DiagnosticService.testUpload();
  }

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.darkSurface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const Help24App());
}

class Help24App extends StatefulWidget {
  const Help24App({super.key});

  @override
  State<Help24App> createState() => _Help24AppState();
}

class _Help24AppState extends State<Help24App> {
  @override
  void initState() {
    super.initState();
    NotificationService.setNavigatorKey(_navigatorKey);
    NotificationService.setupMessageHandlers(
      onForegroundMessage: _onForegroundMessage,
      onNotificationTap: _onNotificationTap,
    );
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
    final chatId = data['chatId'] as String?;
    final postId = data['postId'] as String?;
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
        ChangeNotifierProvider(create: (_) => AppProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()..initialize()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
      ],
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
              home: const HomeScreen(),
            ),
          );
        },
      ),
    );
  }
}
