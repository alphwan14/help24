import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_profile_service.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/auth_guard.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/location_provider.dart';
import '../widgets/loading_empty_offline.dart';
import 'discover_screen.dart';
import 'jobs_screen.dart';
import 'post_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';
import 'location_permission_explainer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  bool _showPostScreen = false;
  String _lastAuthUserId = '';
  bool _locationPromptInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.isLoggedIn) {
        context.read<LocaleProvider>().loadLanguageForUser();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null || uid.isEmpty) return;
    switch (state) {
      case AppLifecycleState.resumed:
        UserProfileService.setOnline(uid, true);
        // Re-check location permission in case user granted it in Settings
        // while the app was in the background.
        context.read<LocationProvider>().refreshPermissionStatus();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        UserProfileService.setOnline(uid, false);
        break;
    }
  }

  void _onNavTap(int index) {
    if (index == 2) {
      // Post button - requires authentication
      AuthGuard.requireAuth(
        context,
        action: 'create a post',
        onAuthenticated: () {
          setState(() {
            _showPostScreen = true;
          });
        },
      );
    } else if (index == 3) {
      // Messages - requires authentication; reload conversations when opening tab
      AuthGuard.requireAuth(
        context,
        action: 'view messages',
        onAuthenticated: () {
          setState(() {
            _currentIndex = 2; // Messages is index 2 in the stack
            _showPostScreen = false;
          });
          final uid = context.read<AuthProvider>().currentUserId ?? '';
          if (uid.isNotEmpty) {
            context.read<AppProvider>().loadConversations(uid);
          }
        },
      );
    } else {
      setState(() {
        _currentIndex = index > 2 ? index - 1 : index;
        _showPostScreen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final uid = auth.currentUserId ?? '';
    if (uid != _lastAuthUserId) {
      _lastAuthUserId = uid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleAuthLocationFlow(uid);
      });
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
        children: [
          Consumer<ConnectivityProvider>(
            builder: (_, connectivity, __) =>
                connectivity.isOffline ? const OfflineBanner() : const SizedBox.shrink(),
          ),
          Expanded(
            child: _showPostScreen
                ? PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) {
                        setState(() {
                          _showPostScreen = false;
                          _currentIndex = 0;
                        });
                      }
                    },
                    child: PostScreen(
                      onComplete: () {
                        setState(() {
                          _showPostScreen = false;
                          _currentIndex = 0;
                        });
                      },
                    ),
                  )
                : IndexedStack(
                    index: _currentIndex,
                    children: const [
                      DiscoverScreen(),
                      JobsScreen(),
                      MessagesScreen(),
                      ProfileScreen(),
                    ],
                  ),
          ),
        ],
        ),
      ),
      bottomNavigationBar: _showPostScreen
          ? null
          : CustomBottomNav(
              currentIndex: _getNavIndex(),
              onTap: _onNavTap,
            ),
    );
  }

  int _getNavIndex() {
    // Map the actual tab index to the nav index (accounting for center button)
    if (_currentIndex >= 2) {
      return _currentIndex + 1;
    }
    return _currentIndex;
  }

  Future<void> _handleAuthLocationFlow(String uid) async {
    final location = context.read<LocationProvider>();
    final app = context.read<AppProvider>();
    if (uid.isEmpty) {
      app.setPriorityLocationCity(null);
      return;
    }

    await location.initializeForUser(uid);
    app.setPriorityLocationCity(location.city);

    final shouldShow = await location.shouldShowExplainer(uid);
    if (!mounted || !shouldShow || _locationPromptInFlight) return;
    _locationPromptInFlight = true;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LocationPermissionExplainerScreen(userId: uid),
    );
    _locationPromptInFlight = false;
    if (!mounted) return;
    await location.initializeForUser(uid);
    app.setPriorityLocationCity(location.city);
  }
}
