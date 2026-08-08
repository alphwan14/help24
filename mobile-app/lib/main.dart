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
import 'models/theme_preference.dart';
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
import 'services/auth_service.dart';
import 'services/cache_service.dart';
import 'services/category_schema_service.dart';
import 'services/feed_snapshot.dart';
import 'services/location_registry.dart';
import 'services/profession_registry.dart';
import 'services/chat_local_prefs.dart';
import 'services/diagnostic_service.dart';
import 'services/journey_engine.dart';
import 'services/launch_sequence.dart';
import 'services/notification_service.dart';
import 'services/notification_store.dart';
import 'services/remote_config_service.dart';
import 'services/reputation_service.dart';
import 'services/session_scope.dart';
import 'services/startup_prefetch.dart';
import 'services/supabase_auth_bridge.dart';
import 'theme/app_theme.dart';
import 'widgets/launch_splash.dart';
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
  // Arm the launch deadline from the same instant the prefetch starts, so the
  // clock covers the whole launch — Firebase's session restore included — and
  // not just the part after a widget tree exists. StartupGate holds the splash
  // until this says the feed is final, or until the deadline expires.
  LaunchSequence.begin();
  // Warm the muted-chats set for synchronous reads in list tiles and menus.
  unawaited(ChatLocalPrefs.ensureLoaded());
  // Pull the persisted reputation cache into memory now, so the first feed
  // cards and the first applicant list paint their trust signals from disk
  // instead of re-earning them over the network on every cold start.
  unawaited(ReputationService.restore());

  // Journey recovery: if the process died mid-journey, silently re-own it so
  // the traveller never has to notice. Short delay lets Firebase restore the
  // session first; if auth lands later anyway, the engine's keepalive beats
  // heal the journey on their own (interrupted → travelling).
  unawaited(Future.delayed(const Duration(seconds: 4), () async {
    await SupabaseAuthBridge.ensureSessionAsync();
    await JourneyEngine.instance.resumePersisted();
  }));

  // Load persisted theme before first frame — prevents any dark/light flicker.
  // Device Default resolves against the OS brightness the platform reports at
  // launch, so a system-themed user also gets the correct first frame.
  final prefs = await SharedPreferences.getInstance();
  final themePreference = await AppProvider.loadThemePreference(prefs);
  final isDark = themePreference.isDark(
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );

  // Decode the splash badge before the first frame. See LaunchSplash.warm.
  await LaunchSplash.warm();

  _applySystemOverlay(isDark);

  runApp(Help24App(initialTheme: themePreference));
}

/// The app's system-bar style, in one place.
///
/// Called from three points that must agree: `main()` before the first frame,
/// the theme builder when the user's choice changes, and [StartupGate] the
/// moment the splash hands over — because while the splash is up it declares
/// the bars itself (an [AnnotatedRegion] holding the brand field's light
/// icons), and this must not be issued underneath it.
void _applySystemOverlay(bool isDark) {
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    systemNavigationBarColor:
        isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
    systemNavigationBarIconBrightness:
        isDark ? Brightness.light : Brightness.dark,
  ));
}

class Help24App extends StatefulWidget {
  final ThemePreference initialTheme;

  const Help24App({super.key, this.initialTheme = ThemePreference.system});

  @override
  State<Help24App> createState() => _Help24AppState();
}

class _Help24AppState extends State<Help24App> with WidgetsBindingObserver {
  Future<void>? _bootstrapFuture;

  /// Observed so "Device Default" reacts the moment the OS flips (manual
  /// toggle or a scheduled night mode) — MaterialApp re-themes itself from
  /// ThemeMode.system, but the system UI overlay style below is ours to keep
  /// in sync.
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _runBackgroundBootstrap() async {
    try {
      // Client configuration, DISK ONLY at this point — the cached document (or
      // the compiled defaults on a fresh install) plus the running app version.
      // Awaited because two things read it before the first frame settles: the
      // hard-update gate in HomeScreen.build, and the kill switches. It is a
      // SharedPreferences read and a platform version lookup, so it costs a
      // frame at most and touches no network — the fetch happens after the
      // first frame (HomeScreen's post-frame callback) precisely so the launch
      // transaction keeps no network dependency.
      await RemoteConfigService.instance.warmUp();
      // Warm the category registry (cache-first, 24h TTL) so feed cards can
      // resolve highlight chips without opening the Post screen. Fire-and-
      // forget: never blocks startup, never throws.
      unawaited(CategorySchemaService.instance.warmUp());
      // Same contract for the profession registry: the profile's profession
      // selector, every profession chip and the become-a-provider gate all
      // read it synchronously and fall back to the bundled list, so this
      // warm-up is a freshness optimisation and never a dependency.
      unawaited(ProfessionRegistry.instance.warmUp());
      // And the location registry: the posting flow, the filters and the feed's
      // "near you" prioritisation all read it synchronously off the bundled
      // dataset, so this warm-up only ever upgrades what is already usable.
      unawaited(LocationRegistry.instance.warmUp());
      // ✅ Supabase is already initialized in main() - don't reinitialize!
      // Join the Firebase init started in main() (memoized — never runs twice).
      await AppFirebase.initialize();

      // Session hygiene, before any screen can read a cache. Destroys every
      // user-scoped key that does NOT belong to the restored session: data left
      // by a previous account, and the pre-scoping device-global keys that
      // caused the cross-account leak. Devices that ran the leaking build are
      // cleaned on their first launch after this update.
      // The in-memory mirror of the message cache is user-owned like the disk
      // entries it mirrors, so it must be reset at a session boundary too.
      SessionScope.instance.register(const MessageMemoScope());
      await SessionScope.instance.purgeForeignScopes(await _restoredUid());

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

  /// The uid of the session Firebase restored from disk, once it is KNOWN.
  ///
  /// `currentUser` is null for a short window after `initializeApp` while
  /// persistence is still being read, so asking it directly would sometimes
  /// report "signed out" for a user who is signed in — and the session sweep
  /// would then delete that user's own caches. `authStateChanges` emits exactly
  /// once persistence has settled, which is the signal we actually need.
  ///
  /// On timeout we fall back to `currentUser` rather than to null: guessing
  /// "signed out" is the answer that destroys data, so it is never the default.
  Future<String?> _restoredUid() async {
    if (!AppFirebase.isReady) return null;
    try {
      final user = await AuthService.authStateChanges.first
          .timeout(const Duration(seconds: 5));
      return user?.uid;
    } catch (_) {
      return AuthService.currentFirebaseUser?.uid;
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final chatId = (data['chatId'] ?? data['chat_id']) as String?;
    final type = (data['type'] as String?) ?? '';
    final postId = (data['post_id'] ?? data['postId']) as String?;

    // A push proves a row was written. Realtime normally delivers it too and the
    // store de-duplicates by id, so this costs nothing when both arrive — but a
    // dropped websocket would otherwise leave the badge stale until the next
    // resume, on exactly the notification the user was pushed about.
    if (type != 'chat_message') {
      unawaited(NotificationStore.instance.refresh());
    }

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
      // The navigator's OWN overlay — an ancestor lookup from
      // `currentContext` finds no Overlay and used to throw.
      overlay: _navigatorKey.currentState?.overlay,
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
        // Eager: the launch feed is loaded from this constructor, and holding
        // the splash for a provider that has not been built yet would mean
        // waiting out the whole deadline on every launch.
        ChangeNotifierProvider(
          lazy: false,
          create: (_) => AppProvider(initialTheme: widget.initialTheme),
        ),
        ChangeNotifierProvider(create: (_) => AuthProvider()..initialize()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (_) => LocationProvider()),
      ],
      child: _SyncOnReconnect(
        // Selector, not Consumer2. This builder owns the ENTIRE MaterialApp, and
        // AppProvider notifies on every search keystroke, every filter change,
        // every load transition and every feed install — so a Consumer rebuilt
        // the whole app tree dozens of times during a single launch, and
        // re-issued the system-overlay platform call each time. The bars
        // visibly fought the splash's own declaration as a result. Only the
        // theme choice can change anything here.
        //
        // LocaleProvider is deliberately not watched: AppLocalizationsLoader
        // watches it itself, which is the only place the language is read.
        child: Selector<AppProvider, ThemePreference>(
          selector: (_, appProvider) => appProvider.themePreference,
          builder: (context, themePreference, _) {
            // Resolved here rather than read from a boolean: under Device
            // Default the effective brightness comes from the platform, and
            // didChangePlatformBrightness above rebuilds this when it flips.
            final isDark = themePreference.isDark(
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
            );
            // Not while the splash owns the bars — StartupGate re-applies this
            // the moment it hands over.
            if (!LaunchSequence.isHoldingSplash) _applySystemOverlay(isDark);

            return AppLocalizationsLoader(
              child: MaterialApp(
                navigatorKey: _navigatorKey,
                scaffoldMessengerKey: _scaffoldMessengerKey,
                title: 'Help24',
                debugShowCheckedModeBanner: false,
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: themePreference.themeMode,
                locale: const Locale('en'),
                localizationsDelegates: const [appLocalizationsDelegate],
                supportedLocales: const [
                  Locale('en'),
                  Locale('sw'),
                ],
                // Offline is a background state, not global chrome: the subtle
                // indicator lives inside the home shell (below the OS status
                // bar), never as a full-app overlay. Pushed routes handle
                // offline contextually instead — silent auto-refresh on
                // reconnect (ReconnectListener), ErrorRetryView on a failed
                // load, and ErrorMapper's "You're offline" on actions.
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

/// Holds the branded splash over a LIVE app until the launch has settled.
///
/// WHY THE APP IS BUILT UNDERNEATH RATHER THAN AFTER
/// -------------------------------------------------
/// The obvious shape — render the splash, then swap in HomeScreen — is wrong in
/// a way that reintroduces the exact bug the splash exists to fix. HomeScreen
/// and Discover do real work in `initState` and their first post-frame
/// callback: the viewer identity is handed to the ranking engine, the urgent
/// list is loaded, and the sponsored slots are fetched. Deferring all of that
/// until after the swap means it lands ON a visible feed — and sponsored slots
/// in particular are INSERTED into the list ([FeedComposer]), so every card
/// below the first one shifts down a second after Discover appears. That is a
/// feed blink with a different cause and identical symptoms.
///
/// Building the app first and covering it with an opaque splash gives that work
/// the same free window every other launch path gets. What is revealed is
/// finished: ranked, composed, and not about to move.
///
/// The splash also FADES OUT over the app rather than the app fading in over
/// the splash. A crossfade blends two half-transparent layers, which on a light
/// theme washes the brand field through white and reads as a flash; fading one
/// opaque layer away just reveals what is behind it.
class _StartupGateState extends State<StartupGate> {
  /// Whether the launch has finished. Drives the splash's fade-out.
  ///
  /// Set exactly once. There is no path back: a launch happens per process, and
  /// re-entering it would mean putting the splash over a running app.
  bool _open = false;

  /// Whether the fade has finished and the splash can leave the tree entirely.
  bool _splashRetired = false;

  static const Duration _fade = Duration(milliseconds: 240);

  @override
  void initState() {
    super.initState();
    // If this appears twice in one launch trace, the splash is not "showing
    // twice" — the gate is being REBUILT FROM SCRATCH, which resets `_open`.
    debugPrint('[LAUNCH] +${LaunchSequence.sinceStart}ms StartupGate created');
    unawaited(
      (widget.bootstrapFuture ?? Future<void>.value()).then((_) async {
        if (!mounted) return;
        await context.read<AuthProvider>().initialize();
      }),
    );

    // THE LAUNCH CAN FINISH BEFORE THIS WIDGET EXISTS.
    //
    // The deadline is armed in main(), but nothing can be painted until Flutter
    // has built a tree — and on a slow device that is seconds, not frames. On a
    // Galaxy A21s the launch handed over at +3518ms and this widget was not
    // created until +4280ms. Painting a splash here would put a fresh brand
    // screen in front of somebody three quarters of a second AFTER the app was
    // ready, then fade it out again: literally a second splash.
    //
    // The Android window background has been showing the badge continuously the
    // whole time, so handing straight to the app is the seamless move — the
    // logo never leaves the screen, and the app simply appears under it.
    if (LaunchSequence.handedOver) {
      debugPrint('[LAUNCH] +${LaunchSequence.sinceStart}ms launch already over '
          '— handing straight to the app, no Flutter splash');
      _open = true;
      _splashRetired = true;
      LaunchSequence.lift();
      _applyThemedOverlay();
      return;
    }

    // Hold the splash until the feed is final, or the deadline expires —
    // whichever comes first. `ready` never completes with an error and is
    // always completed by the deadline, so this cannot strand the app.
    unawaited(LaunchSequence.ready.then((_) {
      if (!mounted) return;
      // ONE FRAME BETWEEN "THE FEED IS FINAL" AND "SHOW IT".
      //
      // The provider marks the launch final and then notifies, so the shell
      // rebuilds in the very next frame. Starting the fade in that same frame
      // would uncover a Discover in the middle of its own state transition —
      // the feed fading in over itself, which looks exactly like the blink this
      // whole mechanism exists to remove. Waiting for the frame to be painted
      // costs ~16ms and guarantees what is revealed is settled. (While the
      // launch is still marked as holding, that transition is instantaneous —
      // see DiscoverScreen._crossfade — so one frame really is enough.)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Announce the handover BEFORE the rebuild: a snapshot landing in the
        // same microtask must already be answering to FeedArrival rather than
        // to the "nothing is on screen" launch rule.
        LaunchSequence.lift();
        // The splash's AnnotatedRegion is about to go; the app's own bar style
        // has to replace it, or the bars keep the brand field's light icons
        // over a light-theme app.
        _applyThemedOverlay();
        setState(() => _open = true);
      });
    }));
  }

  /// Hand the system bars back to the app's own theme.
  void _applyThemedOverlay() {
    _applySystemOverlay(
      context.read<AppProvider>().themePreference.isDark(
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
          ),
    );
  }

  @override
  void dispose() {
    debugPrint('[LAUNCH] +${LaunchSequence.sinceStart}ms StartupGate DISPOSED '
        '(open=$_open) — anything after this is a second launch screen');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const HomeScreen(),
        if (!_splashRetired)
          // Absorbs taps for as long as it is opaque, so nothing can be
          // triggered through a screen the user cannot see.
          AbsorbPointer(
            absorbing: !_open,
            child: AnimatedOpacity(
              opacity: _open ? 0 : 1,
              duration: _fade,
              curve: Curves.easeOut,
              onEnd: () {
                if (_open && mounted) setState(() => _splashRetired = true);
              },
              child: const LaunchSplash(),
            ),
          ),
      ],
    );
  }
}

class _SyncOnReconnect extends StatefulWidget {
  final Widget child;

  const _SyncOnReconnect({required this.child});

  @override
  State<_SyncOnReconnect> createState() => _SyncOnReconnectState();
}

class _SyncOnReconnectState extends State<_SyncOnReconnect> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    // One subscription to the single reconnect edge source drives the app-wide
    // refresh of the AppProvider-backed datasets (posts, jobs, conversations).
    // Per-screen loaders subscribe to the same stream via ReconnectListener, so
    // there is exactly one definition of "reconnected" in the app.
    _sub = context.read<ConnectivityProvider>().onReconnect.listen((_) {
      if (!mounted) return;
      context
          .read<AppProvider>()
          .refreshAll(reason: FeedInvalidation.reconnected);
      final uid = context.read<AuthProvider>().currentUserId;
      if (uid != null && uid.isNotEmpty) {
        context.read<AppProvider>().loadConversations(uid);
        context.read<AppProvider>().loadMyApplications(uid);
        // The register re-syncs app-wide, not just when its screen is open —
        // the bell is visible on Discover, so an unread count that only caught
        // up after a visit to Notifications would be wrong everywhere else.
        // A refresh can only replace rows with newer ones; it never clears.
        unawaited(NotificationStore.instance.refresh());
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}