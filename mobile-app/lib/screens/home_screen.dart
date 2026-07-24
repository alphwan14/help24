import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/supabase_auth_bridge.dart';
import '../services/user_profile_service.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/auth_guard.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/location_provider.dart';
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

  /// Presence heartbeat. `is_online` is a flag another device wrote, so on its
  /// own it goes stale (a crash leaves it stuck true) and `last_seen` freezes
  /// at the last lifecycle transition — which is why a user sitting in an open
  /// chat still read as "last seen 22 min ago". Refreshing it on a timer makes
  /// presence reflect observed liveness. Readers treat presence as valid only
  /// while this beat is fresh (see _presenceStaleAfter in ChatScreen).
  static const Duration _presenceHeartbeat = Duration(seconds: 60);
  Timer? _presenceTimer;

  Future<void> _beatPresence() async {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null || uid.isEmpty) return;
    // The presence row is RLS-protected. On a cold start the Firebase→Supabase
    // token exchange is still in flight for the first seconds, and a write sent
    // before it lands is rejected with "permission denied" — which is exactly
    // how a user sitting in an open chat stayed flagged offline.
    await SupabaseAuthBridge.ensureSessionAsync();
    if (!mounted) return;
    await UserProfileService.setOnline(uid, true);
  }

  void _startPresence() {
    _presenceTimer?.cancel();
    _beatPresence();
    _presenceTimer = Timer.periodic(_presenceHeartbeat, (_) {
      if (mounted) _beatPresence();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.isLoggedIn) {
        context.read<LocaleProvider>().loadLanguageForUser();
        // Cold start with a restored session never fires a lifecycle CHANGE,
        // so the resume branch below does not run and the user would stay
        // flagged offline for the whole session. Start the beat explicitly.
        _startPresence();
      }
    });
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
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
        _startPresence(); // beat now, then keep beating while foregrounded
        // Re-check location permission in case user granted it in Settings
        // while the app was in the background.
        context.read<LocationProvider>().refreshPermissionStatus();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _presenceTimer?.cancel();
        _presenceTimer = null;
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
        // Auth just resolved (cold start restores the session asynchronously,
        // so initState ran while uid was still empty). This is the first point
        // where a presence write can pass RLS.
        if (uid.isEmpty) {
          _presenceTimer?.cancel();
          _presenceTimer = null;
        } else {
          _startPresence();
        }
        _handleAuthLocationFlow(uid);
        // Preload Messages the moment auth is ready — conversations, unread
        // counts and avatars sync quietly in the background so the tab opens
        // instantly instead of loading on first visit. loadConversations is
        // idempotent, so later tab taps are no-ops. Empty uid resets state on
        // logout.
        context.read<AppProvider>().loadConversations(uid);
        // Server-derived "Applied / Offer sent" state for feed cards.
        context.read<AppProvider>().loadMyApplications(uid);
      });
    }

    // Android back behaves like a "home" gesture: from any tab (Jobs, Messages,
    // Profile) the first back press returns to Discover; only a second press —
    // already on Discover — leaves the app. The Post screen keeps its own inner
    // PopScope (which also lands on Discover), so this one stays out of its way.
    return PopScope(
      canPop: !_showPostScreen && _currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _showPostScreen) return;
        setState(() => _currentIndex = 0);
      },
      child: Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
        children: [
          // No connectivity chrome on the tab container: offline is a background
          // state, communicated where it matters — a subtle indicator on the
          // Discover feed (live browsing) and contextual snackbars on actions
          // elsewhere. Keeping the shell calm is deliberate.
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
