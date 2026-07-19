import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../models/provider_reputation.dart';
import '../widgets/reputation_widgets.dart';
import '../services/location_service.dart';
import '../services/reputation_service.dart';
import '../services/chat_local_prefs.dart';
import '../services/chat_service_supabase.dart';
import '../services/post_service.dart';
import '../services/cache_service.dart';
import '../services/supabase_auth_bridge.dart';
import '../services/storage_service.dart';
import 'post_detail_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/chat_ui.dart';
import '../widgets/location_experience.dart';
import '../services/journey_engine.dart';
import 'place_picker_screen.dart';
import 'journey_confirm_screen.dart';
import 'review_submission_screen.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  String get _currentUserId =>
      context.read<AuthProvider>().currentUserId ?? '';

  // Entrance animation plays once per session; the live-updating list must
  // not replay staggered fades on every poll/realtime refresh.
  bool _entranceAnimated = false;

  @override
  void initState() {
    super.initState();
    _loadConversationsWhenReady();
    // Local prefs (mute icons, cleared-conversation previews) load async at
    // startup; repaint once so the first frame after load reflects them.
    ChatLocalPrefs.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Start Supabase chat list stream for Messages tab (real-time).
  void _loadConversationsWhenReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final uid = context.read<AuthProvider>().currentUserId ?? '';
      if (uid.isNotEmpty) {
        context.read<AppProvider>().loadConversations(uid);
      }
    });
  }

  Future<void> _refreshConversations() async {
    final uid = _currentUserId;
    if (uid.isEmpty) return;
    await context.read<AppProvider>().loadConversations(uid);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Text(
              'Messages',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          Divider(
            height: 1,
            thickness: 0.5,
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          ),

          // Conversations List
          Expanded(
            child: Consumer2<AppProvider, ConnectivityProvider>(
              builder: (context, provider, connectivity, _) {
                final conversations = provider.conversations;

                if (provider.isLoadingConversations && conversations.isEmpty) {
                  return const ConversationSkeletonList();
                }

                if (conversations.isEmpty) {
                  // Offline with no cached conversations: show offline empty state.
                  if (connectivity.isOffline) {
                    return OfflineEmptyView(
                      message: 'No internet connection',
                      onRetry: () {
                        connectivity.checkNow();
                        _refreshConversations();
                      },
                    );
                  }
                  return EmptyStateView(
                    icon: Iconsax.message,
                    title: 'No messages yet',
                    subtitle: 'Start a conversation by contacting a poster. Pull to refresh.',
                    actions: [
                      TextButton.icon(
                        onPressed: _refreshConversations,
                        icon: const Icon(Icons.refresh, size: 20),
                        label: const Text('Refresh'),
                      ),
                    ],
                  );
                }

                final hasMore = provider.hasMoreConversations;
                return RefreshIndicator(
                  onRefresh: _refreshConversations,
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: conversations.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (hasMore && index == conversations.length) {
                        final loadingMore = provider.loadingMoreConversations;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: loadingMore
                                ? const SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : TextButton.icon(
                                    onPressed: () => provider.loadMoreConversations(
                                      context.read<AuthProvider>().currentUserId ?? '',
                                    ),
                                    icon: const Icon(Iconsax.refresh, size: 18),
                                    label: const Text('Load more conversations'),
                                  ),
                          ),
                        );
                      }
                      final conversation = conversations[index];
                      final uid = context.read<AuthProvider>().currentUserId ?? '';
                      final tile = _ConversationTile(
                        key: ValueKey(conversation.id),
                        conversation: conversation,
                        onTap: () async {
                          final result = await Navigator.push<Conversation>(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChatScreen(
                                conversation: conversation,
                                currentUserId: uid,
                              ),
                            ),
                          );
                          if (result != null) {
                            provider.updateConversation(result);
                          }
                        },
                      );
                      if (_entranceAnimated) return tile;
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _entranceAnimated = true);
                      return tile.animate().fadeIn(
                        duration: 300.ms,
                        delay: Duration(milliseconds: (index * 50).clamp(0, 400)),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    // Instant-based: correct for any UTC-normalised timestamp regardless of zone.
    final diff = now.difference(time.toLocal());

    if (diff.isNegative || diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      // e.g. "Apr 3" — unambiguous, never looks like a fraction
      return '${_months[time.month]} ${time.day}';
    }
  }

  Widget _avatarPlaceholder(String initial) {
    return CircleAvatar(
      radius: 26,
      backgroundColor: AppTheme.primaryAccent,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatarUrl = conversation.userAvatar;
    final initial = conversation.userName.isNotEmpty
        ? conversation.userName.substring(0, 1).toUpperCase()
        : '?';
    // Device-local "clear conversation": when everything up to the last
    // message was cleared, the tile must not keep echoing the server-side
    // preview. A newer message than the watermark restores normal display.
    final cleared = ChatLocalPrefs.clearedBeforeSync(conversation.id);
    final isCleared =
        cleared != null && !conversation.lastMessageTime.isAfter(cleared);
    final showUnread = conversation.unreadCount > 0 && !isCleared;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  // Circular avatar
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: avatarUrl.isNotEmpty
                        ? CircleAvatar(
                            radius: 26,
                            backgroundColor: AppTheme.primaryAccent,
                            child: ClipOval(
                              // Never a visible load: cached images paint the
                              // same frame (zero fade), uncached ones sit on
                              // the initial-letter avatar — no spinner ever.
                              child: CachedNetworkImage(
                                imageUrl: avatarUrl,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                fadeInDuration: Duration.zero,
                                fadeOutDuration: Duration.zero,
                                placeholderFadeInDuration: Duration.zero,
                                placeholder: (_, __) => _avatarPlaceholder(initial),
                                errorWidget: (_, __, ___) => _avatarPlaceholder(initial),
                              ),
                            ),
                          )
                        : _avatarPlaceholder(initial),
                  ),
                  const SizedBox(width: 14),
                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                conversation.userName,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (ChatLocalPrefs.isMutedSync(conversation.id)) ...[
                              Icon(
                                Icons.notifications_off_rounded,
                                size: 13,
                                color: isDark
                                    ? AppTheme.darkTextTertiary
                                    : AppTheme.lightTextTertiary,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              _formatTime(conversation.lastMessageTime),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                color: showUnread ? AppTheme.primaryAccent : null,
                                fontWeight:
                                    showUnread ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                isCleared
                                    ? 'No messages'
                                    : conversation.lastMessage.isNotEmpty
                                        ? conversation.lastMessage
                                        : 'No messages yet',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: showUnread
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontStyle:
                                      isCleared ? FontStyle.italic : FontStyle.normal,
                                  color: showUnread
                                      ? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary)
                                      : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (showUnread) ...[
                              const SizedBox(width: 8),
                              Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryAccent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  conversation.unreadCount.toString(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ],
                        ),
                        // Post context — always visible when available
                        if (conversation.postTitle != null && conversation.postTitle!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.push_pin_rounded,
                                size: 12,
                                color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  conversation.postTitle!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 0.5,
          indent: 82,
          endIndent: 0,
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ],
    );
  }
}

/// Max height for chat input (~5 lines) so it scrolls internally beyond that.
const double _kChatInputMaxHeight = 156.0;

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final String currentUserId;

  const ChatScreen({
    super.key,
    required this.conversation,
    required this.currentUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<Message> _pendingMessages = []; // Optimistic until send completes
  List<Message> _messages = [];
  bool _loadingMessages = true;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;
  // Realtime subscription for instant message delivery.
  StreamSubscription<List<Message>>? _realtimeSubscription;
  // Chats-row realtime channel: typing indicator without polling. Requires
  // migration 083 (chats in the realtime publication); until then the poll
  // below stays as the fallback.
  RealtimeChannel? _chatRowChannel;
  Timer? _typingExpireTimer;
  // Fallback typing poll — retired the moment the realtime channel proves
  // alive (first chats-row event).
  Timer? _typingPollTimer;
  // Debounced thread-cache persistence (one disk write per burst, not per
  // message), capped to the newest messages.
  Timer? _cacheSaveDebounce;
  List<Message>? _pendingCacheSave;
  bool _isSending = false;
  int _lastMessageCount = 0;

  // ── Journey Engine (Phase 2) ──
  // The screen owns NO journey state: no timers, no position subscriptions,
  // no message-id booleans. JourneyEngine is the single app-level owner; this
  // screen renders its snapshot and forwards user intent. That is what lets a
  // journey survive navigating away, activity recreation and app restart.
  /// True when the thread has nothing to show AND the load failed — lets the
  /// empty state tell the truth ("couldn't load") instead of claiming the
  /// conversation is empty.
  bool _loadFailed = false;
  JourneySnapshot _journey = JourneyEngine.instance.snapshot;
  StreamSubscription<JourneyEvent>? _journeyEvents;
  // Rebuild filter: engine snapshots change on every GPS fix; only state /
  // ownership / coarse distance changes are visually relevant here.
  String _journeyUiKey = '';
  // Post behind this chat — fetched lazily (first location intent) for the
  // journey destination, picker centering and role-aware intent ordering.
  PostModel? _chatPost;
  Future<void>? _chatPostFetch;
  // Viewer's last-known position for card distance labels. Primed silently —
  // rendering must never trigger a permission dialog.
  double? _myLat, _myLng;
  // Ticks only to expire journey UI (strip/cards) when no realtime event fires.
  Timer? _journeyUiTimer;

  // Typing indicator state
  bool _otherIsTyping = false;
  Timer? _typingDebounce;
  Timer? _typingClearTimer;

  // Online status (shown in AppBar subtitle)
  String _onlineStatus = '';
  Timer? _onlineStatusTimer;

  // Backend-sourced trust signal for the header (rating + verified tick).
  // Seeded synchronously from ReputationService's cache; refreshed once.
  ProviderReputation? _headerRep;
  static const _trustedTiers = {
    'top_rated',
    'highly_recommended',
    'trusted_professional',
  };

  // Scroll-to-bottom FAB. In the reversed list "bottom" = offset 0.
  bool _isNearBottom = true;

  // Non-null while user has selected a message to reply to.
  Message? _replyToMessage;

  // Device-local view state: individually hidden messages ("delete for me")
  // and the clear-conversation watermark. Applied as a build-time filter so
  // it is immune to cache/realtime arrival order.
  Set<String> _hiddenIds = {};
  DateTime? _clearedBefore;
  bool _isMuted = false;

  // Maps stable item keys → reversed ListView indices. Rebuilt each build;
  // consumed by findChildIndexCallback (element reuse on insert) and by
  // _scrollToMessage (reply-quote jumps).
  final Map<String, int> _itemIndexByKey = {};

  // Mutable chat ID — empty string = pending (no DB row yet).
  // Populated on first message send via _ensureChatCreated().
  late String _activeChatId;

  String get _chatId => _activeChatId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeChatId = widget.conversation.id;
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTypingChanged);
    if (_chatId.isNotEmpty) {
      _loadLocalPrefs();
      // Existing chat: paint the cached thread instantly (no spinner), then
      // let realtime replace it silently with fresh data.
      _hydrateFromCache();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppProvider>().setActiveChatId(_chatId);
      });
      _startRealtimeMessages();
      _startChatRowRealtime();
      _typingPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _checkTyping();
      });
      _markSeenNow();
    } else {
      // Pending chat: show empty state, no realtime until first send.
      _loadingMessages = false;
    }
    // Presence seeded from the conversation list (already fetched there);
    // refreshed live while the chat is open.
    _seedOnlineStatusFromConversation();
    _loadOnlineStatus();
    _onlineStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadOnlineStatus();
    });
    // Trust signal for the header. ReputationService caches with TTL and
    // deduplicates in-flight requests, so this is at most one network call.
    final participantId = widget.conversation.participantId;
    if (participantId.isNotEmpty) {
      _headerRep = ReputationService.getCachedSync(participantId);
      ReputationService.getReputation(participantId).then((rep) {
        if (mounted && rep != null) setState(() => _headerRep = rep);
      });
    }
    // Location Experience: prime the viewer position for distance labels and
    // keep journey UI (strip, LIVE states) honest when no realtime event lands.
    _primeViewerPosition();
    // Post context up-front (one deduped fetch): powers the context action
    // (roles), journey destination and picker centering from the first frame.
    _ensureChatPost();
    // 20s so watcher freshness ("Updated Xs ago") and the reconnecting phase
    // appear within a reasonable window of the 75s staleness threshold.
    _journeyUiTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _messages.any((m) => m.isLiveLocation)) setState(() {});
    });
    // Journey Engine: render its lifecycle and react to its one-shot events.
    JourneyEngine.instance.listenable.addListener(_onJourneyChanged);
    _onJourneyChanged();
    _journeyEvents = JourneyEngine.instance.events.listen(_onJourneyEvent);
  }

  /// Engine → UI. Fixes arrive every ~8s; rebuild only when something the
  /// user can see changed (state, owned row, or ~25 m of progress).
  void _onJourneyChanged() {
    final s = JourneyEngine.instance.snapshot;
    _journey = s;
    final key = '${s.state.name}:${s.messageId ?? ''}:'
        '${s.distanceToDestinationM == null ? '' : (s.distanceToDestinationM! / 25).round()}';
    if (key == _journeyUiKey) return;
    _journeyUiKey = key;
    if (mounted) setState(() {});
  }

  void _onJourneyEvent(JourneyEvent event) {
    if (!mounted) return;
    switch (event) {
      case JourneyEvent.autoArrived:
        // Same human close as manual arrival — offer the heads-up. Only when
        // this chat is the journey's chat (engine outlives navigation).
        if (_journey.chatId == _chatId || _journey.chatId == null) {
          _offerArrivalNotify();
        }
        break;
      case JourneyEvent.manualArrived:
        break; // dialog is offered inline by _markArrived
      case JourneyEvent.capExpired:
      case JourneyEvent.failedPermanently:
        break; // strip/card copy already explains; no modal interruptions
    }
  }

  /// Android may tear the Realtime websocket down while backgrounded without
  /// the client seeing a close event. Rebuilding the subscription on resume
  /// re-joins the channels and runs one catch-up fetch, so anything that landed
  /// while we were away appears immediately. Lifecycle edge only — not a poll.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    if (!mounted || _chatId.isEmpty) return;
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _startRealtimeMessages();
    _markSeenNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear active chat so notifications resume for other chats.
    context.read<AppProvider>().setActiveChatId(null);
    _realtimeSubscription?.cancel();
    _chatRowChannel?.unsubscribe();
    _typingExpireTimer?.cancel();
    _typingPollTimer?.cancel();
    _typingDebounce?.cancel();
    _typingClearTimer?.cancel();
    _onlineStatusTimer?.cancel();
    // Deliberately NOT stopping the journey: it belongs to the engine and
    // keeps sharing while the user navigates elsewhere in the app.
    JourneyEngine.instance.listenable.removeListener(_onJourneyChanged);
    _journeyEvents?.cancel();
    _journeyUiTimer?.cancel();
    // Flush any pending thread-cache write so the last messages of the
    // session are on disk for the next instant open.
    _cacheSaveDebounce?.cancel();
    final pendingSave = _pendingCacheSave;
    if (pendingSave != null) {
      CacheService.saveMessages(_chatId, _capForCache(pendingSave));
    }
    _scrollController.removeListener(_onScroll);
    _messageController.removeListener(_onTypingChanged);
    ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Loads device-local view prefs (hidden messages, clear watermark, mute).
  /// Applied as a build-time filter, so arrival order vs. cache/realtime
  /// doesn't matter.
  Future<void> _loadLocalPrefs() async {
    await ChatLocalPrefs.ensureLoaded();
    final hidden = await ChatLocalPrefs.hiddenMessageIds(_chatId);
    final cleared = await ChatLocalPrefs.clearedBefore(_chatId);
    if (!mounted) return;
    setState(() {
      _hiddenIds = hidden;
      _clearedBefore = cleared;
      _isMuted = ChatLocalPrefs.isMutedSync(_chatId);
    });
  }

  /// Device-local visibility: hides "deleted for me" messages and anything
  /// at/before the clear-conversation watermark.
  bool _isLocallyVisible(Message m) {
    if (_hiddenIds.contains(m.id)) return false;
    final cleared = _clearedBefore;
    if (cleared != null && !m.timestamp.isAfter(cleared)) return false;
    return true;
  }

  /// Instant open: hydrate the thread from the on-device cache written by
  /// previous sessions. Runs before the realtime initial page returns; if
  /// realtime wins the race its fresher data is kept.
  Future<void> _hydrateFromCache() async {
    final cached = await CacheService.loadMessages(_chatId, widget.currentUserId);
    if (!mounted || cached.isEmpty) return;
    if (_messages.isNotEmpty) return; // realtime already delivered
    setState(() {
      _messages = cached;
      _loadingMessages = false;
      _hasMoreOlder = cached.length >= 30;
    });
  }

  /// Subscribe to Supabase Realtime for this chat. Messages arrive instantly.
  /// Idempotent: three paths can reach here (initState, app resume, lazy chat
  /// creation on first send). Without dropping the previous subscription each
  /// call opened another pair of channels, so every message was delivered once
  /// per live stream — harmless visually (upsert dedupes by id) but a real
  /// socket/CPU leak that grows with each resume.
  void _startRealtimeMessages() {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = ChatServiceSupabase.watchMessages(
      _chatId,
      widget.currentUserId,
    ).listen((messages) {
      if (!mounted) return;
      // Merge with older messages already on screen — from pagination or from
      // the cache hydration — so the visible history never shrinks to the
      // realtime window size.
      final List<Message> merged;
      if (messages.isNotEmpty && _messages.isNotEmpty) {
        final pageOldest = messages.first.timestamp;
        final seen = messages.map((m) => m.id).toSet();
        final older = _messages
            .where((m) => m.timestamp.isBefore(pageOldest) && !seen.contains(m.id))
            .toList();
        merged = older + messages;
      } else {
        merged = messages;
      }
      final hadNew = messages.length > _lastMessageCount;
      setState(() {
        _messages = merged;
        _loadingMessages = false;
        _loadFailed = false; // a successful emission clears any prior failure
        _hasMoreOlder = messages.length >= 30;
      });
      // Re-adopt an orphaned journey: if this device's user has a live share
      // but this screen instance isn't streaming (chat was closed/reopened,
      // app restarted), take ownership again so position updates resume and
      // Stop / I've arrived stay available. Without this the share would idle
      // frozen until the safety cap.
      _readoptOwnLiveJourney();
      // Watcher-side signal freshness for "Updated Xs ago" honesty copy.
      _trackJourneyFreshness(merged);
      if (messages.isNotEmpty) {
        _scheduleCacheSave(merged);
      }
      if (_lastMessageCount == 0) {
        // Initial page. The reversed list is already anchored on the newest
        // message — no scroll command needed.
        _lastMessageCount = messages.length;
        _markSeenNow();
      } else if (hadNew) {
        _lastMessageCount = messages.length;
        // Follow along only when the user is already near the bottom — don't
        // hijack their position while they read older messages.
        if (_isNearBottom) _scrollToBottom();
        _markSeenNow();
      }
    }, onError: (e) {
      debugPrint('ChatScreen Realtime error: $e');
      if (mounted) {
        setState(() {
          _loadingMessages = false;
          // Only reachable with nothing on screen (the service suppresses this
          // when messages are already rendered), so the thread can say what is
          // actually true: we could not load, rather than "no messages yet".
          _loadFailed = true;
        });
      }
    });
  }

  /// Realtime on this chat's `chats` row: typing_user_id/typing_at updates
  /// arrive instantly instead of via the 3s poll. The first event proves the
  /// channel works and retires the poll. Needs migration 083; without it no
  /// events fire and the poll keeps running — zero regression.
  void _startChatRowRealtime() {
    if (_chatId.isEmpty || _chatRowChannel != null) return;
    _chatRowChannel = Supabase.instance.client
        .channel('chat_row:$_chatId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: _chatId,
          ),
          callback: (payload) {
            if (!mounted) return;
            _typingPollTimer?.cancel();
            _typingPollTimer = null;
            final row = payload.newRecord;
            final typingUser = row['typing_user_id']?.toString();
            final typingAt = row['typing_at'] != null
                ? DateTime.tryParse(row['typing_at'].toString())
                : null;
            final isTyping = typingUser != null &&
                typingUser.isNotEmpty &&
                typingUser != widget.currentUserId &&
                typingAt != null &&
                DateTime.now().difference(typingAt.toLocal()).inSeconds < 6;
            if (isTyping != _otherIsTyping) {
              setState(() => _otherIsTyping = isTyping);
            }
            // Safety expiry in case the clear-typing write never lands.
            _typingExpireTimer?.cancel();
            if (isTyping) {
              _typingExpireTimer = Timer(const Duration(seconds: 5), () {
                if (mounted && _otherIsTyping) {
                  setState(() => _otherIsTyping = false);
                }
              });
            }
          },
        )
      ..subscribe();
  }

  /// Cap the cached thread: 60 newest messages cover instant-open plus a page
  /// of scrollback without unbounded SharedPreferences growth.
  static List<Message> _capForCache(List<Message> messages) =>
      messages.length > 60 ? messages.sublist(messages.length - 60) : messages;

  /// One disk write per 2s burst instead of a full JSON re-encode per message.
  void _scheduleCacheSave(List<Message> merged) {
    _pendingCacheSave = merged;
    _cacheSaveDebounce ??= Timer(const Duration(seconds: 2), () {
      _cacheSaveDebounce = null;
      final messages = _pendingCacheSave;
      _pendingCacheSave = null;
      if (messages != null && messages.isNotEmpty) {
        CacheService.saveMessages(_chatId, _capForCache(messages));
      }
    });
  }

  /// Presence carried by the conversation row paints the header immediately;
  /// _loadOnlineStatus refreshes it from the live users row moments later.
  void _seedOnlineStatusFromConversation() {
    if (widget.conversation.isOnline) {
      _onlineStatus = 'online';
    } else if (widget.conversation.lastSeen != null) {
      _onlineStatus = _lastSeenLabel(widget.conversation.lastSeen!.toLocal());
    }
  }

  /// A peer counts as "online" only while its presence heartbeat is newer than
  /// this. Must exceed the writer's heartbeat interval (60s) with margin for a
  /// missed beat and clock skew.
  static const Duration _presenceStaleAfter = Duration(seconds: 150);

  static String _lastSeenLabel(DateTime lastSeen) {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inMinutes < 2) return 'last seen just now';
    if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes} min ago';
    if (diff.inHours < 24) return 'last seen ${diff.inHours}h ago';
    return 'last seen ${diff.inDays}d ago';
  }

  Future<void> _markSeenNow() async {
    await ChatServiceSupabase.markMessagesSeen(_chatId, widget.currentUserId);
    // Zero out the local unread badge immediately without waiting for the
    // next conversation list poll.
    if (mounted) {
      context.read<AppProvider>().markConversationRead(_chatId);
    }
  }

  Future<void> _checkTyping() async {
    if (_chatId.isEmpty) return;
    try {
      final typing = await ChatServiceSupabase.isOtherUserTyping(_chatId, widget.currentUserId);
      if (mounted && typing != _otherIsTyping) {
        setState(() => _otherIsTyping = typing);
      }
    } catch (_) {}
  }

  Future<void> _loadOnlineStatus() async {
    final participantId = widget.conversation.participantId;
    if (participantId.isEmpty) return;
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('is_online, last_seen')
          .eq('id', participantId)
          .maybeSingle();
      if (!mounted || row == null) return;
      final flaggedOnline = row['is_online'] as bool? ?? false;
      final lastSeen = parseServerTimeOrNull(row['last_seen']);
      // `is_online` alone cannot be trusted: it is a flag the other device
      // wrote, and a crash / force-stop / lost network leaves it stuck true
      // forever. Treat it as authoritative only while the heartbeat behind it
      // is fresh, otherwise fall back to the last-seen label. Presence is
      // derived from observed liveness, never from a stale boolean.
      final heartbeatFresh = lastSeen != null &&
          DateTime.now().toUtc().difference(lastSeen.toUtc()) < _presenceStaleAfter;
      String label = '';
      if (flaggedOnline && heartbeatFresh) {
        label = 'online';
      } else if (lastSeen != null) {
        label = _lastSeenLabel(lastSeen.toLocal());
      }
      // Only rebuild when the label actually changed — this runs on a timer
      // and a no-op setState would rebuild the whole screen every 30s.
      if (label != _onlineStatus) {
        setState(() => _onlineStatus = label);
      }
    } catch (_) {}
  }

  /// Header subtitle: typing state wins, then presence · rating.
  /// Typing lives here (not as a bubble above the composer) so it never
  /// shifts the message list.
  Widget _buildHeaderSubtitle(bool isDark) {
    if (_otherIsTyping) {
      return const Text(
        'typing…',
        key: ValueKey('typing'),
        maxLines: 1,
        style: TextStyle(
          fontSize: 12,
          color: AppTheme.primaryAccent,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final online = _onlineStatus == 'online';
    final rep = _headerRep;
    final hasRating = rep != null && rep.hasReviews;
    if (_onlineStatus.isEmpty && !hasRating) {
      return const SizedBox.shrink(key: ValueKey('empty'));
    }
    return Row(
      key: ValueKey('status:$_onlineStatus:${hasRating ? rep.averageRating : ''}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_onlineStatus.isNotEmpty)
          Flexible(
            child: Text(
              _onlineStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: online ? AppTheme.successGreen : tertiary,
                fontWeight: online ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        if (_onlineStatus.isNotEmpty && hasRating)
          Text('  ·  ', style: TextStyle(fontSize: 12, color: tertiary)),
        if (hasRating) ...[
          const Icon(Icons.star_rounded, size: 13, color: AppTheme.warningOrange),
          const SizedBox(width: 2),
          Text(
            rep.averageRating.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 12,
              color: secondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  void _onTypingChanged() {
    final hasText = _messageController.text.isNotEmpty;
    if (!hasText) {
      _typingDebounce?.cancel();
      _typingClearTimer?.cancel();
      ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);
      return;
    }
    // Debounce: only write to DB after 800 ms of no new keystrokes.
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted && _messageController.text.isNotEmpty) {
        ChatServiceSupabase.setTyping(_chatId, widget.currentUserId);
      }
    });
    // Auto-clear 4 s after last keystroke (server-side expiry guard).
    _typingClearTimer?.cancel();
    _typingClearTimer = Timer(const Duration(seconds: 4), () {
      ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);
    });
  }

  /// Load older messages (cursor-based). Prepends to _messages.
  Future<void> _loadOlderMessages() async {
    if (_chatId.isEmpty || _loadingOlder || !_hasMoreOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    final before = _messages.first.timestamp.toUtc().toIso8601String();
    try {
      final result = await ChatServiceSupabase.getMessagesPage(
        _chatId,
        widget.currentUserId,
        before: before,
      );
      if (!mounted) return;
      final existingIds = _messages.map((m) => m.id).toSet();
      final newOlder = result.messages.where((m) => !existingIds.contains(m.id)).toList();
      setState(() {
        _messages = newOlder + _messages;
        _hasMoreOlder = result.hasMore;
        _loadingOlder = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _onScroll() {
    final position = _scrollController.position;
    // Reversed list: offset 0 is the newest message; maxScrollExtent is the
    // oldest loaded one. Nearing the far end = time to page in older history.
    // Prepended pages append beyond the far edge, so loading older messages
    // can never shift what the user is currently reading.
    if (position.pixels > position.maxScrollExtent - 400 && _hasMoreOlder && !_loadingOlder) {
      _loadOlderMessages();
    }
    final nearBottom = position.pixels < 200;
    if (nearBottom != _isNearBottom) {
      setState(() => _isNearBottom = nearBottom);
    }
  }

  /// In the reversed list the newest message sits at offset 0 — the list
  /// OPENS there by construction (no scroll command, no layout race, no
  /// image-height dependence). This helper only exists for follow-along on
  /// new arrivals and the scroll-to-bottom button.
  void _scrollToBottom({bool instant = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (instant) {
        _scrollController.jumpTo(0);
      } else {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.errorRed,
      ),
    );
  }

  /// Creates the chat DB row on first send (lazy creation).
  /// Returns true when _chatId is ready to use, false on failure.
  Future<bool> _ensureChatCreated() async {
    if (_chatId.isNotEmpty) return true;
    final user2Id = widget.conversation.participantId;
    if (user2Id.isEmpty) return false;
    try {
      await SupabaseAuthBridge.ensureSessionForWriteAsync();
      final conv = await ChatServiceSupabase.createChat(
        user1Id: widget.currentUserId,
        user2Id: user2Id,
        currentUserId: widget.currentUserId,
        postId: widget.conversation.postId,
      );
      if (!mounted) return false;
      setState(() => _activeChatId = conv.id);
      // Start realtime and typing now that the chat exists.
      _startRealtimeMessages();
      _startChatRowRealtime();
      _typingPollTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _checkTyping();
      });
      context.read<AppProvider>()
        ..setActiveChatId(_chatId)
        ..updateConversation(conv);
      return true;
    } catch (e) {
      debugPrint('ChatScreen _ensureChatCreated: $e');
      return false;
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    // Create the chat row on first send if we're in pending mode.
    if (!await _ensureChatCreated()) {
      if (mounted) _showError('Could not start chat. Please try again.');
      return;
    }

    _messageController.clear();
    // Capture reply state before clearing it (cleared after optimistic insert).
    final replyingTo = _replyToMessage;
    // Cancel pending typing timers and clear flag immediately on send.
    _typingDebounce?.cancel();
    _typingClearTimer?.cancel();
    ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);

    final optimistic = Message(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: _chatId,
      senderId: widget.currentUserId,
      receiverId: '',
      text: text,
      timestamp: DateTime.now(),
      isMe: true,
      type: 'text',
      replyToId: replyingTo?.id,
      replyToSender: replyingTo == null
          ? null
          : (replyingTo.isMe ? 'You' : widget.conversation.userName),
      replyToPreview: replyingTo?.text.isEmpty == false
          ? replyingTo!.text.substring(0, replyingTo.text.length.clamp(0, 120))
          : null,
    );
    setState(() {
      _pendingMessages.add(optimistic);
      _replyToMessage = null; // clear reply preview immediately on send
    });
    _scrollToBottom();
    try {
      await SupabaseAuthBridge.ensureSessionAsync();
      final confirmed = await ChatServiceSupabase.sendMessage(
        chatIdParam: _chatId,
        senderId: widget.currentUserId,
        content: text,
        replyToId:      replyingTo?.id,
        replyToSender:  replyingTo == null
            ? null
            : (replyingTo.isMe ? 'You' : widget.conversation.userName),
        replyToPreview: replyingTo?.text.isEmpty == false
            ? replyingTo!.text.substring(0, replyingTo.text.length.clamp(0, 120))
            : null,
      );
      if (mounted) {
        setState(() {
          _pendingMessages.removeWhere((m) => m.id == optimistic.id);
          // Add the confirmed row directly — don't rely on realtime for own messages.
          if (!_messages.any((m) => m.id == confirmed.id)) {
            _messages = [..._messages, confirmed];
          }
        });
        _scrollToBottom();
      }
    } catch (e) {
      String errorDetail;
      if (e is PostgrestException) {
        // Supabase DB error — surface code + message for debugging.
        errorDetail = 'DB error ${e.code ?? "?"}: ${e.message}';
        debugPrint('[CHAT][ERROR] type=postgrest code=${e.code} detail=${e.details} hint=${e.hint} message=${e.message}');
      } else if (e.toString().toLowerCase().contains('socketexception') ||
                 e.toString().toLowerCase().contains('network') ||
                 e.toString().toLowerCase().contains('connection')) {
        errorDetail = 'Network error — check your connection.';
        debugPrint('[CHAT][ERROR] type=network detail=$e');
      } else {
        errorDetail = e.toString();
        debugPrint('[CHAT][ERROR] type=unknown detail=$e');
      }
      if (mounted) {
        setState(() => _pendingMessages.removeWhere((m) => m.id == optimistic.id));
        _messageController.text = text;
        _showError('Failed to send: $errorDetail');
      }
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_isSending) return;
    if (!await _ensureChatCreated()) {
      if (mounted) _showError('Could not start chat. Please try again.');
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
      if (xFile == null || !mounted) return;
      setState(() => _isSending = true);
      final url = await StorageService.uploadChatAttachment(xFile, _chatId);
      if (!mounted) return;
      await ChatServiceSupabase.sendAttachmentMessage(
        chatIdParam: _chatId,
        senderId: widget.currentUserId,
        type: 'image',
        attachmentUrl: url,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Failed to send image.');
      }
    }
  }

  Future<void> _pickAndSendFile() async {
    if (_isSending) return;
    if (!await _ensureChatCreated()) {
      if (mounted) _showError('Could not start chat. Please try again.');
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx'],
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final platformFile = result.files.single;
      final path = platformFile.path;
      if (path == null || path.isEmpty) {
        _showError('Could not access file.');
        return;
      }
      setState(() => _isSending = true);
      final xFile = XFile(path);
      final url = await StorageService.uploadChatAttachment(xFile, _chatId);
      if (!mounted) return;
      await ChatServiceSupabase.sendAttachmentMessage(
        chatIdParam: _chatId,
        senderId: widget.currentUserId,
        type: 'file',
        attachmentUrl: url,
        caption: platformFile.name,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Failed to send file.');
      }
    }
  }

  /// Single attach entry point: photo, document and location all live here
  /// (the composer keeps one button instead of two).
  void _showAttachmentOptions() {
    if (_isSending) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Text(
                  'Share something',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              _AttachOption(
                icon: Iconsax.gallery,
                color: AppTheme.primaryAccent,
                title: 'Photo',
                subtitle: 'From your gallery',
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendImage();
                },
              ),
              _AttachOption(
                icon: Iconsax.document,
                color: AppTheme.secondaryAccent,
                title: 'Document',
                subtitle: 'PDF, Word or CV',
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendFile();
                },
              ),
              _AttachOption(
                icon: Iconsax.location,
                color: AppTheme.successGreen,
                title: 'Location',
                subtitle: 'Share or request location',
                onTap: () {
                  Navigator.pop(context);
                  _openLocationIntents();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Location Experience (Phase 1) ─────────────────────────────────────────
  // Three user intents (On my way / Send a place / Request location) replace
  // the old current-vs-live + duration taxonomy. Durations are never asked:
  // journeys end manually ("I've arrived" / Stop) under a silent safety cap.

  /// The newest still-live journey in this thread (either side), if any.
  Message? get _activeJourney {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.isLiveNow && _isLocallyVisible(m)) return m;
    }
    return null;
  }

  /// The journey the header strip narrates: a live one, or — for a graceful
  /// close — the newest ARRIVED journey for ~60s after it concluded, so both
  /// sides watch the strip evolve "on the way → arrived" before it leaves.
  Message? get _stripJourney {
    final live = _activeJourney;
    if (live != null) return live;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.isLiveLocation || !_isLocallyVisible(m)) continue;
      if (m.isJourneyArrived && m.liveUntil != null &&
          DateTime.now().difference(m.liveUntil!) < const Duration(seconds: 60)) {
        return m;
      }
      return null; // newest journey is ended/stale — no strip
    }
    return null;
  }

  /// When the last realtime update for each live journey landed on THIS
  /// device — watcher-side signal honesty ("Updated 2m ago"). Keyed by
  /// message id; fingerprint dedupes non-position emissions.
  final Map<String, DateTime> _journeyEventAt = {};
  final Map<String, String> _journeyEventFingerprint = {};

  void _trackJourneyFreshness(List<Message> messages) {
    for (final m in messages) {
      if (!m.isLiveLocation || m.isMe || !m.isLiveNow) continue;
      final fp = '${m.latitude}:${m.longitude}:${m.liveUntil}:${m.text}';
      if (_journeyEventFingerprint[m.id] != fp) {
        _journeyEventFingerprint[m.id] = fp;
        _journeyEventAt[m.id] = DateTime.now();
      }
    }
  }

  /// The other side asked for a location and no place has been sent since —
  /// their request is still standing.
  bool get _hasOpenLocationRequest {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!_isLocallyVisible(m)) continue;
      if (m.type == 'location' && m.isMe) return false; // answered
      if (m.isLocationRequest && !m.isMe) return true; // still open
    }
    return false;
  }

  /// The newest journey concluded as ARRIVED within the last 10 minutes —
  /// the natural moment to close the loop (rate the provider).
  bool get _recentlyArrivedJourney {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.isLiveLocation || !_isLocallyVisible(m)) continue;
      return m.isJourneyArrived &&
          m.liveUntil != null &&
          DateTime.now().difference(m.liveUntil!) < const Duration(minutes: 10);
    }
    return false;
  }

  /// Lifecycle-driven quick action (at most one; null = no bar). Priority:
  /// answer an open request > start the journey you're expected to make >
  /// rate the provider after arrival. "Stop sharing" intentionally lives in
  /// the journey strip — never duplicated here.
  ({IconData icon, String label, VoidCallback onTap})? _contextAction() {
    if (_isSending) return null;
    // 1) They asked "where exactly?" — answering beats everything else.
    if (_hasOpenLocationRequest) {
      return (
        icon: Iconsax.location,
        label: 'Share location',
        onTap: _respondToLocationRequest,
      );
    }
    // While a journey is live the strip owns the journey controls.
    if (_activeJourney != null || _journey.isLive) return null;
    // 2) I'm the traveller for this job and the trip hasn't started.
    if (_chatPost != null && _travellerFirst) {
      return (
        icon: Iconsax.routing_2,
        label: 'On my way',
        onTap: _startJourneyFlow,
      );
    }
    // 3) The provider just arrived and I'm the customer: close the loop.
    // ReviewService/backend stays the gatekeeper of review validity.
    final postId = widget.conversation.postId;
    if (_chatPost != null &&
        !_travellerFirst &&
        postId != null &&
        postId.isNotEmpty &&
        _recentlyArrivedJourney) {
      return (
        icon: Icons.star_rounded,
        label: 'Rate ${widget.conversation.userName}',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ReviewSubmissionScreen(
                postId: postId,
                clientUserId: widget.currentUserId,
                postTitle: widget.conversation.postTitle,
              ),
            ),
          );
        },
      );
    }
    return null;
  }

  /// One phase computation for strip and card. The traveller's device asks
  /// the engine (it knows interruptions and geometry first-hand); watchers
  /// derive from the row + destination + realtime freshness.
  JourneyPhase _phaseFor(Message m) {
    if (_journey.owns(m.id)) {
      switch (_journey.state) {
        case JourneyState.nearby:
          return JourneyPhase.nearby;
        case JourneyState.interrupted:
        case JourneyState.reconnecting:
          return JourneyPhase.reconnecting;
        default:
          return JourneyPhase.travelling;
      }
    }
    final dest = _journeyDestination();
    return deriveWatcherJourneyPhase(
      m,
      destLat: dest?.latitude,
      destLng: dest?.longitude,
      lastEventAt: m.isMe ? null : _journeyEventAt[m.id],
    );
  }

  /// If the newest live share in this thread belongs to the current user and
  /// the engine doesn't own it (fresh process, engine idle), hand it to the
  /// engine, which resumes beats with the REMAINING safety window. Idempotent —
  /// the engine no-ops when it already owns the row.
  void _readoptOwnLiveJourney() {
    Message? mine;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.isLiveNow && m.isMe) {
        mine = m;
        break;
      }
    }
    if (mine == null || mine.liveUntil == null) return;
    JourneyEngine.instance.adopt(
      messageId: mine.id,
      chatId: _chatId,
      liveUntil: mine.liveUntil!,
      destination: _journeyDestination(),
    );
  }

  /// Where this journey is headed, best knowledge first: the post's own
  /// coordinates, else the most recent pinned place in the thread (the gate,
  /// the stalled car — by convention the job location), else none. Null keeps
  /// the journey valid — it just cannot auto-arrive or show "nearby".
  GeoPoint? _journeyDestination() {
    final post = _chatPost;
    if (post?.latitude != null && post?.longitude != null) {
      return GeoPoint(post!.latitude!, post.longitude!);
    }
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.type == 'location' && m.hasValidCoordinates && !m.deletedForEveryone) {
        return GeoPoint(m.latitude!, m.longitude!);
      }
    }
    return null;
  }

  /// Viewer position for card distance labels — silent, never prompts.
  Future<void> _primeViewerPosition() async {
    final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (mounted && pos != null) {
      setState(() {
        _myLat = pos.latitude;
        _myLng = pos.longitude;
      });
    }
  }

  /// Lazily fetches the post behind this chat (destination, picker centering,
  /// role ordering). Deduplicated; a failure just means graceful fallbacks.
  Future<void> _ensureChatPost() {
    final postId = widget.conversation.postId;
    if (_chatPost != null || postId == null || postId.isEmpty) {
      return Future.value();
    }
    return _chatPostFetch ??= PostService.getPostById(postId).then((post) {
      if (mounted && post != null) setState(() => _chatPost = post);
    }).catchError((_) {
      _chatPostFetch = null; // allow a retry on the next intent
    });
  }

  /// Role-aware intent ordering: the person who did NOT author a request/job
  /// post is usually the one travelling, so "On my way" leads for them. For
  /// offer posts it is inverted (the author is the provider). Falls back to
  /// traveller-first — the most common marketplace action — until the post is
  /// known. Ordering only; every intent stays available to both sides.
  bool get _travellerFirst {
    final post = _chatPost;
    if (post == null) return true;
    final mine = post.authorUserId == widget.currentUserId;
    if (post.type == PostType.offer) return mine;
    return !mine;
  }

  void _openLocationIntents() {
    if (_isSending) return;
    // Warm-ups so the full-screen surfaces open already-informed: the post
    // (destination/centering) and a silent GPS fix. Neither blocks the sheet.
    _ensureChatPost();
    _primeViewerPosition();
    LocationIntents.show(
      context,
      travellerFirst: _travellerFirst,
      onOnMyWay: _startJourneyFlow,
      onSendPlace: _openPlacePicker,
      onRequestLocation: _sendLocationRequest,
    );
  }

  /// "On my way": confirm screen (destination from the post, else the most
  /// recent pinned place in the thread), then hand the journey to the engine.
  /// The confirm screen owns the permission scenario.
  Future<void> _startJourneyFlow() async {
    await _ensureChatPost();
    if (!mounted) return;
    final post = _chatPost;
    final dest = _journeyDestination();
    final start = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => JourneyConfirmScreen(
          destination: dest == null ? null : LatLng(dest.latitude, dest.longitude),
          destinationTitle: widget.conversation.postTitle ?? post?.title ?? 'This job',
          destinationSubtitle: post?.location ?? '',
        ),
      ),
    );
    if (start == true && mounted) await _startJourney(dest);
  }

  /// "Send a place": full-screen picker centered on the job → last-known
  /// position → default region. Works fully without GPS (Scenario B).
  Future<void> _openPlacePicker() async {
    await _ensureChatPost();
    if (!mounted) return;
    final post = _chatPost;
    LatLng? center;
    if (post?.latitude != null && post?.longitude != null) {
      center = LatLng(post!.latitude!, post.longitude!);
    } else if (_myLat != null && _myLng != null) {
      center = LatLng(_myLat!, _myLng!);
    }
    final picked = await Navigator.of(context).push<PickedPlace>(
      MaterialPageRoute(builder: (_) => PlacePickerScreen(initialCenter: center)),
    );
    if (picked != null && mounted) await _sendPickedPlace(picked);
  }

  Future<void> _sendPickedPlace(PickedPlace place) async {
    setState(() => _isSending = true);
    if (!await _ensureChatCreated()) {
      if (mounted) { setState(() => _isSending = false); _showError('Could not start chat. Please try again.'); }
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    try {
      await ChatServiceSupabase.sendLocation(
        chatId: _chatId,
        senderId: widget.currentUserId,
        latitude: place.latitude,
        longitude: place.longitude,
        label: place.label,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Failed to send the place.');
      }
    }
  }

  /// "Request location": sends immediately — no second UI (by design).
  Future<void> _sendLocationRequest() async {
    setState(() => _isSending = true);
    if (!await _ensureChatCreated()) {
      if (mounted) { setState(() => _isSending = false); _showError('Could not start chat. Please try again.'); }
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    try {
      await ChatServiceSupabase.sendLocationRequest(
        chatId: _chatId,
        senderId: widget.currentUserId,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Could not send the request.');
      }
    }
  }

  Future<void> _startJourney(GeoPoint? destination) async {
    setState(() => _isSending = true);
    if (!await _ensureChatCreated()) {
      if (mounted) { setState(() => _isSending = false); _showError('Could not start chat. Please try again.'); }
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    // Foreground service ON: a journey is a promise to someone waiting, so it
    // must survive the screen locking or the app being backgrounded. Android
    // shows the ongoing "Sharing your journey" notification for the duration
    // and the service stops with the journey.
    final result = await JourneyEngine.instance.start(
      chatId: _chatId,
      senderId: widget.currentUserId,
      destination: destination,
      foregroundService: true,
    );
    if (!mounted) return;
    setState(() => _isSending = false);
    switch (result) {
      case JourneyStartResult.started:
        _scrollToBottom();
        break;
      case JourneyStartResult.permissionRequired:
        JourneyEngine.instance.acknowledgeIdle();
        _showError('Location permission is needed to share your journey.');
        break;
      case JourneyStartResult.serviceDisabled:
        JourneyEngine.instance.acknowledgeIdle();
        _showError('Turn on location to share your journey.');
        break;
      case JourneyStartResult.failed:
        JourneyEngine.instance.acknowledgeIdle();
        _showError('Failed to start the journey.');
        break;
    }
  }

  Future<void> _stopLiveSharing() async {
    await JourneyEngine.instance.stop();
  }

  /// "I've arrived": the engine ends the journey as ARRIVED (the card mutates
  /// into the receipt on both sides via realtime), then we offer the heads-up.
  Future<void> _markArrived() async {
    final ok = await JourneyEngine.instance.arrive();
    if (!mounted || !ok) return;
    await _offerArrivalNotify();
  }

  /// The human close of a journey (manual or automatic): offer to send the
  /// other party a one-tap heads-up message.
  Future<void> _offerArrivalNotify() async {
    final partner = widget.conversation.userName.trim();
    final notify = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("You've arrived"),
        content: Text(
          'Send ${partner.isEmpty ? 'them' : partner} a heads-up that you are at the location?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Notify'),
          ),
        ],
      ),
    );
    if (notify == true && mounted) {
      try {
        await ChatServiceSupabase.sendMessage(
          chatIdParam: _chatId,
          senderId: widget.currentUserId,
          content: "🔔 I've arrived at the location.",
        );
        if (mounted) _scrollToBottom();
      } catch (_) {
        if (mounted) _showError('Could not send the arrival note.');
      }
    }
  }

  /// Recipient tapped "Share now" on a request card → straight into the picker.
  void _respondToLocationRequest() {
    _openPlacePicker();
  }

  /// Opens the FULL production post detail screen — the exact same screen
  /// Discover uses (PostService.getPostById → PostDetailScreen).
  bool _openingPost = false;

  Future<void> _openPostFromChat(String postId) async {
    if (_openingPost) return;
    setState(() => _openingPost = true);
    try {
      final post = await PostService.getPostById(postId);
      if (!mounted) return;
      if (post == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This post is no longer available'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => PostDetailScreen(post: post),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not load the post. Check your connection.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingPost = false);
    }
  }

  /// Scrolls the list so the message whose [id] equals [targetId] is visible.
  /// Used when user taps the quoted block in a reply bubble.
  void _scrollToMessage(String targetId) {
    // _itemIndexByKey holds reversed indices, rebuilt on every build — always
    // in sync with what the ListView is showing.
    final index = _itemIndexByKey['m_$targetId'];
    if (index == null || !_scrollController.hasClients) return;
    // Estimate item height — accurate enough to land near the message.
    const estimatedItemH = 60.0;
    final targetOffset = (index * estimatedItemH)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  // ── Message actions (Part 3 + 4) ──────────────────────────────────────────

  /// Long-press → anchored context menu: the pressed bubble lifts above a
  /// blurred backdrop with the action card beneath it (chat_ui.dart).
  void _showMessageActions(Message message, Rect bubbleRect) {
    final canDeleteForEveryone = message.isMe &&
        DateTime.now().difference(message.timestamp).inMinutes <= 15;
    showMessageContextMenu(
      context,
      message: message,
      bubbleRect: bubbleRect,
      onReply: () => setState(() => _replyToMessage = message),
      onCopy: message.text.isNotEmpty
          ? () {
              Clipboard.setData(ClipboardData(text: message.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Message copied'),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          : null,
      onDeleteForMe: () => _deleteForMe(message),
      onDeleteForEveryone:
          canDeleteForEveryone ? () => _deleteForEveryone(message) : null,
      onReport: message.isMe ? null : () => _openReportSheet(messageId: message.id),
    );
  }

  void _openReportSheet({String? messageId}) {
    if (widget.conversation.participantId.isEmpty) return;
    ReportUserSheet.show(
      context,
      reporterId: widget.currentUserId,
      reportedUserId: widget.conversation.participantId,
      reportedUserName: widget.conversation.userName,
      chatId: _chatId.isNotEmpty ? _chatId : null,
      postId: widget.conversation.postId,
      messageId: messageId,
    );
  }

  /// Dispatch for the three-dot conversation command menu.
  void _onMenuAction(ChatMenuAction action) {
    final postId = widget.conversation.postId;
    final hasPost = postId != null && postId.isNotEmpty;
    switch (action) {
      case ChatMenuAction.viewPost:
        if (hasPost) _openPostFromChat(postId);
      case ChatMenuAction.jobStatus:
        if (hasPost) {
          JobStatusSheet.show(
            context,
            postId: postId,
            currentUserId: widget.currentUserId,
            postTitle: widget.conversation.postTitle,
          );
        }
      case ChatMenuAction.search:
        if (_chatId.isEmpty) return;
        ConversationSearchSheet.show(
          context,
          chatId: _chatId,
          currentUserId: widget.currentUserId,
          partnerName: widget.conversation.userName,
          isVisible: _isLocallyVisible,
          onResultTap: _onSearchResultTap,
        );
      case ChatMenuAction.mute:
        _toggleMute();
      case ChatMenuAction.clear:
        _confirmClearConversation();
      case ChatMenuAction.report:
        _openReportSheet();
    }
  }

  void _onSearchResultTap(Message message) {
    if (_itemIndexByKey.containsKey('m_${message.id}')) {
      _scrollToMessage(message.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That message is further back in the history'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _confirmClearConversation() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Clear conversation?',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Messages will be removed from this device only. '
          '${widget.conversation.userName} keeps their copy.',
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Clear',
              style: TextStyle(color: AppTheme.errorRed, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _clearConversation();
  }

  void _deleteForMe(Message message) {
    // Hide via the persistent local filter (survives reopen/offline) instead
    // of dropping from _messages, which realtime would resurrect.
    setState(() => _hiddenIds = {..._hiddenIds, message.id});
    ChatLocalPrefs.hideMessage(_chatId, message.id);
  }

  Future<void> _clearConversation() async {
    final now = DateTime.now().toUtc();
    setState(() {
      _clearedBefore = now;
      _replyToMessage = null;
    });
    await ChatLocalPrefs.setClearedBefore(_chatId, now);
    // Purge the on-device thread cache so hydration can't resurrect it, and
    // drop any queued cache write that would re-save the cleared thread.
    _cacheSaveDebounce?.cancel();
    _cacheSaveDebounce = null;
    _pendingCacheSave = null;
    await CacheService.saveMessages(_chatId, []);
    // Repaint the Messages tab so its tile stops echoing the old preview
    // the moment the user navigates back.
    if (mounted) context.read<AppProvider>().touchConversations();
  }

  Future<void> _toggleMute() async {
    final muted = await ChatLocalPrefs.toggleMuted(_chatId);
    if (!mounted) return;
    setState(() => _isMuted = muted);
    // The tile's mute icon reads ChatLocalPrefs — repaint the list too.
    context.read<AppProvider>().touchConversations();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(muted
            ? 'Notifications muted for this conversation'
            : 'Notifications unmuted'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deleteForEveryone(Message message) async {
    // Optimistic update — show tombstone immediately on sender's device.
    // The Realtime UPDATE propagates the change to the receiver's device.
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == message.id);
      if (idx != -1) {
        final updated = List<Message>.of(_messages);
        updated[idx] = _messages[idx].copyWith(deletedForEveryone: true);
        _messages = updated;
      }
    });

    final result = await ChatServiceSupabase.deleteMessageForEveryone(
      message.id,
      message.timestamp,
    );
    if (!mounted) return;
    if (result != DeleteForEveryoneResult.success) {
      // Revert the optimistic update.
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == message.id);
        if (idx != -1) {
          final updated = List<Message>.of(_messages);
          updated[idx] = message; // restore original
          _messages = updated;
        }
      });
      _showError(result == DeleteForEveryoneResult.windowExpired
          ? 'Cannot delete for everyone — messages can only be deleted within 15 minutes.'
          : 'Could not delete the message. Please try again.');
    }
    // If success: Realtime UPDATE in watchMessages propagates tombstone to receiver.
  }

  void _openFullScreenMap(Message message) {
    if (!message.hasValidCoordinates) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => _FullScreenMapScreen(
          conversationId: widget.conversation.id,
          message: message,
          currentUserId: widget.currentUserId,
          canStopSharing: _journey.owns(message.id) && _journey.isLive,
          onStopSharing: _stopLiveSharing,
        ),
      ),
    );
  }

  // ── Build flat display list (date dividers + grouped message items) ────────

  /// Stable identity for each row — powers element reuse (findChildIndexCallback)
  /// so inserts while scrolled up never visually shift the reader's position,
  /// and reply-quote jumps (_scrollToMessage).
  static String _itemKeyOf(_ChatListItem item) {
    if (item is _ChatMessageItem) return 'm_${item.message.id}';
    final d = (item as _ChatDateDivider).date;
    return 'd_${d.year}-${d.month}-${d.day}';
  }

  List<_ChatListItem> _buildItemsList(List<Message> messages) {
    final items = <_ChatListItem>[];
    DateTime? lastDate;

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final prevMsg = i > 0 ? messages[i - 1] : null;
      final nextMsg = i < messages.length - 1 ? messages[i + 1] : null;

      // Insert a date divider whenever the LOCAL calendar day changes. Using
      // the raw (UTC) components split days at UTC midnight, which put evening
      // messages under the wrong date header.
      final msgDate = localDay(msg.timestamp);
      if (lastDate == null || msgDate != lastDate) {
        items.add(_ChatDateDivider(msgDate));
        lastDate = msgDate;
      }

      // Two messages are in the same group when: same sender, ≤2 minutes apart.
      final isFirstInGroup = prevMsg == null ||
          prevMsg.isMe != msg.isMe ||
          msg.timestamp.difference(prevMsg.timestamp).inMinutes >= 2;
      final isLastInGroup = nextMsg == null ||
          nextMsg.isMe != msg.isMe ||
          nextMsg.timestamp.difference(msg.timestamp).inMinutes >= 2;

      items.add(_ChatMessageItem(
        message: msg,
        isPending: msg.id.startsWith('pending_'),
        isFirstInGroup: isFirstInGroup,
        isLastInGroup: isLastInGroup,
      ));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      onPopInvokedWithResult: (_, __) {},
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leadingWidth: 48,
          titleSpacing: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Row(
            children: [
              _HeaderAvatar(
                avatarUrl: widget.conversation.userAvatar,
                initial: widget.conversation.userName.isNotEmpty
                    ? widget.conversation.userName.substring(0, 1).toUpperCase()
                    : 'U',
                isOnline: _onlineStatus == 'online',
                ringColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.conversation.userName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        // Earned verification: only for backend-trusted tiers.
                        if (_headerRep != null && _trustedTiers.contains(_headerRep!.tier)) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified_rounded,
                            size: 15,
                            color: tierColor(_headerRep!.tier),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: _buildHeaderSubtitle(isDark),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            PopupMenuButton<ChatMenuAction>(
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: 'Conversation options',
              position: PopupMenuPosition.under,
              color: isDark ? AppTheme.darkCard : AppTheme.lightSurface,
              elevation: 8,
              shadowColor: Colors.black.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  width: 0.5,
                ),
              ),
              constraints: const BoxConstraints(minWidth: 220),
              onSelected: _onMenuAction,
              itemBuilder: (context) => buildChatMenuItems(
                isDark: isDark,
                hasPost: widget.conversation.postId != null &&
                    widget.conversation.postId!.isNotEmpty,
                isMuted: _isMuted,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            // Post context banner — lets the user always know what job this chat is about
            if (widget.conversation.postTitle != null && widget.conversation.postTitle!.isNotEmpty)
              _PostContextBanner(
                postTitle: widget.conversation.postTitle!,
                isDark: isDark,
                busy: _openingPost,
                onTap: widget.conversation.postId != null && widget.conversation.postId!.isNotEmpty
                    ? () => _openPostFromChat(widget.conversation.postId!)
                    : null,
              ),
            // Journey strip — narrates the journey as it evolves: on the way →
            // nearby → reconnecting → arrived (brief), then leaves. One strip,
            // phase-driven; tap opens the live map.
            if (_stripJourney != null)
              Builder(builder: (context) {
                final journey = _stripJourney!;
                final mine = journey.isMe;
                final phase = _phaseFor(journey);
                final name = widget.conversation.userName;
                final String title;
                switch (phase) {
                  case JourneyPhase.nearby:
                    title = mine ? "You're almost there" : '$name is nearby';
                    break;
                  case JourneyPhase.reconnecting:
                    title = mine ? 'Reconnecting…' : "Waiting for $name's signal…";
                    break;
                  case JourneyPhase.arrived:
                    title = mine ? "You've arrived" : '$name has arrived';
                    break;
                  case JourneyPhase.travelling:
                  case JourneyPhase.ended:
                    title = mine ? "You're sharing your journey" : '$name is on the way';
                    break;
                }
                return JourneyStatusStrip(
                  title: title,
                  phase: phase,
                  onTap: journey.hasValidCoordinates ? () => _openFullScreenMap(journey) : null,
                  onStop:
                      mine && _journey.owns(journey.id) && _journey.isLive ? _stopLiveSharing : null,
                );
              }),
            // Job/payment tracking moved to the three-dot menu (Job status
            // sheet) — the conversation keeps its full height for messages.
            // Messages: cache-hydrated instantly, then Supabase Realtime.
            Expanded(
              child: Stack(
                children: [
                Builder(
                builder: (context) {
                  final combined = _messages.where(_isLocallyVisible).toList();
                  for (final p in _pendingMessages) {
                    final duplicate = combined.any((m) =>
                        m.isMe && m.text == p.text && m.timestamp.difference(p.timestamp).inSeconds.abs() < 15);
                    if (!duplicate) combined.add(p);
                  }
                  combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));

                  if (_loadingMessages && combined.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (combined.isEmpty && _loadFailed) {
                    _lastMessageCount = 0;
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Iconsax.cloud_cross,
                              size: 52,
                              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              "Couldn't load messages",
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: isDark
                                        ? AppTheme.darkTextSecondary
                                        : AppTheme.lightTextSecondary,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Check your connection and try again.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: isDark
                                        ? AppTheme.darkTextTertiary
                                        : AppTheme.lightTextTertiary,
                                  ),
                            ),
                            const SizedBox(height: 14),
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _loadFailed = false;
                                  _loadingMessages = true;
                                });
                                _startRealtimeMessages();
                              },
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (combined.isEmpty) {
                    _lastMessageCount = 0;
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Iconsax.message,
                            size: 52,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Start the conversation',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Say hello 👋',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final showLoadMore = _hasMoreOlder || _loadingOlder;
                  final items = _buildItemsList(combined);
                  // Reversed presentation: ListView index 0 == the NEWEST item.
                  // The list is anchored at offset 0 (the visual bottom), which
                  // makes "open exactly on the latest message" a structural
                  // property — layout timing, image sizes, keyboard insets and
                  // pagination cannot affect it. The "load older" row lives
                  // past the oldest item (the visual top).
                  _itemIndexByKey.clear();
                  for (int i = 0; i < items.length; i++) {
                    _itemIndexByKey[_itemKeyOf(items[items.length - 1 - i])] = i;
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: items.length + (showLoadMore ? 1 : 0),
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<String>) return null;
                      return _itemIndexByKey[key.value];
                    },
                    itemBuilder: (context, index) {
                      if (showLoadMore && index == items.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _loadingOlder
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : TextButton.icon(
                                    onPressed: _loadOlderMessages,
                                    icon: const Icon(Iconsax.arrow_up_2, size: 18),
                                    label: const Text('Load older messages'),
                                  ),
                          ),
                        );
                      }
                      final item = items[items.length - 1 - index];
                      if (item is _ChatDateDivider) {
                        return KeyedSubtree(
                          key: ValueKey<String>(_itemKeyOf(item)),
                          child: _DateDivider(date: item.date),
                        );
                      }
                      final msgItem = item as _ChatMessageItem;
                      return KeyedSubtree(
                        key: ValueKey<String>(_itemKeyOf(item)),
                        child: _MessageBubble(
                          message: msgItem.message,
                          currentUserId: widget.currentUserId,
                          senderAvatar: widget.conversation.userAvatar,
                          senderInitial: widget.conversation.userName.isNotEmpty
                              ? widget.conversation.userName.substring(0, 1).toUpperCase()
                              : '?',
                          isPending: msgItem.isPending,
                          isFirstInGroup: msgItem.isFirstInGroup,
                          isLastInGroup: msgItem.isLastInGroup,
                          isLiveSharing: _journey.owns(msgItem.message.id),
                          journeyPhase: msgItem.message.isLiveLocation
                              ? _phaseFor(msgItem.message)
                              : JourneyPhase.travelling,
                          journeyLastEventAt: _journeyEventAt[msgItem.message.id],
                          onStopLiveSharing: _journey.owns(msgItem.message.id) ? _stopLiveSharing : null,
                          onMarkArrived: _journey.owns(msgItem.message.id) ? _markArrived : null,
                          onTapLocation: msgItem.message.hasValidCoordinates ? () => _openFullScreenMap(msgItem.message) : null,
                          onRespondToRequest:
                              msgItem.message.isLocationRequest && !msgItem.message.isMe
                                  ? _respondToLocationRequest
                                  : null,
                          partnerName: widget.conversation.userName,
                          viewerLat: _myLat,
                          viewerLng: _myLng,
                          onLongPressMessage: msgItem.isPending || msgItem.message.deletedForEveryone
                              ? null
                              : _showMessageActions,
                          onTapReplyQuote: _scrollToMessage,
                        ),
                      );
                    },
                  );
                },
              ),
              // Scroll-to-bottom button — appears when scrolled away from latest messages
              if (!_isNearBottom)
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: _scrollToBottom,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
            // (Typing indicator lives in the header subtitle — no layout shift.)
            // Context action — the marketplace already knows who travels, who
            // hosts, what was asked and where the journey stands; surface the
            // single next action instead of making users dig through menus.
            Builder(builder: (context) {
              final action = _contextAction();
              if (action == null) return const SizedBox.shrink();
              return ContextActionBar(
                icon: action.icon,
                label: action.label,
                onTap: action.onTap,
              );
            }),
            // Reply preview bar — visible when user long-pressed a message to reply.
            if (_replyToMessage != null)
              _ReplyPreviewBar(
                replyTo: _replyToMessage!,
                isDark: isDark,
                partnerName: widget.conversation.userName,
                onCancel: () => setState(() => _replyToMessage = null),
              ),
            // Composer — enclosed rounded field with the attach entry inside,
            // elevated above the background (theme convention: shadow, not
            // Material elevation). resizeToAvoidBottomInset moves it with the
            // keyboard; SafeArea covers the home-indicator gap.
            Container(
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(
                            maxHeight: _kChatInputMaxHeight,
                            minHeight: 52,
                          ),
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            // Bottom-anchored so the attach button stays put
                            // while the field grows upward; 4px offset centers
                            // it optically inside the 52px resting height.
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 6, bottom: 4),
                                child: IconButton(
                                  onPressed: _showAttachmentOptions,
                                  tooltip: 'Attach',
                                  icon: Icon(
                                    Icons.add_circle_outline_rounded,
                                    size: 26,
                                    color: isDark
                                        ? AppTheme.darkTextSecondary
                                        : AppTheme.lightTextSecondary,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 44,
                                    minHeight: 44,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _messageController,
                                  minLines: 1,
                                  maxLines: 5,
                                  textInputAction: TextInputAction.newline,
                                  keyboardType: TextInputType.multiline,
                                  textCapitalization: TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    hintText: 'Message…',
                                    hintStyle: TextStyle(
                                      color: isDark
                                          ? AppTheme.darkTextTertiary
                                          : AppTheme.lightTextTertiary,
                                      fontSize: 15.5,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding:
                                        const EdgeInsets.fromLTRB(4, 15.5, 16, 15.5),
                                  ),
                                  style: const TextStyle(fontSize: 15.5, height: 1.4),
                                  onSubmitted: (_) => _sendMessage(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Send — enabled state follows the text live; stays
                      // interactive while an attachment uploads elsewhere.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _messageController,
                        builder: (context, value, _) {
                          final canSend =
                              value.text.trim().isNotEmpty && !_isSending;
                          return GestureDetector(
                            onTap: canSend ? _sendMessage : null,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: canSend
                                    ? AppTheme.primaryAccent
                                    : (isDark
                                        ? AppTheme.darkCard
                                        : AppTheme.lightBackground),
                                shape: BoxShape.circle,
                                border: canSend
                                    ? null
                                    : Border.all(
                                        color: isDark
                                            ? AppTheme.darkBorder
                                            : AppTheme.lightBorder,
                                        width: 0.5,
                                      ),
                                boxShadow: canSend
                                    ? [
                                        BoxShadow(
                                          color: AppTheme.primaryAccent
                                              .withValues(alpha: 0.35),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: _isSending
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                            AppTheme.primaryAccent),
                                      ),
                                    )
                                  : Icon(
                                      Icons.arrow_upward_rounded,
                                      color: canSend
                                          ? Colors.white
                                          : (isDark
                                              ? AppTheme.darkTextTertiary
                                              : AppTheme.lightTextTertiary),
                                      size: 24,
                                    ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner at the top of the chat body showing which post this conversation is
/// about. Tapping opens the FULL post detail screen (same as Discover).
class _PostContextBanner extends StatelessWidget {
  final String postTitle;
  final bool isDark;
  final bool busy;
  final VoidCallback? onTap;

  const _PostContextBanner({
    required this.postTitle,
    required this.isDark,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return Material(
      color: isDark
          ? AppTheme.primaryAccent.withValues(alpha: 0.08)
          : AppTheme.primaryAccent.withValues(alpha: 0.06),
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.description_outlined,
                  size: 16,
                  color: AppTheme.primaryAccent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      postTitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (onTap != null)
                      Text(
                        'Tap to view post details',
                        style: TextStyle(fontSize: 11, color: tertiary),
                      ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primaryAccent,
                        ),
                      )
                    : Icon(Icons.chevron_right_rounded, size: 20, color: tertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Row in the attach/location sheets: tinted rounded icon + title/subtitle.
class _AttachOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 21, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final String currentUserId;
  final String senderAvatar;
  final String senderInitial;
  final bool isPending;
  final bool isLiveSharing;
  final JourneyPhase journeyPhase;
  final DateTime? journeyLastEventAt;
  final VoidCallback? onStopLiveSharing;
  final VoidCallback? onMarkArrived;
  final VoidCallback? onTapLocation;
  /// Recipient-side "Share now" on a location request card.
  final VoidCallback? onRespondToRequest;
  /// Other participant's display name (request card copy).
  final String partnerName;
  /// Viewer's last-known position — powers "2.1 km away" on location cards.
  final double? viewerLat;
  final double? viewerLng;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  /// Long-press with the bubble's global rect so the context menu can anchor
  /// exactly where the message sits on screen.
  final void Function(Message, Rect)? onLongPressMessage;
  final void Function(String replyToId)? onTapReplyQuote;

  const _MessageBubble({
    required this.message,
    required this.currentUserId,
    this.senderAvatar = '',
    this.senderInitial = '?',
    this.isPending = false,
    this.isLiveSharing = false,
    this.journeyPhase = JourneyPhase.travelling,
    this.journeyLastEventAt,
    this.onStopLiveSharing,
    this.onMarkArrived,
    this.onTapLocation,
    this.onRespondToRequest,
    this.partnerName = '',
    this.viewerLat,
    this.viewerLng,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.onLongPressMessage,
    this.onTapReplyQuote,
  });

  // Computes bubble corner radii based on message position within a sender group.
  // The "tail" (flat corner, r=4) appears only on the last message of a group,
  // pointing toward the avatar side. Mid-group messages use a tighter inner radius (r=6).
  BorderRadius _buildBorderRadius() {
    const r = Radius.circular(18);
    const tail = Radius.circular(4);
    const inner = Radius.circular(6);

    if (message.isMe) {
      return BorderRadius.only(
        topLeft: r,
        topRight: isFirstInGroup ? r : inner,
        bottomLeft: r,
        bottomRight: isLastInGroup ? tail : inner,
      );
    } else {
      return BorderRadius.only(
        topLeft: isFirstInGroup ? r : inner,
        topRight: r,
        bottomLeft: isLastInGroup ? tail : inner,
        bottomRight: r,
      );
    }
  }

  /// Message-bubble stamp. Delegates to the canonical formatter so the time is
  /// rendered in the device's zone and 12h/24h convention — reading
  /// `time.hour` here rendered the UTC wall clock (3 h behind in EAT).
  String _formatTime(BuildContext context, DateTime time) =>
      formatMessageStamp(context, time);

  Widget _buildTombstone(BuildContext context, bool isDark) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLastInGroup ? 6 : 2),
      child: Row(
        mainAxisAlignment: message.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isMe) const SizedBox(width: 32),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkCard.withValues(alpha: 0.6) : AppTheme.lightCard,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.block_rounded,
                  size: 13,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                ),
                const SizedBox(width: 5),
                Text(
                  'This message was deleted',
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (message.isMe) const SizedBox(width: 4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Tombstone — replaces full bubble for deleted messages.
    if (message.deletedForEveryone) {
      return _buildTombstone(context, isDark).animate().fadeIn(duration: 200.ms);
    }

    final isLocation = message.isLocation && message.hasValidCoordinates;
    final isImage = message.isImage && (message.attachmentUrl != null && message.attachmentUrl!.isNotEmpty);
    final isFile = message.isFile && (message.attachmentUrl != null && message.attachmentUrl!.isNotEmpty);

    return Padding(
      padding: EdgeInsets.only(
        bottom: isLastInGroup ? 6 : 2,
        top: isFirstInGroup ? 0 : 0,
      ),
      child: Row(
        mainAxisAlignment:
            message.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Sender avatar — shown on the left for received messages
          if (!message.isMe) ...[
            SizedBox(
              width: 28,
              height: 28,
              child: isLastInGroup
                  ? CircleAvatar(
                      radius: 14,
                      backgroundColor: AppTheme.primaryAccent,
                      backgroundImage: senderAvatar.isNotEmpty
                          ? CachedNetworkImageProvider(senderAvatar)
                          : null,
                      child: senderAvatar.isEmpty
                          ? Text(
                              senderInitial,
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            )
                          : null,
                    )
                  : null,
            ),
            const SizedBox(width: 4),
          ],
          Builder(builder: (bubbleContext) => GestureDetector(
            onLongPress: onLongPressMessage != null
                ? () {
                    final box = bubbleContext.findRenderObject() as RenderBox?;
                    final rect = (box != null && box.hasSize)
                        ? box.localToGlobal(Offset.zero) & box.size
                        : Rect.zero;
                    onLongPressMessage!(message, rect);
                  }
                : null,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: message.isMe
                  ? AppTheme.primaryAccent
                  : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
              borderRadius: _buildBorderRadius(),
              border: message.isMe
                  ? null
                  : Border.all(
                      color: isDark
                          ? AppTheme.darkBorder
                          : AppTheme.lightBorder.withValues(alpha: 0.8),
                      width: 0.5,
                    ),
            ),
            child: Column(
              crossAxisAlignment: message.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quoted reply block — shown when this message is a reply to another.
                if (message.replyToId != null && message.replyToPreview != null) ...[
                  GestureDetector(
                    onTap: onTapReplyQuote != null ? () => onTapReplyQuote!(message.replyToId!) : null,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: message.isMe
                            ? Colors.white.withValues(alpha: 0.18)
                            : (isDark
                                ? AppTheme.darkSurface.withValues(alpha: 0.8)
                                : AppTheme.lightBorder.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border(
                          left: BorderSide(
                            color: message.isMe
                                ? Colors.white.withValues(alpha: 0.7)
                                : AppTheme.primaryAccent,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            message.replyToSender ?? 'Unknown',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: message.isMe
                                  ? Colors.white
                                  : AppTheme.primaryAccent,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            message.replyToPreview!.length > 100
                                ? '${message.replyToPreview!.substring(0, 100)}…'
                                : message.replyToPreview!,
                            style: TextStyle(
                              fontSize: 12,
                              color: message.isMe
                                  ? Colors.white.withValues(alpha: 0.8)
                                  : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (isImage) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: message.attachmentUrl!,
                      width: 220,
                      height: 180,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 220,
                        height: 180,
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 220,
                        height: 180,
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                        child: const Icon(Icons.broken_image_outlined, size: 48),
                      ),
                    ),
                  ),
                  if (message.text.isNotEmpty && message.text != 'Image') ...[
                    const SizedBox(height: 6),
                    Text(
                      message.text,
                      style: TextStyle(
                        color: message.isMe
                            ? Colors.white
                            : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                        fontSize: 15,
                      ),
                    ),
                  ],
                ] else if (isFile) ...[
                  InkWell(
                    onTap: () {
                      if (message.attachmentUrl != null) {
                        // Could launch URL in browser
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Iconsax.document,
                          size: 28,
                          color: message.isMe ? Colors.white70 : AppTheme.primaryAccent,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            message.text.isNotEmpty ? message.text : 'File',
                            style: TextStyle(
                              color: message.isMe
                                  ? Colors.white
                                  : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                              fontSize: 15,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (message.isLocationRequest) ...[
                  RequestCard(
                    message: message,
                    partnerName: partnerName,
                    onShareNow: onRespondToRequest,
                  ),
                ] else if (isLocation && message.isLiveLocation) ...[
                  JourneyCard(
                    message: message,
                    viewerLat: viewerLat,
                    viewerLng: viewerLng,
                    isSharing: isLiveSharing,
                    phase: journeyPhase,
                    lastEventAt: journeyLastEventAt,
                    onStop: onStopLiveSharing,
                    onArrived: onMarkArrived,
                    onTap: onTapLocation,
                  ),
                ] else if (isLocation) ...[
                  PlaceCard(
                    message: message,
                    viewerLat: viewerLat,
                    viewerLng: viewerLng,
                    onTap: onTapLocation,
                  ),
                ] else
                  Text(
                    message.text,
                    style: TextStyle(
                      color: message.isMe
                          ? Colors.white
                          : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                      fontSize: 15,
                    ),
                  ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(context, message.timestamp),
                      style: TextStyle(
                        color: message.isMe
                            ? Colors.white.withValues(alpha: 0.7)
                            : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
                        fontSize: 11,
                      ),
                    ),
                    if (message.isMe) ...[
                      const SizedBox(width: 4),
                      _MessageStatusIcon(
                        isPending: isPending,
                        status: message.status,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          )), // GestureDetector + Builder
          if (message.isMe) const SizedBox(width: 4),
        ],
      ),
    ).animate().fadeIn(duration: 200.ms).slideX(
      begin: message.isMe ? 0.1 : -0.1,
      end: 0,
    );
  }
}

/// Tick-style delivery/read indicator for sent messages.
/// pending → spinner  |  sent → ✓  |  seen → ✓✓ (blue)
/// State transitions are cross-faded via AnimatedSwitcher.
class _MessageStatusIcon extends StatelessWidget {
  final bool isPending;
  final String status;

  const _MessageStatusIcon({required this.isPending, required this.status});

  Widget _icon() {
    if (isPending) {
      return SizedBox(
        key: const ValueKey('pending'),
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
        ),
      );
    }
    if (status == 'seen') {
      return const Icon(
        Icons.done_all_rounded,
        size: 14,
        color: Colors.lightBlueAccent,
        key: ValueKey('seen'),
      );
    }
    return Icon(
      Icons.done_rounded,
      size: 14,
      color: Colors.white.withValues(alpha: 0.65),
      key: const ValueKey('sent'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: _icon(),
    );
  }
}

/// Chat header avatar with a presence dot. Uses the cached image provider so
/// reopening a chat never re-downloads the avatar.
class _HeaderAvatar extends StatelessWidget {
  final String avatarUrl;
  final String initial;
  final bool isOnline;
  /// Ring around the presence dot — matches the AppBar background so the dot
  /// reads as punched out of the avatar.
  final Color ringColor;

  const _HeaderAvatar({
    required this.avatarUrl,
    required this.initial,
    required this.isOnline,
    required this.ringColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: AppTheme.primaryAccent,
            backgroundImage:
                avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
            child: avatarUrl.isEmpty
                ? Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
          if (isOnline)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: AppTheme.successGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Chat list item types ───────────────────────────────────────────────────

abstract class _ChatListItem {}

class _ChatDateDivider extends _ChatListItem {
  final DateTime date;
  _ChatDateDivider(this.date);
}

class _ChatMessageItem extends _ChatListItem {
  final Message message;
  final bool isPending;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  _ChatMessageItem({
    required this.message,
    required this.isPending,
    required this.isFirstInGroup,
    required this.isLastInGroup,
  });
}

// ── Date divider widget ────────────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final DateTime date;

  const _DateDivider({required this.date});

  String _label() => formatDateSeparator(date);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final labelBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final labelColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(child: Divider(color: dividerColor, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: labelBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: dividerColor, width: 0.5),
              ),
              child: Text(
                _label(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: labelColor,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          Expanded(child: Divider(color: dividerColor, height: 1)),
        ],
      ),
    );
  }
}

// ── Map preview helpers ────────────────────────────────────────────────────

class _FullScreenMapScreen extends StatefulWidget {
  final String conversationId;
  final Message message;
  final String currentUserId;
  final bool canStopSharing;
  final VoidCallback? onStopSharing;

  const _FullScreenMapScreen({
    required this.conversationId,
    required this.message,
    required this.currentUserId,
    required this.canStopSharing,
    this.onStopSharing,
  });

  @override
  State<_FullScreenMapScreen> createState() => _FullScreenMapScreenState();
}

class _FullScreenMapScreenState extends State<_FullScreenMapScreen> {
  late Message _message;
  double? _myLat;
  double? _myLng;
  bool _loadingMyPosition = true;
  GoogleMapController? _mapController;

  @override
  void initState() {
    super.initState();
    _message = widget.message;
    _loadMyPosition();
  }

  Future<void> _loadMyPosition() async {
    final pos = await LocationService.getCurrentPosition();
    if (mounted) {
      setState(() {
        _myLat = pos?.latitude;
        _myLng = pos?.longitude;
        _loadingMyPosition = false;
      });
      if (pos != null && _mapController != null) _fitBounds();
    }
  }

  void _fitBounds() {
    final lat = _message.latitude!;
    final lng = _message.longitude!;
    if (_myLat == null || _myLng == null || _mapController == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        lat < _myLat! ? lat : _myLat!,
        lng < _myLng! ? lng : _myLng!,
      ),
      northeast: LatLng(
        lat > _myLat! ? lat : _myLat!,
        lng > _myLng! ? lng : _myLng!,
      ),
    );
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 64));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lat = _message.latitude!;
    final lng = _message.longitude!;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _message.isJourneyArrived
              ? 'Journey'
              : _message.isLiveLocation
                  ? (_message.text == 'Live location' ? 'Live location' : 'Journey')
                  : 'Location',
        ),
        actions: [
          if (widget.canStopSharing && widget.onStopSharing != null)
            TextButton(
              onPressed: () {
                widget.onStopSharing!();
                Navigator.pop(context);
              },
              child: const Text('Stop sharing'),
            ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: LatLng(lat, lng), zoom: 15),
            markers: {
              Marker(
                markerId: const MarkerId('shared'),
                position: LatLng(lat, lng),
                icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
              ),
              if (_myLat != null && _myLng != null)
                Marker(
                  markerId: const MarkerId('me'),
                  position: LatLng(_myLat!, _myLng!),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
                ),
            },
            onMapCreated: (controller) {
              _mapController = controller;
              if (_myLat != null && _myLng != null) _fitBounds();
            },
            myLocationButtonEnabled: true,
            myLocationEnabled: !_loadingMyPosition,
          ),
          if (_message.isLiveLocation && _message.liveUntil != null && _message.liveUntil!.isAfter(DateTime.now()))
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 24,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                color: isDark ? AppTheme.darkCard : Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const LiveDot(size: 7),
                      const SizedBox(width: 12),
                      Text(
                        'Sharing live',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Reply preview bar (shown above the text input when replying) ──────────────

class _ReplyPreviewBar extends StatelessWidget {
  final Message replyTo;
  final bool isDark;
  final String partnerName;
  final VoidCallback onCancel;

  const _ReplyPreviewBar({
    required this.replyTo,
    required this.isDark,
    required this.partnerName,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    const accentColor = AppTheme.primaryAccent;
    final bg = isDark
        ? AppTheme.darkCard.withValues(alpha: 0.95)
        : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    final preview = replyTo.text.isNotEmpty
        ? replyTo.text.substring(0, replyTo.text.length.clamp(0, 120))
        : replyTo.isImage
            ? 'Photo'
            : replyTo.isFile
                ? 'File'
                : 'Location';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(color: borderColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyTo.isMe ? 'You' : partnerName,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: accentColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onCancel,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

