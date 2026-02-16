import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/app_provider.dart';
import 'providers/auth_provider.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'config/supabase_config.dart';
import 'config/firebase_config.dart';
import 'services/diagnostic_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Supabase (always works)
  await SupabaseConfig.initialize();
  
  // Initialize Firebase (only if configured - won't crash if not)
  await FirebaseConfig.initialize();
  
  
  // Run diagnostics in debug mode
  if (kDebugMode) {
    await DiagnosticService.runDiagnostics();
    await DiagnosticService.testUpload();
  }
  
  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.darkSurface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const Help24App());
}

class Help24App extends StatelessWidget {
  const Help24App({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()..initialize()),
      ],
      child: Consumer<AppProvider>(
        builder: (context, appProvider, _) {
          // Update system UI based on theme
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                appProvider.isDarkMode ? Brightness.light : Brightness.dark,
            systemNavigationBarColor:
                appProvider.isDarkMode ? AppTheme.darkSurface : AppTheme.lightSurface,
            systemNavigationBarIconBrightness:
                appProvider.isDarkMode ? Brightness.light : Brightness.dark,
          ));

          return MaterialApp(
            title: 'Help24',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
