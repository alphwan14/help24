import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliverMultiBoxAdaptor;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';
import '../theme/app_icons.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../models/provider_reputation.dart';
import '../widgets/primitives.dart';
import '../widgets/reputation_widgets.dart';
import '../services/location_service.dart';
import '../services/reputation_service.dart';
import '../services/chat_local_prefs.dart';
import '../services/chat_resolution.dart';
import '../services/chat_service_supabase.dart';
import '../services/post_service.dart';
import '../services/cache_service.dart';
import '../services/chat_media_store.dart';
import '../services/chat_store.dart';
import '../services/outbox_delivery.dart';
import '../services/outbox_store.dart';
import '../services/supabase_auth_bridge.dart';
import '../services/chat_attachments.dart';
import '../services/chat_documents.dart';
import 'post_detail_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/error_mapper.dart';
import '../theme/tokens.dart';
import '../utils/time_utils.dart';
import '../services/adaptive_poll.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/chat_ui.dart';
import '../widgets/chat/chat_bubbles.dart';
import '../widgets/chat/chat_chrome.dart';
import '../widgets/chat/chat_sync_status.dart';
import '../widgets/chat/person_avatar.dart';
import '../models/chat_person.dart';
import '../models/chat_presentation.dart';
import '../models/chat_job_stage.dart';
import '../models/job_lifecycle.dart';
import '../services/jobs_service.dart';
import '../services/place_name_cache.dart';
import '../services/profession_registry.dart';
import '../services/user_profile_service.dart';
import '../utils/format_utils.dart';
import '../utils/payment_utils.dart';
import '../utils/phone_utils.dart';
import 'approve_or_dispute_screen.dart';
import 'job_lifecycle_screen.dart';
import 'mark_complete_screen.dart';
import 'payment_screen.dart';
import '../models/moderation.dart';
import '../services/account_status_service.dart';
import '../widgets/account_restriction.dart';
import '../widgets/report_sheet.dart';
import '../widgets/location_experience.dart';
import '../services/journey_engine.dart';
import '../services/route_service.dart';
import 'image_composer_screen.dart';
import 'image_viewer_screen.dart';
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
    // The outbox is not part of the conversation stream, so the list would not
    // otherwise repaint when a message is queued, delivered or fails while the
    // user is looking at it.
    OutboxStore.instance.addListener(_onOutboxChanged);
  }

  void _onOutboxChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    OutboxStore.instance.removeListener(_onOutboxChanged);
    super.dispose();
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

  /// Pull-to-refresh is the user asking for a sync NOW. The list is never
  /// cleared, so nothing blinks: the database change repaints it.
  Future<void> _refreshConversations() async {
    final uid = _currentUserId;
    if (uid.isEmpty) return;
    await context.read<AppProvider>().refreshConversations(uid);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          // The title, and under it the one line that says where chat stands
          // with the server — "Waiting for network", "Connecting…" or
          // nothing. Content below never waits on it.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Messages',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const ChatSyncStatusLine(),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: colors.borderHairline),

          // Conversations List
          Expanded(
            child: Consumer2<AppProvider, ConnectivityProvider>(
              builder: (context, provider, connectivity, _) {
                final conversations = provider.conversations;

                if (conversations.isEmpty) {
                  // Offline with nothing in the chat database: this phone has
                  // never loaded this account's chats. Say what would fix it.
                  //
                  // Checked BEFORE the skeleton: a skeleton offline promises a
                  // load that cannot happen. And it is only reachable with
                  // nothing stored — the list is read from the database first,
                  // so any history at all is on screen instead.
                  if (connectivity.isOffline) {
                    return OfflineEmptyView(
                      message: 'Connect to the internet to load your chats',
                      detail: "Once they've loaded, they stay on this phone — even offline.",
                      onRetry: () {
                        connectivity.checkNow();
                        _refreshConversations();
                      },
                    );
                  }
                  if (provider.isLoadingConversations) {
                    return const ConversationSkeletonList();
                  }
                  // "We couldn't load your chats" is not "you have no chats" —
                  // same distinction the Discover feed makes.
                  if (provider.messagesError != null) {
                    return ErrorRetryView(
                      message: provider.messagesError!,
                      onRetry: _refreshConversations,
                    );
                  }
                  return EmptyStateView(
                    icon: AppIcons.chat,
                    title: 'No messages yet',
                    subtitle: 'Start a conversation by contacting a poster. Pull to refresh.',
                    actions: [
                      TextButton.icon(
                        onPressed: _refreshConversations,
                        icon: const Icon(AppIcons.refresh, size: 20),
                        label: const Text('Refresh'),
                      ),
                    ],
                  );
                }

                // Every conversation the database holds — sync pages the whole
                // list in, so there is no "load more" to wait on.
                return RefreshIndicator(
                  onRefresh: _refreshConversations,
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      final uid = context.read<AuthProvider>().currentUserId ?? '';
                      final tile = _ConversationTile(
                        key: ValueKey(conversation.id),
                        conversation: conversation,
                        currentUserId: uid,
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

  /// The owner of these conversations. The outbox is user-owned, so reading it
  /// requires naming whose it is rather than trusting an ambient current user.
  final String currentUserId;

  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.currentUserId,
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // Device-local "clear conversation": when everything up to the last
    // message was cleared, the tile must not keep echoing the server-side
    // preview. A newer message than the watermark restores normal display.
    final cleared = ChatLocalPrefs.clearedBeforeSync(conversation.id);
    final isCleared =
        cleared != null && !conversation.lastMessageTime.isAfter(cleared);
    final showUnread = conversation.unreadCount > 0 && !isCleared;

    // AN UNSENT MESSAGE IS STILL THE LATEST THING IN THIS CONVERSATION.
    //
    // `conversation.lastMessage` is the server's `chats.last_message`, written
    // only after a successful insert. So a message composed offline used to
    // leave no trace here at all: the row kept showing the PREVIOUS message as
    // the latest one, and the user's own words were missing from the list with
    // nothing to explain why. What is queued is newer than what the server
    // knows, and it is shown as such — marked, never disguised as delivered.
    final pending = OutboxStore.instance.pendingFor(currentUserId, conversation.id);
    final hasFailure = OutboxStore.instance.hasFailure(currentUserId, conversation.id);
    // Worded exactly as the server will write it once delivered, so a queued
    // photo or place does not change its preview the moment it is sent.
    final previewText = pending == null
        ? conversation.lastMessage
        : ChatServiceSupabase.previewFor(type: pending.type, content: pending.text);
    final previewTime = pending?.timestamp ?? conversation.lastMessageTime;
    // Three states, three honest labels. "Sending…" is reserved for a request
    // that is genuinely open RIGHT NOW — asked of the store, not read off the
    // message's persisted status, because a status survives being killed
    // mid-send and would then claim a request that no longer exists. Anything
    // else says the true thing, which is that it has NOT been sent.
    final String? pendingLabel = pending == null
        ? null
        : (!hasFailure && OutboxStore.instance.isSending(pending.id))
            ? 'Sending…'
            : 'Not sent';
    // A cleared conversation is cleared UP TO A POINT; something composed since
    // is newer than that watermark and must show, exactly as a received message
    // newer than the watermark does.
    final showCleared = isCleared && pending == null;

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
                  // The person, from this phone first: their photo as a
                  // file, then the network, then their initials on their own
                  // tint. A placeholder is not a brand moment, and it is
                  // never "?" (see PersonAvatar).
                  PersonAvatar(
                    userId: conversation.participantId,
                    name: conversation.userName,
                    size: 52,
                    avatarPath: conversation.userAvatarPath,
                    avatarUrl: conversation.userAvatar,
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
                                ChatPeople.displayName(conversation.userName),
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (ChatLocalPrefs.isMutedSync(conversation.id)) ...[
                              Icon(AppIcons.mute, size: 13, color: colors.contentTertiary),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              _formatTime(previewTime),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                // Weight, not hue. The row already carries a
                                // red count; colouring the timestamp as well
                                // says "unread" twice, in a third colour.
                                color: showUnread
                                    ? AppColors.of(context).contentPrimary
                                    : null,
                                fontWeight:
                                    showUnread ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            // The unsent marker. A clock for "waiting for a
                            // network", a warning for "this did not go" — the
                            // two must not look alike, because only one of them
                            // needs the user to do something.
                            if (pending != null) ...[
                              Icon(
                                hasFailure
                                    ? AppIcons.error
                                    : AppIcons.messageSending,
                                size: 13,
                                color: hasFailure ? colors.criticalText : colors.contentTertiary,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                showCleared
                                    ? 'No messages'
                                    : previewText.isNotEmpty
                                        ? previewText
                                        : 'No messages yet',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: showUnread
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontStyle:
                                      showCleared ? FontStyle.italic : FontStyle.normal,
                                  color: hasFailure
                                      ? colors.criticalText
                                      : showUnread
                                          ? colors.contentPrimary
                                          : colors.contentSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // Says in words what the icon says in shape. "Not
                            // sent" is the fact the report asked for and the
                            // one a glyph alone cannot be trusted to carry.
                            if (pendingLabel != null) ...[
                              const SizedBox(width: 6),
                              Text(
                                pendingLabel,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: hasFailure ? colors.criticalText : colors.contentTertiary,
                                ),
                              ),
                            ],
                            if (showUnread) ...[
                              const SizedBox(width: 8),
                              Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  // The SAME red the bottom bar's badge uses.
                                  // An unread count rendered gold here and red
                                  // there is one concept in two colours, on two
                                  // surfaces a user sees at the same time.
                                  color: AppColors.of(context).criticalFill,
                                  borderRadius: AppRadius.pillAll,
                                ),
                                child: Text(
                                  conversation.unreadCount.toString(),
                                  style: TextStyle(
                                    // The theme's own "on error" — the label for this fill.
                                    color: Theme.of(context).colorScheme.onError,
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
                                AppIcons.pinned,
                                size: 12,
                                color: colors.contentTertiary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  conversation.postTitle!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.contentTertiary,
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
        Divider(height: 1, thickness: 0.5, indent: 82, endIndent: 0, color: colors.borderHairline),
      ],
    );
  }
}

/// The thread's padding below the newest message (the reversed list's
/// leading edge) — the sticky day pill reads the list in the same frame.
const double _kListPaddingBottom = 8;

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final String currentUserId;

  /// Entry points with NO post context (Provider Profile → Message) set this.
  ///
  /// The conversation is then resolved to the most recently active thread with
  /// this person, whatever its post, instead of always targeting the general
  /// (`post_id IS NULL`) one — so "message this provider" continues the
  /// conversation you were already having (§D2). Contextual entry points
  /// (application, post, job) leave it false and keep resolving their own
  /// specific `post_id`.
  final bool resolveMostRecent;

  const ChatScreen({
    super.key,
    required this.conversation,
    required this.currentUserId,
    this.resolveMostRecent = false,
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
  // alive (first chats-row event). Built in one place so both start sites (an
  // existing chat, and a pending chat that just got its first message) share
  // one cadence and one offline policy.
  AdaptivePoll? _typingPoll;

  AdaptivePoll _makeTypingPoll() => AdaptivePoll(
        interval: const Duration(seconds: 3),
        onTick: () {
          if (mounted) _checkTyping();
        },
        debugLabel: 'chat/typing',
      );
  // Debounced thread-cache persistence (one disk write per burst, not per
  // message), capped to the newest messages.
  Timer? _cacheSaveDebounce;
  List<Message>? _pendingCacheSave;
  bool _isSending = false;
  int _lastMessageCount = 0;

  // ── Offline outbox ──
  // Messages composed while unsent are queued (persisted per chat) and resent
  // automatically the moment the connection returns.
  //
  // This screen sends for the thread it is showing; `OutboxStore` owns the
  // queue for the session and drains every other thread. The in-flight claim
  // lives THERE, not here, so a manual retry, this screen's auto-flush and the
  // store's drain cannot all send the same message.
  StreamSubscription<void>? _reconnectSub;

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
  AdaptivePoll? _onlineStatusPoll;

  // Backend-sourced trust signal for the header (rating + verified tick).
  // Seeded synchronously from ReputationService's cache; refreshed once.
  ProviderReputation? _headerRep;
  static const _trustedTiers = {
    'top_rated',
    'highly_recommended',
    'trusted_professional',
  };

  /// The other person's `users.profession` (a registry key or legacy text),
  /// read with their presence — the header's "Plumber · ★ 4.8 · 34 jobs".
  String? _partnerProfession;

  /// The other person as the chat database knows them — name, photo file,
  /// profession — read at open, so the header is right with no network.
  ChatPerson? _partner;

  /// The conversation's own copy of its participant's last known name: the
  /// fallback that still names them when the person record has no name.
  String? _storedPartnerName;

  /// Who the other person is, for every place this screen names them. The
  /// person record wins, then the entry point's name, then the conversation's
  /// copy — and when none is known, `ChatPeople.unknownName`. Never "?".
  String get _partnerName => ChatPeople.displayName(
        _partner?.name ??
            ChatPeople.knownOrNull(widget.conversation.userName) ??
            _storedPartnerName,
      );

  /// Writes to the chat database by anyone else — a sync, a push the
  /// background isolate stored — reach the open thread through this.
  StreamSubscription<ChatChange>? _storeSub;
  Timer? _storeMerge;

  /// Offline and the database has nothing older: stop asking until a network
  /// returns, instead of re-querying on every scroll event.
  bool _olderExhaustedOffline = false;

  // ── Pinned job bar ──
  // The lifecycle aggregate is the server's money-truth for this job (see
  // chat_job_stage.dart). Memoised per post so reopening the chat paints the
  // bar at once; refreshed on open, every 30 s while online, on resume, and
  // after every action taken from the bar.
  JobLifecycle? _lifecycle;
  AdaptivePoll? _jobPoll;
  static final Map<String, JobLifecycle> _lifecycleMemo = {};

  // ── Thread presentation ──
  /// The rows last built — the sticky day pill reads them on scroll.
  List<ChatThreadEntry> _entries = const [];
  final GlobalKey _listKey = GlobalKey();

  /// The day of the message at the top of the viewport, pinned as a pill.
  DateTime? _stickyDay;

  /// Messages from the other person that arrived while scrolled up.
  int _unseenBelow = 0;

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

  /// AppProvider, captured in [initState] while the element is still active.
  ///
  /// `dispose()` runs from `StatefulElement.unmount()`, which has already
  /// released the element's widget — so `context.read<AppProvider>()` there
  /// walks into `Element.widget` and throws a null check on a null value. That
  /// is not a debug assert; it happens in release, on every close, and it
  /// aborts the rest of dispose(). See the note in [_markSeenNow]: the
  /// BuildContext stops being safe, the provider does not.
  late final AppProvider _appProvider;

  /// Whether a conversation exists — see `chat_resolution.dart`. Never let
  /// `resolving` or `unresolved` render the start-conversation state.
  ChatResolution _resolution = ChatResolution.resolving;

  /// Time-to-first-paint instrumentation for the chat thread.
  ///
  /// "It feels faster" is not a measurement. This records how long the user
  /// actually stares at a spinner: `CACHE_PAINT` is the cached thread appearing,
  /// `NET_PAINT` is the server's first page. The gap between them is the whole
  /// value of the cache, and if CACHE_PAINT never fires the cache did nothing.
  final Stopwatch _openWatch = Stopwatch();
  bool _loggedFirstPaint = false;

  void _logPaint(String stage, int count) {
    debugPrint(
      '[CHAT][$stage] +${_openWatch.elapsedMilliseconds}ms n=$count chat=$_chatId',
    );
  }

  /// The post context of the conversation we actually adopted, which can differ
  /// from the entry point's when Provider Profile resolved to the most recent
  /// (post-scoped) thread. Null until a lookup adopts one.
  String? _resolvedPostId;
  String? _resolvedPostTitle;

  /// What the CHAT is about — the adopted thread's post wins over the entry
  /// point's. Used for display and post-dependent actions only; the lookup key
  /// and lazy creation deliberately keep using `widget.conversation.postId`.
  String? get _postId => _resolvedPostId ?? widget.conversation.postId;
  String? get _postTitle => _resolvedPostTitle ?? widget.conversation.postTitle;

  String get _chatId => _activeChatId;

  /// Everything that must happen once a canonical chat UUID is known.
  ///
  /// Extracted so the initState path (id supplied by the caller) and the
  /// resolver path (id discovered by lookup) are literally the same code —
  /// the divergence between them is what §D1 was.
  void _beginExistingChat() {
    _loadLocalPrefs();
    // FIRST FRAME: if this thread is already mirrored in memory, seed it
    // synchronously so the chat opens with its history on screen — no spinner
    // at all, not even the one frame the async disk read used to cost.
    // A null peek means "not known yet", NOT "no messages": the async read
    // below is still authoritative.
    final memo = CacheService.peekMessages(_chatId, widget.currentUserId);
    if (memo != null && memo.isNotEmpty && _messages.isEmpty) {
      _messages = List<Message>.from(memo);
      ChatAttachmentCache.evictDeleted(_messages);
      _loadingMessages = false;
      _hasMoreOlder = memo.length >= 30;
      _loggedFirstPaint = true;
      _logPaint('MEMO_PAINT', memo.length);
    }
    // Paint the cached thread instantly (no spinner), then let realtime
    // replace it silently with fresh data.
    _hydrateFromCache();
    // The pinned job bar as it last stood, until the server says otherwise.
    unawaited(_restoreJobSnapshot());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppProvider>().setActiveChatId(_chatId);
    });
    _startRealtimeMessages();
    _startChatRowRealtime();
    _typingPoll ??= _makeTypingPoll()..start();
    _markSeenNow();
  }

  /// Take [chatId] as this screen's conversation — found in the chat database
  /// or by the server lookup; the two paths are the same code from here on.
  Future<void> _adoptExistingChat(
    String chatId, {
    required String? postId,
    required String? postTitle,
  }) async {
    setState(() {
      _activeChatId = chatId;
      _resolution = ChatResolution.existing;
      // Adopting the thread's real post context keeps the post banner and the
      // job-status card correct when Profile resolved to a post-scoped chat.
      // `_postTitle` prefers what is adopted here over what the caller
      // supplied, because the adopted thread is the one actually on screen.
      _resolvedPostId = postId;
      _resolvedPostTitle = postTitle;
    });
    _beginExistingChat();
    unawaited(_loadPartner());
    // The post context just changed under us; refresh what depends on it.
    _ensureChatPost().then((_) => _refreshJob(postAlreadyFresh: true));
    // The outbox is keyed by chat id, which was unknown until now: show what
    // an earlier session queued here, then give anything composed while the
    // conversation was unresolved its place on disk. Load BEFORE persisting,
    // or the in-memory queue would overwrite the one on disk.
    await _loadOutbox();
    if (mounted && _pendingMessages.isNotEmpty) _persistOutbox();
  }

  /// Resolve "does a conversation already exist?" when the caller had no id.
  ///
  /// Read-only — creates nothing. A failed lookup resolves to `unresolved`,
  /// never to `absent`: offline, offering "Start the conversation" would invite
  /// a second conversation beside one that already exists.
  Future<void> _resolveExistingChat() async {
    final otherId = widget.conversation.participantId;
    if (otherId.isEmpty) {
      if (mounted) {
        setState(() {
          _resolution = ChatResolution.absent;
          _loadingMessages = false;
        });
      }
      return;
    }

    // The chat database first. A conversation this phone already holds opens
    // with no request at all — offline included — under the same identity
    // rules the server lookup applies: this post's own thread, or the most
    // recently active one for a profile entry point.
    final local = await ChatStore.instance.findConversationFor(
      widget.currentUserId,
      otherId,
      postId: widget.conversation.postId,
      mostRecent: widget.resolveMostRecent,
    );
    if (!mounted) return;
    if (local != null) {
      debugPrint('[CHAT][RESOLVED] stored chatId=${local.id} '
          'postId=${local.postId ?? 'null'} mostRecent=${widget.resolveMostRecent}');
      await _adoptExistingChat(local.id, postId: local.postId, postTitle: local.postTitle);
      return;
    }

    // No post context (Provider Profile) → continue the most recent thread.
    // Otherwise resolve this post's own conversation (§D2).
    final result = widget.resolveMostRecent
        ? await ChatServiceSupabase.findMostRecentChatForPair(
            userAId: widget.currentUserId,
            userBId: otherId,
          )
        : await ChatServiceSupabase.findExistingChat(
            user1Id: widget.currentUserId,
            user2Id: otherId,
            // The ENTRY POINT's post, not `_postId` — this is the lookup key,
            // and nothing has been adopted yet.
            postId: widget.conversation.postId,
          );

    if (!mounted) return;

    final row = result.row;
    final foundId = (row?['id'] ?? '').toString();
    final resolution = chatResolutionFor(
      knownId: false,
      lookupDone: true,
      lookupSucceeded: result.ok,
      found: foundId.isNotEmpty,
    );

    if (resolution == ChatResolution.existing) {
      debugPrint(
        '[CHAT][RESOLVED] existing chatId=$foundId '
        'postId=${ChatServiceSupabase.postIdOf(row) ?? 'null'} mostRecent=${widget.resolveMostRecent}',
      );
      // BOTH lookups carry the join (ChatServiceSupabase.chatRowSelect), so
      // this recovers the post name by itself instead of depending on the
      // entry point to have brought one.
      await _adoptExistingChat(
        foundId,
        postId: ChatServiceSupabase.postIdOf(row),
        postTitle: ChatServiceSupabase.postTitleOf(row),
      );
      return;
    }

    debugPrint(
      '[CHAT][RESOLVED] $resolution participant=$otherId '
      'postId=${widget.conversation.postId ?? 'null'} '
      'mostRecent=${widget.resolveMostRecent}',
    );
    setState(() {
      _resolution = resolution;
      _loadingMessages = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _openWatch.start();
    WidgetsBinding.instance.addObserver(this);
    // Read here, not in dispose(): the element is active now and defunct then.
    _appProvider = context.read<AppProvider>();
    _activeChatId = widget.conversation.id;
    // The database first: who this is, and anything written by a sync or a
    // push while the screen is open.
    unawaited(_loadPartner());
    _storeSub = ChatStore.instance.changes.listen(_onStoreChange);
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTypingChanged);
    // Offline outbox: restore anything queued in a previous session and resend
    // automatically whenever the connection comes back.
    //
    // The store is started here as well as by AppProvider: a chat opened cold
    // from a notification can arrive before the conversation list ever loads,
    // and the retry signal below is only fed once the store has an owner.
    // Idempotent per uid.
    unawaited(OutboxStore.instance.start(widget.currentUserId));
    _loadOutbox();
    // The reconnect edge AND the store's short transient-retry timer — one
    // signal, so this thread and every other thread retry on the same cue.
    _reconnectSub = OutboxStore.instance.retrySignal.listen((_) {
      if (mounted) _flushOutbox();
    });
    if (_chatId.isNotEmpty) {
      _resolution = ChatResolution.existing;
      _beginExistingChat();
    } else {
      // The id being unknown is NOT proof that no conversation exists — that
      // conflation was the bug (§D1). Ask, and show progress while asking.
      _resolution = ChatResolution.resolving;
      _loadingMessages = true;
      unawaited(_resolveExistingChat());
    }
    // Presence seeded from the conversation list (already fetched there);
    // refreshed live while the chat is open.
    _seedOnlineStatusFromConversation();
    _loadOnlineStatus();
    // Both chat pollers park while offline and resume with one immediate run.
    // At 3s and 30s they were the app's chattiest timers, and neither can
    // possibly succeed without a network — a chat open in a tunnel used to fire
    // roughly twenty doomed requests a minute.
    _onlineStatusPoll = AdaptivePoll(
      interval: const Duration(seconds: 30),
      onTick: () {
        if (mounted) _loadOnlineStatus();
      },
      debugLabel: 'chat/presence',
      // _loadOnlineStatus() was just called directly above.
      tickOnStart: false,
    )..start();
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
    _ensureChatPost().then((_) => _refreshJob(postAlreadyFresh: true));
    // The pinned job bar: the memo paints it at once, the poll keeps it
    // honest. Parks while offline; one immediate refresh on reconnect.
    final memoPost = _postId;
    if (memoPost != null) _lifecycle = _lifecycleMemo[memoPost];
    _jobPoll = AdaptivePoll(
      interval: const Duration(seconds: 30),
      onTick: () {
        if (mounted) _refreshJob();
      },
      debugLabel: 'chat/job',
      tickOnStart: false,
    )..start();
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
    // Rebuild key = everything the journey UI can actually show. The route
    // parts are NOT optional: without them a newly-arrived route changed no
    // other field on a stationary device, the key compared equal, setState was
    // skipped, and the ETA never appeared even though the engine had it.
    // Bucketed so the filter still does its job — route identity changes ~once
    // per 90s, and the ETA is rendered in whole minutes.
    final key = '${s.state.name}:${s.messageId ?? ''}:'
        '${s.distanceToDestinationM == null ? '' : (s.distanceToDestinationM! / 25).round()}:'
        '${s.route?.computedAt.millisecondsSinceEpoch ?? 0}:'
        '${s.etaSeconds == null ? '' : (s.etaSeconds! / 60).round()}';
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
    // Back from paying (or anywhere): the job may have moved on.
    _refreshJob();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear active chat so notifications resume for other chats.
    //
    // Through the captured reference, NEVER `context.read` — this line used to
    // throw on every close, and because it sits second in dispose() it took
    // everything below it with it: the realtime subscription, the chats-row
    // channel, six timers, the journey listener and the cache flush all
    // leaked. Measured on an A21s: five chats opened and closed left five live
    // watchMessages channel pairs, each still running its own backoff loop.
    _appProvider.setActiveChatId(null);
    _storeSub?.cancel();
    _storeMerge?.cancel();
    _realtimeSubscription?.cancel();
    _chatRowChannel?.unsubscribe();
    _typingExpireTimer?.cancel();
    _typingPoll?.dispose();
    _typingDebounce?.cancel();
    _typingClearTimer?.cancel();
    _onlineStatusPoll?.dispose();
    _jobPoll?.dispose();
    // Deliberately NOT stopping the journey: it belongs to the engine and
    // keeps sharing while the user navigates elsewhere in the app.
    JourneyEngine.instance.listenable.removeListener(_onJourneyChanged);
    _journeyEvents?.cancel();
    _journeyUiTimer?.cancel();
    _reconnectSub?.cancel();
    // Flush any pending thread-cache write so the last messages of the
    // session are on disk for the next instant open.
    _cacheSaveDebounce?.cancel();
    final pendingSave = _pendingCacheSave;
    if (pendingSave != null) {
      CacheService.saveMessages(
          widget.currentUserId, _chatId, _capForCache(pendingSave));
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

  /// The other person from the chat database, and the conversation's own copy
  /// of their name. Re-run when a sync or an avatar download changes them.
  Future<void> _loadPartner() async {
    final uid = widget.currentUserId;
    final partnerId = widget.conversation.participantId;
    if (uid.isEmpty || partnerId.isEmpty) return;
    final person = await ChatStore.instance.person(uid, partnerId);
    final stored = _chatId.isEmpty ? null : await ChatStore.instance.conversation(uid, _chatId);
    if (!mounted) return;
    setState(() {
      _partner = person;
      _storedPartnerName = ChatPeople.knownOrNull(stored?.userName);
      final profession = person?.profession;
      if ((_partnerProfession ?? '').isEmpty && profession != null && profession.isNotEmpty) {
        _partnerProfession = profession;
      }
      final seen = person?.lastSeen;
      if (_onlineStatus.isEmpty && seen != null) _onlineStatus = _lastSeenLabel(seen.toLocal());
    });
  }

  void _onStoreChange(ChatChange change) {
    if (!mounted) return;
    if (change.owner.isNotEmpty && change.owner != widget.currentUserId) return;
    if (change.people || change.all) unawaited(_loadPartner());
    if (_chatId.isNotEmpty && change.touchesThread(_chatId)) {
      // Coalesce a burst (a page, then its outbox clean-up) into one read.
      _storeMerge?.cancel();
      _storeMerge = Timer(const Duration(milliseconds: 60), () => unawaited(_mergeFromStore()));
    }
  }

  /// Fold what the database holds for this thread into what is on screen —
  /// messages a sync or a push stored while the screen was open. By id, so a
  /// message already shown is only replaced when the stored copy differs.
  Future<void> _mergeFromStore() async {
    if (_chatId.isEmpty) return;
    final stored = await ChatStore.instance.loadThread(
      widget.currentUserId,
      _chatId,
      limit: _messages.length > 100 ? _messages.length : 100,
    );
    if (!mounted || stored.isEmpty) return;
    final byId = {for (final m in _messages) m.id: m};
    var changed = false;
    for (final m in stored) {
      final current = byId[m.id];
      if (current == null || !_sameMessage(current, m)) {
        byId[m.id] = m;
        changed = true;
      }
    }
    if (!changed) return;
    final merged = byId.values.toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    ChatAttachmentCache.evictDeleted(merged);
    setState(() {
      _messages = merged;
      _loadingMessages = false;
      _loadFailed = false;
    });
  }

  /// Whether two copies of one message would render the same.
  static bool _sameMessage(Message a, Message b) =>
      a.id == b.id &&
      a.text == b.text &&
      a.status == b.status &&
      a.seenAt == b.seenAt &&
      a.deliveredAt == b.deliveredAt &&
      a.deletedForEveryone == b.deletedForEveryone &&
      a.liveUntil == b.liveUntil &&
      a.latitude == b.latitude &&
      a.longitude == b.longitude &&
      a.attachmentUrl == b.attachmentUrl;

  /// The pinned job bar as the chat database last saw it — the post and its
  /// lifecycle — so an offline open shows the real stage and price instead of
  /// "No job agreed yet". The live refresh replaces it as soon as it can.
  Future<void> _restoreJobSnapshot() async {
    if (_chatId.isEmpty || (_lifecycle != null && _chatPost != null)) return;
    final snapshot = await ChatStore.instance.jobSnapshot(widget.currentUserId, _chatId);
    if (!mounted || snapshot == null) return;
    final post = snapshot['post'];
    final lifecycle = snapshot['lifecycle'];
    setState(() {
      if (_chatPost == null && post is Map) {
        _chatPost = PostModel.fromJson(Map<String, dynamic>.from(post));
      }
      if (_lifecycle == null && lifecycle is Map) {
        _lifecycle = JobLifecycle.fromJson(Map<String, dynamic>.from(lifecycle));
      }
    });
  }

  /// Keep what the job bar was drawn from, for the next offline open.
  void _persistJobSnapshot({Map<String, dynamic>? lifecycleJson}) {
    if (_chatId.isEmpty) return;
    final post = _chatPost;
    if (post == null && lifecycleJson == null) return;
    unawaited(ChatStore.instance.saveJobSnapshot(widget.currentUserId, _chatId, {
      if (post != null) 'post': post.toCacheMap(),
      if (lifecycleJson != null) 'lifecycle': lifecycleJson,
    }));
  }

  /// Instant open: hydrate the thread from the on-device cache written by
  /// previous sessions. Runs before the realtime initial page returns; if
  /// realtime wins the race its fresher data is kept.
  Future<void> _hydrateFromCache() async {
    final cached = await CacheService.loadMessages(_chatId, widget.currentUserId);
    if (!mounted || cached.isEmpty) return;
    // A deletion that reached this device in an earlier session (or offline)
    // still removes the local copy of its photo or document.
    ChatAttachmentCache.evictDeleted(cached);
    if (_messages.isNotEmpty) return; // realtime already delivered
    setState(() {
      _messages = cached;
      _loadingMessages = false;
      _hasMoreOlder = cached.length >= 30;
    });
    _loggedFirstPaint = true;
    _logPaint('CACHE_PAINT', cached.length);
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
      // An EMPTY emission must never wipe what's already on screen. Offline, the
      // fetch behind a resync yields nothing (the error is swallowed into an
      // empty page), and a resync always emits — so without this guard a
      // background refresh while offline would replace a cached, readable thread
      // with the "Start the conversation" empty state. Keep the history; only a
      // real, non-empty update ever changes it.
      if (messages.isEmpty) {
        setState(() {
          _loadingMessages = false;
          _loadFailed = false;
        });
        return;
      }
      // Merge with older messages already on screen — from pagination or from
      // the cache hydration — so the visible history never shrinks to the
      // realtime window size.
      final List<Message> merged;
      if (_messages.isNotEmpty) {
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
      // The server now has these rows, so any queued copy of them is done —
      // whichever sender delivered it (this screen, or OutboxStore draining
      // the thread before it was opened). The queued id names the row
      // exactly, so this is a match, not a guess.
      final deliveredIds = {for (final m in messages) m.id};
      final queuedBefore = _pendingMessages.length;
      // "Delete for everyone" arrives here as a realtime UPDATE (or in a fresh
      // page after reconnecting): the attachment's local copies go with it.
      ChatAttachmentCache.evictDeleted(messages);
      setState(() {
        _messages = merged;
        _loadingMessages = false;
        _loadFailed = false; // a successful emission clears any prior failure
        _hasMoreOlder = messages.length >= 30;
        _pendingMessages.removeWhere((p) {
          final serverId = OutboxIds.serverIdOf(p.id);
          return serverId != null && deliveredIds.contains(serverId);
        });
      });
      if (_pendingMessages.length != queuedBefore) _persistOutbox();
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
        _logPaint(_loggedFirstPaint ? 'NET_REFRESH' : 'NET_PAINT', messages.length);
        _loggedFirstPaint = true;
        // Initial page. The reversed list is already anchored on the newest
        // message — no scroll command needed.
        _lastMessageCount = messages.length;
        _markSeenNow();
      } else if (hadNew) {
        final arrived = messages.length - _lastMessageCount;
        _lastMessageCount = messages.length;
        // Follow along only when the user is already near the bottom — don't
        // hijack their position while they read older messages. Up there,
        // the scroll-down button counts what arrived instead.
        if (_isNearBottom) {
          _scrollToBottom();
        } else if (messages.isNotEmpty && !messages.last.isMe) {
          setState(() => _unseenBelow += arrived);
        }
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
            // Realtime proved itself — the fallback poll is redundant.
            _typingPoll?.dispose();
            _typingPoll = null;
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

  /// Bound each write-through to the newest 60: older rows on screen came from
  /// the database or from [_loadOlderMessages], which stores its own pages, so
  /// re-writing them on every realtime burst would only cost time.
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
        final chatId = _chatId;
        final uid = widget.currentUserId;
        // Into the database, then make sure its photos have thumbnails on
        // this phone — the copy an offline open draws.
        CacheService.saveMessages(uid, chatId, _capForCache(messages)).then((_) {
          if (!NetworkHealth.isOffline) {
            unawaited(ChatMediaStore.ensureThumbs(uid, [chatId], limit: 30));
          }
        });
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
    // Resolved BEFORE the await, while the element is certainly usable.
    //
    // `mounted` does not make `context` safe after an async gap: it stays true
    // through a window in which the element is already defunct, and reading a
    // provider off it then throws. Observed on the S20+ during the offline
    // messaging run:
    //   Unhandled Exception: Null check operator used on a null value
    //   #0 Element.widget  #2 Provider.of  #4 _ChatScreenState._markSeenNow
    // AppProvider lives above this route, so holding the reference across the
    // await is safe — it is the BuildContext that stops being safe, not the
    // provider.
    final app = context.read<AppProvider>();
    await ChatServiceSupabase.markMessagesSeen(_chatId, widget.currentUserId);
    // Zero out the local unread badge immediately without waiting for the
    // next conversation list poll.
    if (mounted) {
      app.markConversationRead(_chatId);
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
          .select('is_online, last_seen, profession')
          .eq('id', participantId)
          .maybeSingle();
      if (!mounted || row == null) return;
      final profession = row['profession']?.toString().trim();
      if (profession != _partnerProfession) {
        setState(() => _partnerProfession = profession);
      }
      final flaggedOnline = row['is_online'] as bool? ?? false;
      final lastSeen = parseServerTimeOrNull(row['last_seen']);
      // Remember what was learned, so the next offline open can say it.
      final known = _partner;
      if (known == null ||
          (profession != null && profession.isNotEmpty && profession != known.profession) ||
          (lastSeen != null && lastSeen != known.lastSeen)) {
        unawaited(ChatStore.instance.upsertPeople(
          widget.currentUserId,
          [
            ChatPerson(
              id: participantId,
              profession: (profession == null || profession.isEmpty) ? null : profession,
              lastSeen: lastSeen,
            ),
          ],
          profileKnown: false,
        ));
      }
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

  /// The header's second line: who this person is on Help24 — "Plumber ·
  /// ★ 4.8 · 34 jobs" for a provider, "Customer · Bamburi, Mombasa" for the
  /// customer — rather than when they last opened the app. Presence is the
  /// fallback when none of that is known. ("typing…" is the header's own.)
  String? _headerSubtitle() {
    final presence = _onlineStatus.isEmpty ? null : _onlineStatus;
    final role = chatPartnerRoleOf(
      viewerId: widget.currentUserId,
      partnerId: widget.conversation.participantId,
      postAuthorId: _chatPost?.authorUserId,
      postIsOffer: _chatPost?.type == PostType.offer,
      partnerHasProfession: (_partnerProfession ?? '').isNotEmpty,
      partnerCompletedJobs: _headerRep?.completedJobs ?? 0,
    );
    final rep = _headerRep;
    final line = chatPartnerLine(
      role: role,
      professionLabel: (_partnerProfession ?? '').isEmpty
          ? null
          : ProfessionRegistry.instance.labelFor(_partnerProfession),
      rating: rep != null && rep.hasReviews ? rep.averageRating : null,
      completedJobs: rep?.completedJobs ?? 0,
      area: _chatPost?.location,
    );
    return line ?? presence;
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
  ///
  /// The database first — history this phone already has costs no network
  /// and works on a plane — then the server, whose page is stored before it
  /// is shown, so it is there next time too.
  Future<void> _loadOlderMessages() async {
    if (_chatId.isEmpty || _loadingOlder || !_hasMoreOlder || _messages.isEmpty) return;
    final offline = NetworkHealth.isOffline;
    if (offline && _olderExhaustedOffline) return;
    if (!offline) _olderExhaustedOffline = false;
    _loadingOlder = true;
    final oldest = _messages.first.timestamp;
    const page = 30;
    try {
      final existingIds = _messages.map((m) => m.id).toSet();
      final stored = await ChatStore.instance.loadThread(
        widget.currentUserId,
        _chatId,
        limit: page,
        before: oldest,
      );
      var older = stored.where((m) => !existingIds.contains(m.id)).toList();
      var hasMore = true;
      if (older.length < page && !NetworkHealth.isOffline) {
        final result = await ChatServiceSupabase.fetchMessagesPage(
          _chatId,
          widget.currentUserId,
          before: (older.isEmpty ? oldest : older.first.timestamp).toUtc().toIso8601String(),
        );
        await CacheService.saveMessages(widget.currentUserId, _chatId, result.messages);
        final seen = {...existingIds, ...older.map((m) => m.id)};
        older = [...result.messages.where((m) => !seen.contains(m.id)), ...older]
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        hasMore = result.hasMore;
      } else if (older.length < page) {
        // Offline, and the database has nothing older. The server may; ask
        // again when a network is back.
        _olderExhaustedOffline = true;
      }
      if (!mounted) return;
      ChatAttachmentCache.evictDeleted(older);
      setState(() {
        _messages = older + _messages;
        _hasMoreOlder = hasMore;
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
    if (nearBottom != _isNearBottom || (nearBottom && _unseenBelow > 0)) {
      setState(() {
        _isNearBottom = nearBottom;
        if (nearBottom) _unseenBelow = 0;
      });
    }
    _updateStickyDay();
  }

  /// Which day the message at the top of the viewport belongs to — the pill
  /// pinned there while the thread scrolls.
  ///
  /// Read straight off the list's laid-out children: the reversed sliver puts
  /// offset 0 at the bottom, so the top edge is `pixels + viewport`, and the
  /// child spanning that offset names the row. Hidden when the row there is
  /// the day's own pill, so the same label is never shown twice.
  void _updateStickyDay() {
    final root = _listKey.currentContext?.findRenderObject();
    if (root == null || !_scrollController.hasClients || _entries.isEmpty) return;
    RenderSliverMultiBoxAdaptor? sliver;
    void find(RenderObject o) {
      if (sliver != null) return;
      if (o is RenderSliverMultiBoxAdaptor) {
        sliver = o;
        return;
      }
      o.visitChildren(find);
    }

    find(root);
    final list = sliver;
    if (list == null) return;
    final pos = _scrollController.position;
    DateTime? day;
    if (pos.maxScrollExtent > 0) {
      final top = pos.pixels + pos.viewportDimension - _kListPaddingBottom - 4;
      var child = list.firstChild;
      while (child != null) {
        final start = list.childScrollOffset(child) ?? 0;
        if (top >= start && top < start + child.size.height) {
          final index = list.indexOf(child);
          final row = index < _entries.length ? _entries[_entries.length - 1 - index] : null;
          day = switch (row) {
            ChatDayEntry() || null => null,
            ChatMessageEntry(:final message) => localDay(message.timestamp),
            ChatEventEntry(:final event) => localDay(event.at),
            ChatOfferEntry(:final offer) => localDay(offer.at),
          };
          break;
        }
        child = list.childAfter(child);
      }
    }
    if (day != _stickyDay) setState(() => _stickyDay = day);
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
        backgroundColor: AppColors.of(context).criticalFill,
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
        // The ENTRY POINT's post. Creation only happens when resolution found
        // nothing, so there is no adopted thread whose context could apply —
        // and Provider Profile (postId null) correctly creates the general one.
        postId: widget.conversation.postId,
        // So the row lands in the Messages tab already able to name its post,
        // instead of appearing without its 📌 until the next poll.
        postTitle: widget.conversation.postTitle,
      );
      if (!mounted) return false;
      setState(() {
        _activeChatId = conv.id;
        // ADOPT THE CREATED ROW'S OWN POST CONTEXT.
        //
        // `_insertChatRow` selects through `chatRowSelect`, so the row that
        // comes back already carries `posts(title)` whether or not the entry
        // point brought one. Reading it here closes the last way the post-name
        // invariant could be broken: a caller that knew `postId` but not
        // `postTitle` would create a genuinely post-scoped chat whose banner
        // stayed empty for the life of the screen — the Messages tab would
        // show the 📌 and the open conversation would not. No entry point does
        // that today; this makes it impossible for a new one to.
        _resolvedPostId ??= conv.postId;
        _resolvedPostTitle ??= conv.postTitle;
      });
      // Start realtime and typing now that the chat exists.
      _startRealtimeMessages();
      _startChatRowRealtime();
      _typingPoll ??= _makeTypingPoll()..start();
      // The captured provider, not `context.read`: this runs after awaits on
      // the send path, which the retry signal can drive while the element is
      // already unusable (see [_appProvider]).
      _appProvider
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
    await _sendText(text, fromComposer: true);
  }

  /// Every typed message — the composer, a quick reply, the arrival notice —
  /// goes into the thread through the outbox, so all of them wait out an
  /// outage the same way.
  Future<void> _sendText(String text, {bool fromComposer = false}) async {
    // Explained up front; the server refuses it regardless (migration 116).
    if (!RestrictionGate.allows(context, Capability.message)) return;

    // Capture reply state before clearing it. Only what was typed answers the
    // quoted message — a quick reply or the arrival notice is never a reply.
    final replyingTo = fromComposer ? _replyToMessage : null;
    if (fromComposer) _messageController.clear();
    _typingDebounce?.cancel();
    _typingClearTimer?.cancel();
    if (_chatId.isNotEmpty) {
      ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);
    }

    // The message enters the thread immediately as an outbox entry. It is never
    // discarded on failure — it stays visible (clock while queued, retry chip
    // when it fails) and is resent automatically on reconnect. So composing a
    // message offline is a normal, safe action, not an error.
    final optimistic = Message(
      // Minted once; the server row is inserted under the uuid inside it, so
      // no retry can ever store this message twice (see OutboxIds).
      id: OutboxIds.create(),
      conversationId: _chatId,
      senderId: widget.currentUserId,
      receiverId: '',
      text: text,
      timestamp: DateTime.now(),
      isMe: true,
      type: 'text',
      // Queued until a request is actually open for it — see [OutboxStatus].
      // `sending` used to cover both, so an offline message showed a spinner
      // for work that was not happening.
      status: OutboxStatus.queued,
      replyToId: replyingTo?.id,
      replyToSender: replyingTo == null
          ? null
          : (replyingTo.isMe ? 'You' : _partnerName),
      replyToPreview: replyingTo?.text.isEmpty == false
          ? replyingTo!.text.substring(0, replyingTo.text.length.clamp(0, 120))
          : null,
    );
    if (fromComposer) setState(() => _replyToMessage = null); // clear reply preview immediately
    await _enqueue([optimistic]);
  }

  /// EVERY OUTBOUND MESSAGE ENTERS THE THREAD HERE — text, photo, document,
  /// place, location request.
  ///
  /// It is on screen and persisted before any network work starts, so losing
  /// the connection can never lose it: offline it waits with a clock and goes
  /// out on the reconnect edge; online it is sent now. Photos, documents and
  /// places used to bypass this entirely and upload on the spot, which is why
  /// they could not be sent offline at all — a failed upload had nowhere to
  /// wait and was simply dropped.
  Future<void> _enqueue(List<Message> messages) async {
    if (messages.isEmpty) return;
    final hadQueue = _pendingMessages.isNotEmpty;
    if (mounted) {
      setState(() => _pendingMessages.addAll(messages));
    } else {
      _pendingMessages.addAll(messages);
    }
    _persistOutbox();
    _scrollToBottom();

    // Offline: don't burn a long timeout — leave it queued (clock) and reassure
    // the user it will go out on its own. Online: try now, in order.
    // One definition of offline for the whole send path — see `_attemptSend`.
    if (NetworkHealth.isOffline) {
      // Reassure once, not on every queued message — the clock on each bubble
      // already shows they're waiting to send.
      if (!hadQueue) {
        _showInfo("No internet — we'll send this when you're back online.");
      }
      return;
    }
    for (final m in messages) {
      await _attemptSend(m);
    }
  }

  /// Try to deliver one queued message. Removes it from the outbox on success;
  /// on failure, [OutboxStore.statusAfterFailure] decides between queued
  /// (waiting for a network, retried automatically) and failed (Retry). Safe
  /// to call repeatedly — an in-flight id is skipped.
  Future<void> _attemptSend(Message pending) async {
    // The claim is shared with OutboxStore, which drains every OTHER thread on
    // the reconnect edge. Two senders holding the same message is how one
    // message becomes two.
    if (OutboxStore.instance.isSending(pending.id)) return;

    // NetworkHealth, not `context.read<ConnectivityProvider>()`. Same verdict —
    // ConnectivityProvider is the only thing that publishes it — but reachable
    // without an Element.
    //
    // This path is driven by a STREAM, not by a tap. Device evidence: on the
    // reconnect edge, `_flushOutbox` reached here from a ChatScreen whose
    // element was already defunct and threw
    //   Unhandled Exception: Null check operator used on a null value
    //   #0  Element.widget  #2 Provider.of  #4 _ChatScreenState._attemptSend
    // which aborted the flush, and the queued message was still undelivered
    // afterwards. `mounted` did not protect it: the guard was true while the
    // element was already unusable. A send must not depend on a widget being
    // alive — the message belongs to the account, not to the screen.
    if (NetworkHealth.isOffline) {
      _updatePendingStatus(pending.id, OutboxStatus.queued);
      return;
    }

    if (!OutboxStore.instance.claimSend(pending.id)) return;
    _updatePendingStatus(pending.id, OutboxStatus.sending);
    // The CURRENT copy, not the one the caller captured: an earlier attempt
    // may have uploaded the file and recorded its URL on the queued message.
    final current = _pendingMessages.firstWhere(
      (m) => m.id == pending.id,
      orElse: () => pending,
    );
    try {
      // Lazy chat creation for a brand-new conversation's first message. Needs
      // the network, so it lives here: offline it fails and the message simply
      // stays queued for the next reconnect.
      if (_chatId.isEmpty && !await _ensureChatCreated()) {
        throw Exception('chat not created');
      }
      final confirmed = await OutboxDelivery.deliver(
        senderId: widget.currentUserId,
        chatId: _chatId,
        message: current,
        // Persisted at once, so a retry after this writes the row instead of
        // uploading the file again.
        onUploaded: (uploaded) {
          _replacePending(uploaded);
          _persistOutbox();
        },
      );
      OutboxStore.instance.clearFailures(pending.id);
      // Clear it from the outbox FIRST, even if the screen has since closed —
      // the send succeeded, so it must never be resent (that would duplicate the
      // message). UI updates below are best-effort and only when still mounted.
      _pendingMessages.removeWhere((m) => m.id == pending.id);
      _persistOutbox();
      if (!mounted) return;
      setState(() {
        // Add the confirmed row directly — don't rely on realtime for own messages.
        if (!_messages.any((m) => m.id == confirmed.id)) {
          _messages = [..._messages, confirmed];
        }
      });
      _scheduleCacheSave(_messages);
      _scrollToBottom();
    } catch (e) {
      final withdrawn = OutboxIds.serverIdOf(pending.id);
      if (withdrawn != null && ChatUploads.isCancelled(withdrawn)) {
        // Stopped by the user ([_cancelPending] already took it out of the
        // queue). Not a failure, so no status and no retry.
        debugPrint('[CHAT][SEND] ${pending.id} withdrawn by the user');
        return;
      }
      if (e is PostgrestException) {
        debugPrint('[CHAT][SEND] ${pending.type} postgrest code=${e.code} msg=${e.message}');
      } else {
        debugPrint('[CHAT][SEND] ${pending.type} failed: $e');
      }
      final next = OutboxStore.instance.statusAfterFailure(pending.id, e);
      debugPrint('[CHAT][SEND] ${pending.id} → $next');
      _updatePendingStatus(pending.id, next);
      _persistOutbox();
    } finally {
      OutboxStore.instance.releaseSend(pending.id);
    }
  }

  void _replacePending(Message updated) {
    final i = _pendingMessages.indexWhere((m) => m.id == updated.id);
    if (i == -1) return;
    // Keep the live status: the copy handed back mid-send predates it.
    final next = updated.copyWith(status: _pendingMessages[i].status);
    if (mounted) {
      setState(() => _pendingMessages[i] = next);
    } else {
      _pendingMessages[i] = next;
    }
  }

  /// Send every queued/failed message, oldest first, preserving order. Fired on
  /// reconnect and when the thread opens online.
  Future<void> _flushOutbox() async {
    if (_pendingMessages.isEmpty) return;
    final queue = _pendingMessages
        .where((m) => !OutboxStore.instance.isSending(m.id))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final m in queue) {
      if (!mounted) break;
      await _attemptSend(m);
    }
  }

  /// Stop sending a queued or uploading photo or document: its upload is
  /// abandoned at the next chunk, it leaves the outbox, and its queued copy is
  /// deleted. Only a message the server does not have yet can be stopped —
  /// once its row is written it is delivered, and "delete for everyone" is
  /// the way back.
  void _cancelPending(Message m) {
    final id = OutboxIds.serverIdOf(m.id);
    if (id != null) ChatUploads.cancel(id);
    setState(() => _pendingMessages.removeWhere((p) => p.id == m.id));
    _persistOutbox();
    unawaited(OutboxFiles.discard(m.localPath));
    _showInfo(m.isImage ? 'Photo not sent.' : 'Document not sent.');
  }

  /// Manual retry from a failed message's "Not sent. Tap to retry". A
  /// deliberate retry gets a fresh transient budget.
  void _retryPending(Message m) {
    OutboxStore.instance.clearFailures(m.id);
    _updatePendingStatus(m.id, OutboxStatus.sending);
    _attemptSend(m);
  }

  void _updatePendingStatus(String id, String status) {
    final i = _pendingMessages.indexWhere((m) => m.id == id);
    if (i == -1 || _pendingMessages[i].status == status) return;
    final updated = _pendingMessages[i].copyWith(status: status);
    if (mounted) {
      setState(() => _pendingMessages[i] = updated);
    } else {
      _pendingMessages[i] = updated;
    }
  }

  void _persistOutbox() {
    // Keyed by chat id; a brand-new conversation has none yet, so its queue
    // lives in memory until the chat row exists (created on the first flush).
    if (_chatId.isEmpty) return;
    final queue = List<Message>.of(_pendingMessages);
    CacheService.saveOutbox(widget.currentUserId, _chatId, queue);
    // THE SINGLE CHOKE POINT. Every add, status change and successful send
    // passes through here, so publishing from this one place is what lets the
    // Messages tab show an unsent message without this screen knowing the tab
    // exists — and what clears the pending preview the moment it is delivered.
    OutboxStore.instance.publish(widget.currentUserId, _chatId, queue);
  }

  /// Restore messages queued in a previous session and drain them if online.
  Future<void> _loadOutbox() async {
    if (_chatId.isEmpty) return;
    final queued = await CacheService.loadOutbox(_chatId, widget.currentUserId);
    if (!mounted || queued.isEmpty) return;
    setState(() {
      for (final m in queued) {
        if (!_pendingMessages.any((p) => p.id == m.id)) _pendingMessages.add(m);
      }
    });
    if (!NetworkHealth.isOffline) {
      _flushOutbox();
    }
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Pick → REVIEW → send. Nothing is uploaded until the user presses send in
  /// the composer: picking an image is not the same as deciding to send it,
  /// and photos here are often evidence (damage, receipts, meter readings)
  /// where sending the wrong shot has real consequences.
  ///
  /// Nothing here needs the network: the gallery, the composer and the queue
  /// are all on the device. The chat row is created lazily by the send path,
  /// exactly as for text, so a photo can be composed in a tunnel.
  Future<void> _pickAndSendImage() async {
    List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage(maxWidth: 1024, imageQuality: 85);
    } catch (e) {
      debugPrint('ChatScreen pickMultiImage: $e');
      if (mounted) _showError('Could not open your gallery.');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final composed = await Navigator.of(context).push<ComposedImages>(
      MaterialPageRoute(
        builder: (_) => ImageComposerScreen(
          initialFiles: picked,
          partnerName: _partnerName,
        ),
      ),
    );
    if (composed == null || composed.files.isEmpty || !mounted) return;
    await _queueComposedImages(composed);
  }

  /// The composer's camera: take a photo, review it in the same composer as a
  /// picked one, then queue it. Like the gallery, nothing here needs a
  /// network.
  Future<void> _takePhoto() async {
    if (_isSending) return;
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        imageQuality: 85,
      );
    } catch (e) {
      debugPrint('ChatScreen camera: $e');
      if (mounted) _showError('Could not open the camera.');
      return;
    }
    if (shot == null || !mounted) return;
    final composed = await Navigator.of(context).push<ComposedImages>(
      MaterialPageRoute(
        builder: (_) => ImageComposerScreen(
          initialFiles: [shot!],
          partnerName: _partnerName,
        ),
      ),
    );
    if (composed == null || composed.files.isEmpty || !mounted) return;
    await _queueComposedImages(composed);
  }

  /// Each photo becomes its own queued message, so a failure part-way leaves
  /// the others delivered rather than holding the batch hostage — and the
  /// caption rides the first one, matching how every messenger treats a
  /// captioned set. Each is copied out of the picker's cache into durable
  /// app storage BEFORE it is queued: the queue outlives this screen, and the
  /// cache can be cleared under it.
  Future<void> _queueComposedImages(ComposedImages composed) async {
    final queued = <Message>[];
    var skipped = 0;
    final now = DateTime.now();
    for (var i = 0; i < composed.files.length; i++) {
      final file = composed.files[i];
      final id = OutboxIds.create();
      try {
        if (await file.length() > ChatAttachments.maxBytes) {
          skipped++;
          continue;
        }
        final local = await OutboxFiles.adopt(
          sourcePath: file.path,
          uid: widget.currentUserId,
          messageId: id,
          name: file.name,
        );
        queued.add(Message(
          id: id,
          conversationId: _chatId,
          senderId: widget.currentUserId,
          text: ChatServiceSupabase.attachmentContent(
              'image', queued.isEmpty ? composed.caption : ''),
          // A millisecond apart, so the set keeps its order on screen and in
          // the queue (both sort by timestamp).
          timestamp: now.add(Duration(milliseconds: i)),
          isMe: true,
          type: 'image',
          status: OutboxStatus.queued,
          localPath: local,
        ));
      } catch (e) {
        debugPrint('ChatScreen queue photo [$i]: $e');
        skipped++;
      }
    }
    if (skipped > 0 && mounted) {
      _showError(queued.isEmpty
          ? "We couldn't prepare your photos. Please try again."
          : "$skipped of ${composed.files.length} photos couldn't be prepared.");
    }
    await _enqueue(queued);
  }

  /// Opens a sent or received photo fullscreen. The hero tag is the message id,
  /// which is stable and unique, so the thumbnail lifts into the viewer.
  void _openImageViewer(Message message) {
    final url = message.attachmentUrl;
    if (url == null || url.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageViewerScreen(
          // The photo is read through the files endpoint, by message, from
          // the same private cache the thumbnail filled.
          imageUrl: ChatAttachments.urlFor(message.id).toString(),
          cacheKey: ChatAttachments.cacheKeyFor(message.id),
          cacheManager: ChatAttachmentCache.instance,
          heroTag: 'chat_image_${message.id}',
          caption: message.text == 'Image' ? null : message.text,
        ),
      ),
    );
  }

  /// Pick a document and queue it. Like a photo, nothing here needs the
  /// network — it used to wait on a session exchange before the picker would
  /// even open, and then upload on the spot, so offline the document was lost.
  Future<void> _pickAndSendFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx'],
        withData: false,
      );
    } catch (e) {
      debugPrint('ChatScreen pickFiles: $e');
      if (mounted) _showError('Could not open your files.');
      return;
    }
    if (result == null || result.files.isEmpty || !mounted) return;
    final platformFile = result.files.single;
    final path = platformFile.path;
    if (path == null || path.isEmpty) {
      _showError('Could not access file.');
      return;
    }
    // Refused here, not in the queue: a file over the limit can never be
    // sent, and queueing it would only fail later with less to say.
    if (platformFile.size > ChatAttachments.maxBytes) {
      _showError('This file is too large to send. The limit is 10 MB.');
      return;
    }
    final id = OutboxIds.create();
    final String local;
    try {
      local = await OutboxFiles.adopt(
        sourcePath: path,
        uid: widget.currentUserId,
        messageId: id,
        name: platformFile.name,
      );
    } catch (e) {
      debugPrint('ChatScreen queue document: $e');
      if (mounted) _showError('Could not access file.');
      return;
    }
    await _enqueue([
      Message(
        id: id,
        conversationId: _chatId,
        senderId: widget.currentUserId,
        text: ChatServiceSupabase.attachmentContent('file', platformFile.name),
        timestamp: DateTime.now(),
        isMe: true,
        type: 'file',
        status: OutboxStatus.queued,
        localPath: local,
      ),
    ]);
  }

  /// Single attach entry point: photo, document and location all live here
  /// (the composer keeps one button instead of two).
  void _showAttachmentOptions() {
    if (_isSending) return;
    final chat = ChatColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.of(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.sheetTop,
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
                icon: AppIcons.gallery,
                color: chat.accentText,
                title: 'Photo',
                subtitle: 'From your gallery',
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendImage();
                },
              ),
              _AttachOption(
                icon: AppIcons.fileGeneric,
                color: chat.accentText,
                title: 'Document',
                subtitle: 'PDF, Word or CV',
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendFile();
                },
              ),
              _AttachOption(
                icon: AppIcons.location,
                color: chat.success,
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
        icon: AppIcons.location,
        label: 'Share location',
        onTap: _respondToLocationRequest,
      );
    }
    // While a journey is live the strip owns the journey controls.
    if (_activeJourney != null || _journey.isLive) return null;
    // 2) I'm the traveller for this job and the trip hasn't started.
    if (_chatPost != null && _travellerFirst) {
      return (
        icon: AppIcons.route,
        label: 'On my way',
        onTap: _startJourneyFlow,
      );
    }
    // 3) The provider just arrived and I'm the customer: close the loop.
    // ReviewService/backend stays the gatekeeper of review validity.
    final postId = _postId;
    if (_chatPost != null &&
        !_travellerFirst &&
        postId != null &&
        postId.isNotEmpty &&
        _recentlyArrivedJourney) {
      return (
        icon: AppIcons.reviewFilled,
        label: 'Rate ${_partnerName}',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ReviewSubmissionScreen(
                postId: postId,
                clientUserId: widget.currentUserId,
                postTitle: _postTitle,
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
    final postId = _postId;
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
    // A journey is LIVE — it streams the traveller's position as they move —
    // so it is the one location intent that cannot wait in the queue: sent
    // later, "on my way" would describe a moment that has passed. Say so, and
    // offer the intent that can wait. Without this the engine tried, failed,
    // and blamed "something on our side".
    if (NetworkHealth.isOffline) {
      await _showJourneyBlocked(
        icon: AppIcons.unreachable,
        title: "You're offline",
        body: 'Sharing your journey needs a connection, because it sends your '
            'position as you move. You can send a place instead — it will go '
            "out as soon as you're back online.",
        actionLabel: 'Send a place',
        onAction: _openPlacePicker,
      );
      return;
    }
    await _ensureChatPost();
    if (!mounted) return;
    final post = _chatPost;
    final dest = _journeyDestination();
    final start = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => JourneyConfirmScreen(
          destination: dest == null ? null : LatLng(dest.latitude, dest.longitude),
          destinationTitle: _postTitle ?? post?.title ?? 'This job',
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

  /// A place is a pin the user chose on the map — a spot, not a claim about
  /// where they are right now — so it keeps its meaning however long it waits
  /// in the queue. Queued like any other message: picked offline (the picker
  /// works from GPS and a draggable pin), it goes out on reconnect.
  Future<void> _sendPickedPlace(PickedPlace place) async {
    final label = place.label.trim();
    await _enqueue([
      Message(
        id: OutboxIds.create(),
        conversationId: _chatId,
        senderId: widget.currentUserId,
        text: label.isEmpty ? 'Location' : label,
        timestamp: DateTime.now(),
        isMe: true,
        type: 'location',
        latitude: place.latitude,
        longitude: place.longitude,
        status: OutboxStatus.queued,
      ),
    ]);
  }

  /// "Request location": sends immediately — no second UI (by design). It
  /// carries no coordinates, so it can wait in the queue like text.
  Future<void> _sendLocationRequest() async {
    await _enqueue([
      Message(
        id: OutboxIds.create(),
        conversationId: _chatId,
        senderId: widget.currentUserId,
        text: 'Location requested',
        timestamp: DateTime.now(),
        isMe: true,
        type: 'location_request',
        status: OutboxStatus.queued,
      ),
    ]);
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
        // The journey is a commitment; a short confirmation makes it land
        // physically as well as visually.
        HapticFeedback.mediumImpact();
        _scrollToBottom();
        break;
      case JourneyStartResult.permissionRequired:
        JourneyEngine.instance.acknowledgeIdle();
        await _showJourneyBlocked(
          icon: AppIcons.locationOff,
          title: 'Location access is off',
          body: 'Help24 needs your location to share your journey with '
              '${_partnerName.isEmpty ? 'them' : _partnerName}. '
              'You can turn it on in Settings — nothing is shared until you start a journey.',
          actionLabel: 'Open settings',
          onAction: ph.openAppSettings,
        );
        break;
      case JourneyStartResult.serviceDisabled:
        JourneyEngine.instance.acknowledgeIdle();
        await _showJourneyBlocked(
          icon: AppIcons.currentLocationOff,
          title: 'Location is turned off',
          body: 'Your device location is switched off, so we can\'t follow your '
              'journey. Turn it on and try again.',
          actionLabel: 'Location settings',
          onAction: Geolocator.openLocationSettings,
        );
        break;
      case JourneyStartResult.failed:
        JourneyEngine.instance.acknowledgeIdle();
        await _showJourneyBlocked(
          icon: AppIcons.warning,
          title: "Couldn't start the journey",
          body: 'Something went wrong on our side. Check your connection and '
              'try again — you can also just send a place instead.',
          actionLabel: 'Try again',
          onAction: () async {
            if (mounted) await _startJourneyFlow();
          },
        );
        break;
    }
  }

  /// A blocked journey is a dead end unless we hand back a way forward, so
  /// every failure states what happened, what it means for sharing, and the
  /// one action that resolves it. Replaces terse snackbars that explained the
  /// problem but left the user with nowhere to go.
  Future<void> _showJourneyBlocked({
    required IconData icon,
    required String title,
    required String body,
    required String actionLabel,
    required Future<void> Function() onAction,
  }) async {
    HapticFeedback.heavyImpact();
    if (!mounted) return;
    final colors = AppColors.of(context);
    final act = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(icon, size: 28, color: colors.cautionText),
        title: Text(title, textAlign: TextAlign.center),
        content: Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(height: 1.4, color: colors.contentSecondary),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    if (act == true) await onAction();
  }

  Future<void> _stopLiveSharing() async {
    HapticFeedback.selectionClick();
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
    // Arrival is the journey's payoff — and with auto-arrival it can happen
    // while the phone is in a pocket, so it deserves a distinct physical cue
    // rather than only a visual one.
    HapticFeedback.mediumImpact();
    final partner = _partnerName.trim();
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
      // Through the outbox like any message, so it survives a dead zone at
      // the gate. The thread draws it as an "arrived" event pill.
      await _sendText(kArrivalNoticeText);
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
      onInfo: () => showMessageInfo(context, message),
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
      onReport: message.isMe ? null : () => _openReportSheet(message: message),
    );
  }

  /// Report the person (from the menu) or one message they sent (from the
  /// long-press). The server derives who is reported from the target and
  /// keeps the chat/listing context only when both people are really in it.
  void _openReportSheet({Message? message}) {
    if (widget.conversation.participantId.isEmpty) return;
    final target = message != null && !message.isMe && !message.id.startsWith('pending_')
        ? ReportTarget.message(messageId: message.id, senderName: _partnerName)
        : ReportTarget.user(
            userId: widget.conversation.participantId,
            name: _partnerName,
            chatId: _chatId.isNotEmpty ? _chatId : null,
            postId: _postId,
          );
    ReportSheet.show(context, target);
  }

  /// Dispatch for the three-dot conversation command menu.
  void _onMenuAction(ChatMenuAction action) {
    final postId = _postId;
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
            postTitle: _postTitle,
          );
        }
      case ChatMenuAction.search:
        if (_chatId.isEmpty) return;
        ConversationSearchSheet.show(
          context,
          chatId: _chatId,
          currentUserId: widget.currentUserId,
          partnerName: _partnerName,
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
    final colors = AppColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        title: const Text(
          'Clear conversation?',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Messages will be removed from this device only. '
          '${_partnerName} keeps their copy.',
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Clear',
              style: TextStyle(color: colors.criticalText, fontWeight: FontWeight.w600),
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
    await CacheService.clearMessages(widget.currentUserId, _chatId);
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
    if (result == DeleteForEveryoneResult.success && (message.isImage || message.isFile)) {
      // The sender's own copy goes too — even if this screen has closed.
      unawaited(ChatAttachmentCache.evict(message.id));
    }
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

  // ── The pinned job bar ─────────────────────────────────────────────────────

  bool _jobRefreshing = false;

  /// Whether this chat is between the job's customer and its SELECTED
  /// provider — the only pair the lifecycle belongs to.
  bool get _chatIsTheJob {
    final post = _chatPost;
    if (post == null) return false;
    final me = widget.currentUserId;
    final partner = widget.conversation.participantId;
    final selected = (post.selectedProviderUserId ?? '').trim();
    return selected.isNotEmpty &&
        ((post.authorUserId == me && partner == selected) ||
            (me == selected && partner == post.authorUserId));
  }

  /// Re-read the post (who is selected can change) and, when this chat is the
  /// job's own pair, the lifecycle aggregate. A failure keeps what is shown —
  /// the bar never goes blank because a poll missed.
  Future<void> _refreshJob({bool postAlreadyFresh = false}) async {
    final postId = _postId;
    if (postId == null || postId.isEmpty || _jobRefreshing) return;
    _jobRefreshing = true;
    try {
      if (!postAlreadyFresh) {
        final fresh = await PostService.getPostById(postId);
        if (!mounted) return;
        if (fresh != null) setState(() => _chatPost = fresh);
      }
      if (!_chatIsTheJob) {
        if (_lifecycle != null && mounted) setState(() => _lifecycle = null);
        _persistJobSnapshot();
        return;
      }
      final json = await JobsService.getLifecycleJson(postId: postId, userId: widget.currentUserId);
      final lifecycle = JobLifecycle.fromJson(json);
      if (!mounted) return;
      _lifecycleMemo[postId] = lifecycle;
      setState(() => _lifecycle = lifecycle);
      _persistJobSnapshot(lifecycleJson: json);
    } catch (e) {
      debugPrint('[CHAT][JOB] refresh failed: $e');
    } finally {
      _jobRefreshing = false;
    }
  }

  /// When the provider arrived, from the thread: the newest arrival notice or
  /// journey that ended "Arrived", sent by the selected provider after the
  /// payment was secured (an arrival for a site visit before the price was
  /// agreed is not this stage).
  DateTime? _arrivedAt() {
    final provider = (_chatPost?.selectedProviderUserId ?? '').trim();
    if (provider.isEmpty) return null;
    DateTime? paidAt;
    for (final t in _lifecycle?.timeline ?? const <TimelineEvent>[]) {
      if (t.type == 'payment_secured') paidAt = parseServerTimeOrNull(t.at);
    }
    DateTime? latest;
    for (final m in [..._messages, ..._pendingMessages]) {
      if (m.senderId != provider) continue;
      final event = chatEventFromMessage(m, partnerName: '');
      if (event == null || event.kind != ChatEventKind.arrived) continue;
      if (paidAt != null && event.at.isBefore(paidAt)) continue;
      if (latest == null || event.at.isAfter(latest)) latest = event.at;
    }
    return latest;
  }

  ChatJobBarState? _jobBarState() {
    final postId = _postId;
    if (postId == null || postId.isEmpty) return null;
    final post = _chatPost;
    // The bar names a real post or does not render: never a pin with nothing
    // next to it, never a name invented for a general chat. The fresh post's
    // title wins over the one the chat row carried.
    final hasTitle = _postTitle != null && _postTitle!.isNotEmpty;
    final fresh = post?.title.trim() ?? '';
    final title = fresh.isNotEmpty ? fresh : (hasTitle ? _postTitle!.trim() : '');
    if (title.isEmpty) return null;
    final arrived = _arrivedAt();
    return deriveChatJobBar(ChatJobInputs(
      viewerId: widget.currentUserId,
      partnerId: widget.conversation.participantId,
      partnerName: _partnerName,
      title: title,
      price: post?.price ?? 0,
      authorId: post?.authorUserId ?? '',
      selectedProviderId: post?.selectedProviderUserId,
      offers: [
        for (final a in post?.applications ?? const <Application>[])
          ChatJobOffer(
            applicantId: a.applicantUserId,
            price: a.proposedPrice,
            at: a.timestamp,
            message: a.message,
          ),
      ],
      lifecycle: _chatIsTheJob ? _lifecycle : null,
      arrivedAt: arrived,
      arrivalClock: arrived == null ? null : formatClockTime(context, arrived),
    ));
  }

  /// The bar's button. Every route refreshes the bar on return.
  Future<void> _onJobAction(ChatJobBarState state) async {
    final postId = _postId;
    if (postId == null || postId.isEmpty) return;
    final title = state.title;
    final me = widget.currentUserId;
    switch (state.action) {
      case ChatJobAction.review:
        await _openPostFromChat(postId);
      case ChatJobAction.view:
      case ChatJobAction.details:
        if (_chatIsTheJob) {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => JobLifecycleScreen(postId: postId, postTitle: title),
          ));
        } else {
          await _openPostFromChat(postId);
        }
      case ChatJobAction.pay:
        await _payForJob(title);
      case ChatJobAction.imArrived:
        await _announceArrival();
      case ChatJobAction.markComplete:
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => MarkCompleteScreen(postId: postId, postTitle: title, providerUserId: me),
        ));
      case ChatJobAction.approve:
        final paid = _lifecycle?.payment?.amount;
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ApproveOrDisputeScreen(
            postId: postId,
            postTitle: title,
            clientUserId: me,
            providerNote: _lifecycle?.completion?.providerNote,
            amount: paid != null && paid > 0 ? paid : (_chatPost?.price ?? 0),
          ),
        ));
      case ChatJobAction.rate:
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ReviewSubmissionScreen(postId: postId, clientUserId: me, postTitle: title),
        ));
    }
    if (mounted) unawaited(_refreshJob());
  }

  /// Pay into Help24's hold — the same path as the Job status sheet: the
  /// saved M-Pesa number (or the sign-in phone), the platform fee, then the
  /// payment screen.
  Future<void> _payForJob(String title) async {
    final post = _chatPost;
    final postId = _postId;
    if (post == null || postId == null) return;
    String? raw = await UserProfileService.getMpesaPhone(widget.currentUserId);
    if (!mounted) return;
    if (raw == null || raw.isEmpty) {
      final signIn = context.read<AuthProvider>().currentUser?.phoneNumber;
      if (signIn != null && signIn.isNotEmpty) raw = signIn;
    }
    final phone = raw == null ? null : normalizeKenyanNumber(raw);
    if (phone == null) {
      _showInfo('Add a valid M-Pesa number in Profile → Payment Number.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PaymentScreen(
        postId: postId,
        postTitle: title,
        amount: post.price,
        platformFee: calculatePlatformFee(post.price),
        buyerUserId: widget.currentUserId,
        buyerPhone: phone,
      ),
    ));
  }

  /// "I've arrived" from the bar: ends a live journey as arrived when there is
  /// one (which offers the heads-up), otherwise sends the heads-up itself.
  Future<void> _announceArrival() async {
    if (_journey.isLive && (_journey.chatId == _chatId || _journey.chatId == null)) {
      await _markArrived();
      return;
    }
    HapticFeedback.mediumImpact();
    await _sendText(kArrivalNoticeText);
  }

  // ── Job events and offers in the thread ────────────────────────────────────

  /// The stages the server recorded for this job (`lifecycle.timeline`), as
  /// pills where they happened. Only real timeline entries; nothing inferred.
  List<ChatEvent> _jobEvents() {
    final lc = _lifecycle;
    final post = _chatPost;
    if (lc == null || post == null || !_chatIsTheJob) return const [];
    final isClient = lc.isClient;
    final name = _partnerName.trim();
    final partner = name.isEmpty ? 'They' : name;
    final paid = lc.payment?.amount;
    final money = formatPriceDisplay(paid != null && paid > 0 ? paid : post.price);
    final events = <ChatEvent>[];
    for (final t in lc.timeline) {
      final at = parseServerTimeOrNull(t.at);
      if (at == null) continue;
      final (ChatEventKind, String)? e = switch (t.type) {
        'payment_secured' => (
            ChatEventKind.paidHeld,
            isClient ? 'You paid. $money is held by Help24' : '$partner paid. $money is held by Help24',
          ),
        'completion_requested' => (
            ChatEventKind.completionRequested,
            isClient ? '$partner marked the job complete' : 'You marked the job complete',
          ),
        'completion_approved' => (
            ChatEventKind.completed,
            isClient ? 'You approved the work' : '$partner approved the work',
          ),
        'dispute_opened' => (ChatEventKind.disputeOpened, 'Dispute opened. Payment on hold'),
        'payout_released' => (
            ChatEventKind.released,
            isClient ? '$money released to $partner' : '$money released to you',
          ),
        _ => null,
      };
      if (e == null) continue;
      events.add(ChatEvent(
        kind: e.$1,
        at: at,
        label: e.$2,
        sourceKey: 'lc_${t.type}_${at.millisecondsSinceEpoch}',
      ));
    }
    return events;
  }

  /// This pair's own application on the chat's post, shown as an offer card
  /// where it was made.
  List<ChatThreadOffer> _threadOffers() {
    final post = _chatPost;
    if (post == null) return const [];
    final me = widget.currentUserId;
    final partner = widget.conversation.participantId;
    final viewerIsAuthor = post.authorUserId == me;
    if (!viewerIsAuthor && post.authorUserId != partner) return const [];
    final applicant = viewerIsAuthor ? partner : me;
    final selected = (post.selectedProviderUserId ?? '').trim();
    final name = _partnerName.trim();
    return [
      for (final a in post.applications)
        if (a.applicantUserId == applicant && a.proposedPrice > 0)
          ChatThreadOffer(
            id: a.id,
            mine: applicant == me,
            price: a.proposedPrice,
            at: a.timestamp,
            message: a.message,
            status: selected.isEmpty
                ? ChatOfferStatus.pending
                : (selected == applicant ? ChatOfferStatus.accepted : ChatOfferStatus.notSelected),
            acceptedBy: applicant == me ? (name.isEmpty ? 'them' : name) : 'you',
          ),
    ];
  }

  // ── Documents ──────────────────────────────────────────────────────────────

  /// Open a delivered document in the phone's own viewer.
  ///
  /// Like a photo: the first open downloads it once through the files
  /// endpoint with the user's own token (participant and deletion checked
  /// there), every later open is the copy already on the phone — no network.
  /// The bubble shows the download's progress from the moment it starts.
  Future<void> _openDocument(String messageId) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ChatDocuments.open(messageId);
    final String? problem = switch (result) {
      DocumentOpenResult.opened => null,
      DocumentOpenResult.offline => "You're offline. Connect to download this file.",
      DocumentOpenResult.gone => 'This file was deleted.',
      DocumentOpenResult.unavailable => "This file isn't available any more.",
      DocumentOpenResult.failed => "Couldn't open this file. Please try again.",
      DocumentOpenResult.noViewer => null,
    };
    if (result == DocumentOpenResult.noViewer) {
      // No installed app opens this type: fall back to the browser.
      if (!mounted) return;
      await _openInBrowser(messageId);
      return;
    }
    if (problem != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(problem), behavior: SnackBarBehavior.floating),
      );
    }
    // The size is known now that the copy is on the phone.
    if (mounted) setState(() {});
  }

  /// The fallback when no viewer app is installed: a one-time link on
  /// files.help24.co.ke (two minutes, single use) opened in the browser,
  /// which trades it for access to this one file and nothing else.
  Future<void> _openInBrowser(String messageId) async {
    final messenger = ScaffoldMessenger.of(context);
    String? problem;
    try {
      final link = await ChatAttachmentApi.browserLink(messageId);
      if (!await launchUrl(link, mode: LaunchMode.externalApplication)) {
        problem = "Couldn't open this file.";
      }
    } on ChatAttachmentException catch (e) {
      debugPrint('ChatScreen open document: $e');
      problem = e.isGone
          ? 'This file was deleted.'
          : e.statusCode == 404
              ? "This file isn't available any more."
              : "Couldn't open this file. Please try again.";
    } catch (e) {
      debugPrint('ChatScreen open document: $e');
      problem = ErrorMapper.isConnectivityError(e)
          ? "You're offline. Connect to open this file."
          : "Couldn't open this file. Please try again.";
    }
    if (problem != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(problem), behavior: SnackBarBehavior.floating),
      );
    }
  }

  // ── The thread ─────────────────────────────────────────────────────────────

  Widget _buildEntry(ChatThreadEntry entry) {
    switch (entry) {
      case ChatDayEntry(:final day):
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Center(child: ChatDayPill(label: chatDayLabel(day))),
        );
      case ChatEventEntry(:final event):
        final m = event.message;
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Center(
            child: Builder(
              builder: (pillContext) => GestureDetector(
                onTap: m != null && m.hasValidCoordinates ? () => _openFullScreenMap(m) : null,
                onLongPress: m == null || OutboxIds.isPending(m.id)
                    ? null
                    : () => _showMessageActions(m, _rectOf(pillContext)),
                child: ChatEventPill(event: event, time: chatBubbleTime(context, event.at)),
              ),
            ),
          ),
        );
      case ChatOfferEntry(:final offer):
        return Padding(
          padding: const EdgeInsets.only(top: ChatGeometry.betweenGroupsGap),
          child: Align(
            alignment: offer.mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            child: ChatOfferCard(
              offer: offer,
              time: chatBubbleTime(context, offer.at),
              onTap: _postId == null ? null : () => _openPostFromChat(_postId!),
            ),
          ),
        );
      case ChatMessageEntry(:final message, :final position):
        return _buildMessageRow(message, position);
    }
  }

  static Rect _rectOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;
  }

  Widget _buildMessageRow(Message m, RunPosition position) {
    final mine = m.isMe;
    final pending = OutboxIds.isPending(m.id);
    final state = mine ? chatSendStateOf(m) : null;
    final time = chatBubbleTime(context, m.timestamp);
    final hasUrl = m.attachmentUrl != null && m.attachmentUrl!.isNotEmpty;
    // A queued attachment has no URL yet — only the copy on this phone. It is
    // drawn from that copy, never from a server address it does not have.
    final localFile = pending && m.localPath != null ? m.localPath : null;
    final stoppable = pending && state != ChatSendState.failed;

    Widget bubble;
    if (m.deletedForEveryone) {
      bubble = ChatTombstoneBubble(message: m, position: position, time: time);
    } else if (m.isImage && (hasUrl || localFile != null)) {
      bubble = ChatPhotoBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        localPath: localFile,
        onOpen: pending ? null : () => _openImageViewer(m),
        onCancel: stoppable ? () => _cancelPending(m) : null,
      );
    } else if (m.isFile && (hasUrl || localFile != null)) {
      bubble = ChatFileBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        localPath: localFile,
        onOpen: !pending && hasUrl ? () => _openDocument(m.id) : null,
        onCancel: stoppable ? () => _cancelPending(m) : null,
      );
    } else if (m.isLocationRequest) {
      bubble = ChatCardBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        child: RequestCard(
          message: m,
          partnerName: _partnerName,
          onShareNow: mine ? null : _respondToLocationRequest,
        ),
      );
    } else if (m.isLiveLocation && m.hasValidCoordinates) {
      final owns = _journey.owns(m.id);
      bubble = ChatCardBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        child: JourneyCard(
          message: m,
          width: ChatCardBubble.innerWidth(context),
          viewerLat: _myLat,
          viewerLng: _myLng,
          isSharing: owns,
          phase: _phaseFor(m),
          lastEventAt: _journeyEventAt[m.id],
          etaSeconds: owns ? _journey.etaSeconds : null,
          remainingMeters: owns ? _journey.remainingMeters : null,
          onStop: owns ? _stopLiveSharing : null,
          onArrived: owns ? _markArrived : null,
          onTap: () => _openFullScreenMap(m),
        ),
      );
    } else if (m.isLocation && m.hasValidCoordinates) {
      bubble = ChatLocationBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        viewerLat: _myLat,
        viewerLng: _myLng,
        onOpen: () => _openFullScreenMap(m),
      );
    } else {
      bubble = ChatTextBubble(
        message: m,
        position: position,
        time: time,
        state: state,
        onTapQuote: m.replyToId == null ? null : () => _scrollToMessage(m.replyToId!),
      );
    }

    final canLongPress = !pending && !m.deletedForEveryone;
    return ChatMessageRow(
      mine: mine,
      position: position,
      state: state,
      onLongPress: canLongPress ? (rect) => _showMessageActions(m, rect) : null,
      onRetry: state == ChatSendState.failed ? () => _retryPending(m) : null,
      bubble: bubble,
    );
  }

  /// One empty or failed state of the thread: an icon, what is true, and the
  /// way forward when there is one.
  Widget _threadNotice({
    required IconData icon,
    required String title,
    String? body,
    VoidCallback? onRetry,
  }) {
    final c = ChatColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: c.iconSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: c.text),
            ),
            if (body != null) ...[
              const SizedBox(height: 4),
              Text(
                body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(AppIcons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Offline, with nothing of this thread on the phone. Not an error, and not
  /// "No messages yet" — which would be a claim about a conversation this
  /// phone simply has not seen. It says what will happen instead.
  Widget _offlineThreadNotice() {
    _lastMessageCount = 0;
    return _threadNotice(
      icon: AppIcons.noConnection,
      title: 'Waiting for network',
      body: "This chat's messages will appear here when you're back online.",
    );
  }

  Widget _buildThread({required bool offline}) {
    final combined = mergeOutboxIntoThread(
      _messages.where(_isLocallyVisible).toList(),
      _pendingMessages,
    );

    // Nothing stored and no network: no spinner can end, so none is shown.
    if (offline && combined.isEmpty && _resolution != ChatResolution.absent) {
      return _offlineThreadNotice();
    }

    // Still asking whether a conversation exists. Progress, never an empty
    // state — "Start the conversation" here was §D1.
    if (showsResolvingProgress(_resolution) && combined.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadingMessages && combined.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (combined.isEmpty && _loadFailed) {
      _lastMessageCount = 0;
      return _threadNotice(
        icon: AppIcons.unreachable,
        title: "Couldn't load messages",
        body: 'Check your connection and try again.',
        onRetry: () {
          setState(() {
            _loadFailed = false;
            _loadingMessages = true;
          });
          _startRealtimeMessages();
        },
      );
    }
    // We could not find out whether a conversation exists (offline / error).
    // Say exactly that. Offering to start one here is how a user ends up with
    // two parallel threads.
    if (combined.isEmpty && _resolution == ChatResolution.unresolved) {
      _lastMessageCount = 0;
      return _threadNotice(
        icon: AppIcons.unreachable,
        title: "Couldn't open this conversation",
        body: 'Check your connection and try again.',
        onRetry: () {
          setState(() {
            _resolution = ChatResolution.resolving;
            _loadingMessages = true;
          });
          unawaited(_resolveExistingChat());
        },
      );
    }
    // Only a COMPLETED lookup that found nothing may say this.
    if (combined.isEmpty && showsStartConversation(_resolution)) {
      _lastMessageCount = 0;
      return _threadNotice(icon: AppIcons.chat, title: 'Start the conversation', body: 'Say hello 👋');
    }
    if (combined.isEmpty) {
      // Existing conversation with genuinely no messages yet.
      _lastMessageCount = 0;
      return _threadNotice(icon: AppIcons.chat, title: 'No messages yet');
    }

    final showLoadMore = _hasMoreOlder || _loadingOlder;
    final entries = buildChatThread(
      combined,
      extraEvents: _jobEvents(),
      offers: _threadOffers(),
      partnerName: _partnerName,
    );
    _entries = entries;
    // Reversed presentation: ListView index 0 == the NEWEST row. The list is
    // anchored at offset 0 (the visual bottom), which makes "open exactly on
    // the latest message" a structural property — layout timing, image sizes,
    // keyboard insets and pagination cannot affect it. The "load older" row
    // lives past the oldest row (the visual top).
    _itemIndexByKey.clear();
    for (int i = 0; i < entries.length; i++) {
      _itemIndexByKey[entries[entries.length - 1 - i].key] = i;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateStickyDay();
    });
    return ListView.builder(
      key: _listKey,
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(
        ChatGeometry.sidePadding, 8, ChatGeometry.sidePadding, _kListPaddingBottom,
      ),
      itemCount: entries.length + (showLoadMore ? 1 : 0),
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        return _itemIndexByKey[key.value];
      },
      itemBuilder: (context, index) {
        if (showLoadMore && index == entries.length) {
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
                      icon: const Icon(AppIcons.refresh, size: 18),
                      label: const Text('Load older messages'),
                    ),
            ),
          );
        }
        final entry = entries[entries.length - 1 - index];
        return KeyedSubtree(key: ValueKey<String>(entry.key), child: _buildEntry(entry));
      },
    );
  }

  /// Quick replies, for the provider whose journey to this job is live.
  bool get _showQuickReplies =>
      _journey.isLive && (_journey.chatId == _chatId) && _chatId.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final offline = context.select<ConnectivityProvider, bool>((p) => p.isOffline);
    final jobBar = _jobBarState();
    final rep = _headerRep;

    return Scaffold(
      backgroundColor: c.bg,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            // The second line yields to "Waiting for network" / "Connecting…"
            // while chat is not in touch with the server — the same small
            // status the Messages tab shows under its title.
            child: ChatSyncPhaseBuilder(
              builder: (context, syncLabel) => ChatHeader(
                name: _partnerName,
                userId: widget.conversation.participantId,
                avatarUrl: _partner?.avatarUrl ?? widget.conversation.userAvatar,
                avatarPath: _partner?.avatarPath ?? widget.conversation.userAvatarPath,
                subtitle: syncLabel ?? _headerSubtitle(),
                typing: _otherIsTyping && syncLabel == null,
                online: _onlineStatus == 'online' && syncLabel == null,
                onBack: () => Navigator.of(context).pop(),
                // Earned verification: only for backend-trusted tiers.
                badge: rep != null && _trustedTiers.contains(rep.tier)
                    ? Icon(AppIcons.verifiedProvider, size: 15, color: tierColor(context, rep.tier))
                    : null,
                menu: ChatMenuButton<ChatMenuAction>(
                  onSelected: _onMenuAction,
                  itemBuilder: (menuContext) => buildChatMenuItems(
                    menuContext,
                    hasPost: _postId != null && _postId!.isNotEmpty,
                    isMuted: _isMuted,
                  ),
                ),
              ),
            ),
          ),
          if (offline) const ChatOfflineBanner(),
          if (jobBar != null)
            ChatJobBar(
              state: jobBar,
              busy: _openingPost,
              onOpen: _postId != null && _postId!.isNotEmpty ? () => _openPostFromChat(_postId!) : null,
              onAction: () => _onJobAction(jobBar),
            ),
          // Journey strip — narrates the journey as it evolves: on the way →
          // nearby → reconnecting → arrived (brief), then leaves. One strip,
          // phase-driven; tap opens the live map.
          if (_stripJourney != null)
            Builder(builder: (context) {
              final journey = _stripJourney!;
              final mine = journey.isMe;
              final phase = _phaseFor(journey);
              final name = _partnerName;
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
              // ETA line: only the traveller's device computes a route, so
              // only it can narrate one. Watchers keep the Phase 2 line.
              final owns = _journey.owns(journey.id);
              final subtitle = (owns && phase != JourneyPhase.arrived)
                  ? [
                      etaText(_journey.etaSeconds),
                      remainingText(_journey.remainingMeters),
                    ].whereType<String>().join(' · ')
                  : null;
              return JourneyStatusStrip(
                title: title,
                phase: phase,
                subtitle: (subtitle == null || subtitle.isEmpty) ? null : subtitle,
                onTap: journey.hasValidCoordinates ? () => _openFullScreenMap(journey) : null,
                onStop: mine && owns && _journey.isLive ? _stopLiveSharing : null,
              );
            }),
          // Messages: cache-hydrated instantly, then Supabase Realtime.
          Expanded(
            child: Stack(
              children: [
                _buildThread(offline: offline),
                // The current day, pinned while the thread scrolls.
                if (_stickyDay != null)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(child: ChatDayPill(label: chatDayLabel(_stickyDay!))),
                    ),
                  ),
                // Back to the latest: 12 above the composer, centred over Send
                // and never on top of it.
                if (!_isNearBottom)
                  PositionedDirectional(
                    end: ChatGeometry.sidePadding +
                        (ChatGeometry.sendDiameter - ChatGeometry.minTouch) / 2,
                    bottom: 12 - (ChatGeometry.minTouch - ChatGeometry.scrollButtonDiameter) / 2,
                    child: ChatScrollToLatest(
                      unread: _unseenBelow,
                      onTap: () {
                        _scrollToBottom();
                        setState(() => _unseenBelow = 0);
                      },
                    ),
                  ),
              ],
            ),
          ),
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
          if (_showQuickReplies)
            ChatQuickReplies(
              replies: ChatQuickReplies.onTheWay,
              onTap: (text) => _sendText(text),
            ),
          // Reply preview bar — visible when user long-pressed a message to reply.
          if (_replyToMessage != null)
            _ReplyPreviewBar(
              replyTo: _replyToMessage!,
              partnerName: _partnerName,
              onCancel: () => setState(() => _replyToMessage = null),
            ),
          // Messaging denied → the composer is replaced, so nobody writes a
          // message the server will refuse. The status is explanation only;
          // the database and backend still enforce.
          ListenableBuilder(
            listenable: AccountStatusStore.instance,
            builder: (context, composer) => AccountStatusStore.instance.denies(Capability.message)
                ? const SafeArea(top: false, child: RestrictedComposerNotice())
                : composer!,
            child: SafeArea(
              top: false,
              child: ChatComposer(
                controller: _messageController,
                busy: _isSending,
                onAttach: _showAttachmentOptions,
                onCamera: _takePhoto,
                onSend: _sendMessage,
              ),
            ),
          ),
        ],
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
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            IconBadge(icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: c.contentPrimary),
                  ),
                  const SizedBox(height: 1),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: c.contentTertiary)),
                ],
              ),
            ),
            Icon(AppIcons.disclosure, size: 20, color: c.contentTertiary),
          ],
        ),
      ),
    );
  }
}

// ── Full-screen map ────────────────────────────────────────────────────────

/// A shared place or a journey, full screen, in the theme's map style — with
/// Directions and Copy address for either side of the conversation.
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
  String? _area;

  @override
  void initState() {
    super.initState();
    _message = widget.message;
    _loadMyPosition();
    _area = PlaceNameCache.peek(_message.latitude!, _message.longitude!);
    if (_area == null) {
      PlaceNameCache.resolve(_message.latitude!, _message.longitude!).then((name) {
        if (mounted && name != null) setState(() => _area = name);
      });
    }
    // Redraw when the engine publishes a new route/position for this journey.
    JourneyEngine.instance.listenable.addListener(_onEngine);
  }

  void _onEngine() {
    if (!mounted) return;
    final journey = JourneyEngine.instance.snapshot;
    if (!journey.owns(_message.id)) return;
    // Only the route object identity matters for the drawn path; the marker
    // follows the message row via realtime. Cheap setState, no camera fight.
    if (!identical(journey.route, _lastDrawnRoute)) {
      _lastDrawnRoute = journey.route;
      setState(() {});
    }
  }

  JourneyRoute? _lastDrawnRoute;

  @override
  void dispose() {
    JourneyEngine.instance.listenable.removeListener(_onEngine);
    super.dispose();
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

  String get _label {
    final t = _message.text.trim();
    if (_message.isLiveLocation || t.isEmpty || t == 'Location') return '';
    return t;
  }

  /// What "Copy address" puts on the clipboard: the sender's name for the
  /// place, the area, and the coordinates — which every maps app can find.
  String get _addressText {
    final lat = _message.latitude!.toStringAsFixed(5);
    final lng = _message.longitude!.toStringAsFixed(5);
    return [
      if (_label.isNotEmpty) _label,
      if (_area != null && _area != _label) _area!,
      '$lat, $lng',
    ].join(', ');
  }

  /// Route path for this journey, if the engine has one for THIS message.
  ///
  /// Identity-keyed on the route object: the polyline is only rebuilt when a
  /// genuinely new route arrives (every ~90 s), not on every position fix, so
  /// the line does not flicker as the marker moves.
  Set<Polyline> _routePolylines(Color color) {
    final journey = JourneyEngine.instance.snapshot;
    if (!journey.owns(_message.id)) return const {};
    final route = journey.route;
    if (route == null || route.isStale || route.path.length < 2) return const {};
    return {
      Polyline(
        polylineId: PolylineId('route_${route.computedAt.millisecondsSinceEpoch}'),
        points: [
          for (final p in _simplify(route.path)) LatLng(p.lat, p.lng),
        ],
        width: 5,
        color: color,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        geodesic: true,
      ),
    };
  }

  /// Caps the drawn vertex count. An overview polyline for a long trip can
  /// carry thousands of points; past a few hundred they are sub-pixel and cost
  /// only render time. Uniform sampling keeps the shape and always keeps the
  /// endpoints.
  List<({double lat, double lng})> _simplify(List<({double lat, double lng})> path) {
    const maxPoints = 300;
    if (path.length <= maxPoints) return path;
    final step = (path.length / maxPoints).ceil();
    final out = <({double lat, double lng})>[];
    for (var i = 0; i < path.length; i += step) {
      out.add(path[i]);
    }
    if (out.last != path.last) out.add(path.last);
    return out;
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
    final chat = ChatColors.of(context);
    final app = AppColors.of(context);
    final lat = _message.latitude!;
    final lng = _message.longitude!;
    final live = _message.isLiveLocation &&
        _message.liveUntil != null &&
        _message.liveUntil!.isAfter(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _message.isJourneyArrived
              ? 'Journey'
              : _message.isLiveLocation
                  ? (_message.text == 'Live location' ? 'Live location' : 'Journey')
                  : (_label.isNotEmpty ? _label : 'Location'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(target: LatLng(lat, lng), zoom: 15),
                  style: chat.mapStyle,
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
                  // Actual driven route, not a straight line. Drawn only when
                  // this device owns the journey (only it computes routes).
                  polylines: _routePolylines(chat.accent),
                  onMapCreated: (controller) {
                    _mapController = controller;
                    if (_myLat != null && _myLng != null) _fitBounds();
                  },
                  myLocationButtonEnabled: true,
                  myLocationEnabled: !_loadingMyPosition,
                ),
                if (live)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Material(
                      elevation: 4,
                      borderRadius: AppRadius.mdAll,
                      color: app.surface,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            const LiveDot(size: 7),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Builder(builder: (context) {
                                final journey = JourneyEngine.instance.snapshot;
                                final owns = journey.owns(_message.id);
                                final eta = owns ? etaText(journey.etaSeconds) : null;
                                final remaining = owns ? remainingText(journey.remainingMeters) : null;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(eta ?? 'Sharing live', style: Theme.of(context).textTheme.titleSmall),
                                    if (remaining != null)
                                      Text(remaining, style: Theme.of(context).textTheme.bodySmall),
                                  ],
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ColoredBox(
            color: app.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_label.isNotEmpty || _area != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          [if (_label.isNotEmpty) _label, if (_area != null && _area != _label) _area!].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: app.contentPrimary),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              launchDirections(lat, lng, label: _label);
                            },
                            // The theme's 24 px button padding wrapped "Copy address"
                            // onto two lines at half the screen width (seen on device).
                            style: FilledButton.styleFrom(
                              backgroundColor: chat.accent,
                              foregroundColor: chat.onAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            icon: const Icon(AppIcons.directions, size: 18),
                            label: const Text('Directions', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _addressText));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Address copied'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            icon: const Icon(AppIcons.copy, size: 18),
                            label: const Text('Copy address', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ],
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

// ── Reply preview bar (shown above the composer when replying) ──────────────

class _ReplyPreviewBar extends StatelessWidget {
  final Message replyTo;
  final String partnerName;
  final VoidCallback onCancel;

  const _ReplyPreviewBar({
    required this.replyTo,
    required this.partnerName,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final preview = replyTo.text.isNotEmpty
        ? replyTo.text.substring(0, replyTo.text.length.clamp(0, 120))
        : replyTo.isImage
            ? 'Photo'
            : replyTo.isFile
                ? 'File'
                : 'Location';

    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 2, 6),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(color: c.accent, borderRadius: AppRadius.pillAll),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyTo.isMe ? 'You' : partnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: c.accentText),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: 'Cancel reply',
            icon: Icon(AppIcons.close, size: 18, color: c.iconSecondary),
            constraints: const BoxConstraints.tightFor(
              width: ChatGeometry.minTouch,
              height: ChatGeometry.minTouch,
            ),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}

