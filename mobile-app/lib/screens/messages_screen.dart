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
import '../services/location_service.dart';
import '../services/chat_service_supabase.dart';
import '../services/post_service.dart';
import '../services/cache_service.dart';
import '../services/supabase_auth_bridge.dart';
import '../services/storage_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/job_status_card.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  String get _currentUserId =>
      context.read<AuthProvider>().currentUserId ?? '';

  @override
  void initState() {
    super.initState();
    _loadConversationsWhenReady();
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
                      return _ConversationTile(
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
                      ).animate().fadeIn(
                        duration: 300.ms,
                        delay: Duration(milliseconds: index * 50),
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
    required this.conversation,
    required this.onTap,
  });

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
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

  Widget _avatarLoadingPlaceholder() {
    return CircleAvatar(
      radius: 26,
      backgroundColor: AppTheme.darkCard,
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryAccent),
      ),
    );
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
                              child: CachedNetworkImage(
                                imageUrl: avatarUrl,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => _avatarLoadingPlaceholder(),
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
                            Text(
                              _formatTime(conversation.lastMessageTime),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                color: conversation.unreadCount > 0
                                    ? AppTheme.primaryAccent
                                    : null,
                                fontWeight: conversation.unreadCount > 0
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                conversation.lastMessage.isNotEmpty
                                    ? conversation.lastMessage
                                    : 'No messages yet',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: conversation.unreadCount > 0
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: conversation.unreadCount > 0
                                      ? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary)
                                      : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (conversation.unreadCount > 0) ...[
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
const double _kChatInputMaxHeight = 130.0;

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
  DateTime? _oldestInCurrentPage;
  // Realtime subscription for instant message delivery.
  StreamSubscription<List<Message>>? _realtimeSubscription;
  // Fallback poll for typing indicator + reliability (30s, not 4s).
  Timer? _typingPollTimer;
  bool _isSending = false;
  StreamSubscription? _liveLocationSubscription;
  Timer? _liveEndTimer;
  String? _liveMessageId;
  int _lastMessageCount = 0;

  // Typing indicator state
  bool _otherIsTyping = false;
  Timer? _typingDebounce;
  Timer? _typingClearTimer;

  // Online status (shown in AppBar subtitle)
  String _onlineStatus = '';
  Timer? _onlineStatusTimer;

  // Scroll-to-bottom FAB
  bool _isNearBottom = true;
  // Set to true after the first successful jump to bottom on load.
  // Used to distinguish initial instant-jump from subsequent smooth-scrolls.
  bool _initialScrollDone = false;

  // Non-null while user has selected a message to reply to.
  Message? _replyToMessage;

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
      // Existing chat: start realtime immediately.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppProvider>().setActiveChatId(_chatId);
      });
      _startRealtimeMessages();
      _typingPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _checkTyping();
      });
      _markSeenNow();
    } else {
      // Pending chat: show empty state, no realtime until first send.
      setState(() => _loadingMessages = false);
    }
    // Load online/last-seen status for the other participant.
    _loadOnlineStatus();
    _onlineStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadOnlineStatus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear active chat so notifications resume for other chats.
    context.read<AppProvider>().setActiveChatId(null);
    _realtimeSubscription?.cancel();
    _typingPollTimer?.cancel();
    _typingDebounce?.cancel();
    _typingClearTimer?.cancel();
    _onlineStatusTimer?.cancel();
    _liveLocationSubscription?.cancel();
    _liveEndTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _messageController.removeListener(_onTypingChanged);
    ChatServiceSupabase.clearTyping(_chatId, widget.currentUserId);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Called by WidgetsBinding whenever the window metrics change — most
  /// importantly when the soft keyboard slides in or out.  If the user is
  /// already at the bottom we keep them pinned to the latest message.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || !_isNearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[CHAT_SCROLL][KEYBOARD_ADJUST]');
      _doScroll(instant: false);
    });
  }

  /// Subscribe to Supabase Realtime for this chat. Messages arrive instantly.
  void _startRealtimeMessages() {
    _realtimeSubscription = ChatServiceSupabase.watchMessages(
      _chatId,
      widget.currentUserId,
    ).listen((messages) {
      if (!mounted) return;
      // Merge with any older messages already loaded (pagination).
      final List<Message> merged;
      if (_oldestInCurrentPage != null) {
        final older = _messages.where((m) => m.timestamp.isBefore(_oldestInCurrentPage!)).toList();
        final seen = messages.map((m) => m.id).toSet();
        merged = older.where((m) => !seen.contains(m.id)).toList() + messages;
      } else {
        merged = messages;
      }
      final hadNew = messages.length > _lastMessageCount;
      setState(() {
        _messages = merged;
        _oldestInCurrentPage = messages.isEmpty ? null : messages.first.timestamp;
        _loadingMessages = false;
        _hasMoreOlder = messages.length >= 30;
      });
      if (messages.isNotEmpty) {
        CacheService.saveMessages(_chatId, merged);
      }
      if (_lastMessageCount == 0) {
        // Initial load: instant jump so the user lands on the latest message,
        // not the top of the history.
        _lastMessageCount = messages.length;
        _scrollToBottom(instant: true);
        _markSeenNow();
      } else if (hadNew) {
        _lastMessageCount = messages.length;
        // Only auto-scroll if user is already near the bottom — don't hijack
        // their scroll position when they're reading older messages.
        if (_isNearBottom) _scrollToBottom();
        _markSeenNow();
      }
    }, onError: (e) {
      debugPrint('ChatScreen Realtime error: $e');
      if (mounted) setState(() => _loadingMessages = false);
    });
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
      final isOnline = row['is_online'] as bool? ?? false;
      if (isOnline) {
        setState(() => _onlineStatus = 'online');
        return;
      }
      final lastSeenStr = row['last_seen'] as String?;
      if (lastSeenStr == null) {
        setState(() => _onlineStatus = '');
        return;
      }
      final lastSeen = DateTime.tryParse(lastSeenStr)?.toLocal();
      if (lastSeen == null) {
        setState(() => _onlineStatus = '');
        return;
      }
      final diff = DateTime.now().difference(lastSeen);
      String label;
      if (diff.inMinutes < 2) {
        label = 'last seen just now';
      } else if (diff.inMinutes < 60) {
        label = 'last seen ${diff.inMinutes} min ago';
      } else if (diff.inHours < 24) {
        label = 'last seen ${diff.inHours}h ago';
      } else {
        label = 'last seen ${diff.inDays}d ago';
      }
      setState(() => _onlineStatus = label);
    } catch (_) {}
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

  /// Loads cached messages for offline mode. Realtime handles online loading.
  Future<void> _loadCachedMessagesIfOffline() async {
    if (_chatId.isEmpty) return;
    final results = await Connectivity().checkConnectivity();
    final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (!offline) return;
    final cached = await CacheService.loadMessages(_chatId, widget.currentUserId);
    if (!mounted) return;
    setState(() {
      _messages = cached;
      _loadingMessages = false;
      _hasMoreOlder = false;
    });
    if (cached.isNotEmpty) _scrollToBottom();
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
    if (_scrollController.position.pixels < 120 && _hasMoreOlder && !_loadingOlder) {
      _loadOlderMessages();
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent > 0) {
      final nearBottom = _scrollController.position.pixels >= maxExtent - 200;
      if (nearBottom != _isNearBottom) {
        setState(() => _isNearBottom = nearBottom);
      }
    }
  }

  /// Inner scroll executor with capped retry.
  ///
  /// If `maxScrollExtent == 0` and messages are present, the ListView layout
  /// may not have settled yet — retry up to [_kScrollRetryLimit] frames.
  /// After that, if extent is still 0, the content genuinely fits the viewport
  /// (no scroll needed) and we mark initialScroll done to unblock future calls.
  ///
  /// First-ever scroll uses `jumpTo` (instant) to avoid the "flash-from-top"
  /// artifact; subsequent calls use `animateTo` for smooth follow-along.
  static const int _kScrollRetryLimit = 4;

  void _doScroll({required bool instant, int retries = 0}) {
    if (!mounted || !_scrollController.hasClients) return;
    final extent = _scrollController.position.maxScrollExtent;
    debugPrint('[CHAT_SCROLL][FRAME_READY] extent=$extent retries=$retries instant=$instant');
    if (extent <= 0) {
      if (_messages.isNotEmpty && retries < _kScrollRetryLimit) {
        // Layout hasn't settled — retry next frame.
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _doScroll(instant: instant, retries: retries + 1));
        return;
      }
      // Content fits the viewport (no scrolling required) or retries exhausted.
      debugPrint('[CHAT_SCROLL][AUTO_SCROLL] extent=0 content_fits_viewport — marking done');
      _initialScrollDone = true;
      return;
    }
    debugPrint('[CHAT_SCROLL][MAX_EXTENT] extent=$extent');
    debugPrint('[CHAT_SCROLL][AUTO_SCROLL] instant=${instant || !_initialScrollDone}');
    if (instant || !_initialScrollDone) {
      _scrollController.jumpTo(extent);
      _initialScrollDone = true;
      debugPrint('[CHAT_SCROLL][MESSAGES_LOADED] jumped to bottom extent=$extent');
    } else {
      _scrollController.animateTo(
        extent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  /// Public entry point.  Schedules a post-frame callback so it is safe to
  /// call during build/setState without triggering a mid-frame layout call.
  void _scrollToBottom({bool instant = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[CHAT_SCROLL][LOAD_COMPLETE] hasClients=${_scrollController.hasClients} messages=${_messages.length}');
      _doScroll(instant: instant);
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

  void _showAttachmentOptions() {
    if (_isSending) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Attach',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.2),
                  child: const Icon(Iconsax.gallery, color: AppTheme.primaryAccent),
                ),
                title: const Text('Photo'),
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendImage();
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.secondaryAccent.withValues(alpha: 0.2),
                  child: const Icon(Iconsax.document, color: AppTheme.secondaryAccent),
                ),
                title: const Text('File (PDF, CV)'),
                onTap: () {
                  Navigator.pop(context);
                  _pickAndSendFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLocationOptions() {
    if (_isSending) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Share location',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.2),
                  child: const Icon(Iconsax.location, color: AppTheme.primaryAccent),
                ),
                title: const Text('Send current location'),
                subtitle: const Text('Share your location once'),
                onTap: () {
                  Navigator.pop(context);
                  _sendCurrentLocation();
                },
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.only(left: 16, top: 8),
                child: Text('Share live location', style: TextStyle(fontSize: 12, color: AppTheme.darkTextTertiary)),
              ),
              _LiveOption(minutes: 15, onTap: () { Navigator.pop(context); _startLiveLocation(15); }),
              _LiveOption(minutes: 30, onTap: () { Navigator.pop(context); _startLiveLocation(30); }),
              _LiveOption(minutes: 60, onTap: () { Navigator.pop(context); _startLiveLocation(60); }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendCurrentLocation() async {
    setState(() => _isSending = true);
    if (!await _ensureChatCreated()) {
      if (mounted) { setState(() => _isSending = false); _showError('Could not start chat. Please try again.'); }
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    final position = await LocationService.getCurrentPosition();
    if (!mounted) return;
    if (position == null) {
      setState(() => _isSending = false);
      _showError('Location unavailable. Enable location and try again.');
      return;
    }
    try {
      await ChatServiceSupabase.sendLocation(
        chatId: _chatId,
        senderId: widget.currentUserId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Failed to send location.');
      }
    }
  }

  Future<void> _startLiveLocation(int durationMinutes) async {
    setState(() => _isSending = true);
    if (!await _ensureChatCreated()) {
      if (mounted) { setState(() => _isSending = false); _showError('Could not start chat. Please try again.'); }
      return;
    }
    await SupabaseAuthBridge.ensureSessionAsync();
    final position = await LocationService.getCurrentPosition();
    if (!mounted) return;
    if (position == null) {
      setState(() => _isSending = false);
      _showError('Location unavailable. Enable location and try again.');
      return;
    }
    try {
      final message = await ChatServiceSupabase.sendLiveLocation(
        chatId: _chatId,
        senderId: widget.currentUserId,
        latitude: position.latitude,
        longitude: position.longitude,
        durationMinutes: durationMinutes,
      );
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _liveMessageId = message.id;
      });
      _scrollToBottom();

      _liveEndTimer = Timer(Duration(minutes: durationMinutes), () {
        if (!mounted) return;
        _stopLiveSharing();
      });

      _liveLocationSubscription = LocationService.positionUpdatesEvery(intervalSeconds: 8).listen((pos) {
        if (_liveMessageId == null) return;
        ChatServiceSupabase.updateMessageLocation(
          messageId: _liveMessageId!,
          latitude: pos.latitude,
          longitude: pos.longitude,
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isSending = false);
        _showError('Failed to start live location.');
      }
    }
  }

  Future<void> _stopLiveSharing() async {
    _liveEndTimer?.cancel();
    _liveEndTimer = null;
    await _liveLocationSubscription?.cancel();
    _liveLocationSubscription = null;
    if (_liveMessageId != null) {
      try {
        await ChatServiceSupabase.stopLiveLocation(_liveMessageId!);
      } catch (_) {}
      if (mounted) setState(() => _liveMessageId = null);
    }
  }

  Future<void> _openPostFromChat(String postId) async {
    try {
      final post = await PostService.getPostById(postId);
      if (post == null || !mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _PostDetailPage(post: post),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load post: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Scrolls the list so the message whose [id] equals [targetId] is visible.
  /// Used when user taps the quoted block in a reply bubble.
  void _scrollToMessage(String targetId) {
    final allItems = _buildItemsList(
      List<Message>.of(_messages)..sort((a, b) => a.timestamp.compareTo(b.timestamp)),
    );
    // Find position: each item in `allItems` corresponds to one ListView index
    // (plus the optional "load older" row at index 0).
    final showLoadMore = _hasMoreOlder || _loadingOlder;
    final offset = showLoadMore ? 1 : 0;
    for (int i = 0; i < allItems.length; i++) {
      final item = allItems[i];
      if (item is _ChatMessageItem && item.message.id == targetId) {
        // Estimate item height — accurate enough for scrolling to approximate position.
        const estimatedItemH = 60.0;
        final targetOffset = (i + offset) * estimatedItemH;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        );
        return;
      }
    }
  }

  // ── Message actions (Part 3 + 4) ──────────────────────────────────────────

  void _showMessageActions(Message message) {
    HapticFeedback.mediumImpact();
    final canDeleteForEveryone = message.isMe &&
        DateTime.now().difference(message.timestamp).inMinutes <= 15;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _MessageActionsSheet(
        message: message,
        canDeleteForEveryone: canDeleteForEveryone,
        onCopy: message.text.isNotEmpty
            ? () {
                Navigator.pop(context);
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
        onReply: () {
          Navigator.pop(context);
          setState(() => _replyToMessage = message);
        },
        onDeleteForMe: () {
          Navigator.pop(context);
          _deleteForMe(message);
        },
        onDeleteForEveryone: canDeleteForEveryone
            ? () {
                Navigator.pop(context);
                _deleteForEveryone(message);
              }
            : null,
      ),
    );
  }

  void _deleteForMe(Message message) {
    setState(() {
      _messages = _messages.where((m) => m.id != message.id).toList();
    });
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

    final success = await ChatServiceSupabase.deleteMessageForEveryone(
      message.id,
      message.timestamp,
    );
    if (!mounted) return;
    if (!success) {
      // Revert the optimistic update.
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == message.id);
        if (idx != -1) {
          final updated = List<Message>.of(_messages);
          updated[idx] = message; // restore original
          _messages = updated;
        }
      });
      _showError('Cannot delete — message is older than 15 minutes or permission denied.');
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
          canStopSharing: message.isMe && message.isLiveLocation &&
              (message.liveUntil == null || message.liveUntil!.isAfter(DateTime.now())),
          onStopSharing: _stopLiveSharing,
        ),
      ),
    );
  }

  // ── Build flat display list (date dividers + grouped message items) ────────
  List<_ChatListItem> _buildItemsList(List<Message> messages) {
    final items = <_ChatListItem>[];
    DateTime? lastDate;

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final prevMsg = i > 0 ? messages[i - 1] : null;
      final nextMsg = i < messages.length - 1 ? messages[i + 1] : null;

      // Insert a date divider whenever the calendar day changes.
      final msgDate = DateTime(msg.timestamp.year, msg.timestamp.month, msg.timestamp.day);
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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.primaryAccent,
                child: widget.conversation.userAvatar.isNotEmpty
                    ? ClipOval(
                        child: Image.network(
                          widget.conversation.userAvatar,
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Text(
                            widget.conversation.userName.isNotEmpty
                                ? widget.conversation.userName.substring(0, 1).toUpperCase()
                                : 'U',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ),
                      )
                    : Text(
                        widget.conversation.userName.isNotEmpty
                            ? widget.conversation.userName.substring(0, 1).toUpperCase()
                            : 'U',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.conversation.userName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    if (_onlineStatus.isNotEmpty)
                      Text(
                        _onlineStatus,
                        style: TextStyle(
                          fontSize: 11,
                          color: _onlineStatus == 'online'
                              ? AppTheme.successGreen
                              : Colors.white.withValues(alpha: 0.6),
                          fontWeight: _onlineStatus == 'online'
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Iconsax.more),
              onPressed: () {},
            ),
          ],
        ),
        body: Column(
          children: [
            // Post context banner — lets the user always know what job this chat is about
            if (widget.conversation.postTitle != null && widget.conversation.postTitle!.isNotEmpty)
              _PostContextBanner(
                postTitle: widget.conversation.postTitle!,
                isDark: isDark,
                onTap: widget.conversation.postId != null && widget.conversation.postId!.isNotEmpty
                    ? () => _openPostFromChat(widget.conversation.postId!)
                    : null,
              ),
            // Escrow workflow card — shows job/payment state and action buttons.
            // Only renders when this chat is scoped to a post with a selected provider.
            if (widget.conversation.postId != null && widget.conversation.postId!.isNotEmpty)
              JobStatusCard(
                postId: widget.conversation.postId!,
                currentUserId: widget.currentUserId,
              ),
            // Messages: fetch on load, re-fetch after send, poll every 4s (no Realtime)
            Expanded(
              child: Stack(
                children: [
                Builder(
                builder: (context) {
                  final combined = List<Message>.from(_messages);
                  for (final p in _pendingMessages) {
                    final duplicate = combined.any((m) =>
                        m.isMe && m.text == p.text && m.timestamp.difference(p.timestamp).inSeconds.abs() < 15);
                    if (!duplicate) combined.add(p);
                  }
                  combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));

                  if (_loadingMessages && combined.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
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
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: items.length + (showLoadMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (showLoadMore && index == 0) {
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
                      final item = items[showLoadMore ? index - 1 : index];
                      if (item is _ChatDateDivider) {
                        return _DateDivider(date: item.date);
                      }
                      final msgItem = item as _ChatMessageItem;
                      return _MessageBubble(
                        message: msgItem.message,
                        currentUserId: widget.currentUserId,
                        senderAvatar: widget.conversation.userAvatar,
                        senderInitial: widget.conversation.userName.isNotEmpty
                            ? widget.conversation.userName.substring(0, 1).toUpperCase()
                            : '?',
                        isPending: msgItem.isPending,
                        isFirstInGroup: msgItem.isFirstInGroup,
                        isLastInGroup: msgItem.isLastInGroup,
                        isLiveSharing: _liveMessageId == msgItem.message.id,
                        onStopLiveSharing: msgItem.message.id == _liveMessageId ? _stopLiveSharing : null,
                        onTapLocation: msgItem.message.hasValidCoordinates ? () => _openFullScreenMap(msgItem.message) : null,
                        onLongPressMessage: msgItem.isPending || msgItem.message.deletedForEveryone
                            ? null
                            : _showMessageActions,
                        onTapReplyQuote: _scrollToMessage,
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
            // Typing indicator — sits between message list and input bar
            if (_otherIsTyping)
              _TypingIndicator(
                isDark: isDark,
                userName: widget.conversation.userName,
              ),
            // Reply preview bar — visible when user long-pressed a message to reply.
            if (_replyToMessage != null)
              _ReplyPreviewBar(
                replyTo: _replyToMessage!,
                isDark: isDark,
                partnerName: widget.conversation.userName,
                onCancel: () => setState(() => _replyToMessage = null),
              ),
            // Input bar — resizeToAvoidBottomInset moves the whole body up when keyboard opens;
            // SafeArea covers the home-indicator gap on notched devices.
            SafeArea(
              top: false,
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  border: Border(
                    top: BorderSide(
                      color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: _showAttachmentOptions,
                      icon: const Icon(Iconsax.attach_circle, size: 22),
                      color: AppTheme.primaryAccent,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                    IconButton(
                      onPressed: _showLocationOptions,
                      icon: const Icon(Iconsax.location, size: 22),
                      color: AppTheme.primaryAccent,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _kChatInputMaxHeight,
                        ),
                        child: TextField(
                          controller: _messageController,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          decoration: InputDecoration(
                            hintText: 'Type a message...',
                            hintStyle: TextStyle(
                              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                              fontSize: 15,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 15),
                          onSubmitted: (_) => _sendMessage(),
                          enabled: !_isSending,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _isSending ? null : _sendMessage,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _isSending
                              ? AppTheme.primaryAccent.withValues(alpha: 0.5)
                              : AppTheme.primaryAccent,
                          shape: BoxShape.circle,
                        ),
                        child: _isSending
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Icon(
                                Iconsax.send_1,
                                color: Colors.white,
                                size: 20,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin banner at the top of the chat body showing which post this conversation is about.
class _PostContextBanner extends StatelessWidget {
  final String postTitle;
  final bool isDark;
  final VoidCallback? onTap;

  const _PostContextBanner({
    required this.postTitle,
    required this.isDark,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark
        ? AppTheme.primaryAccent.withValues(alpha: 0.08)
        : AppTheme.primaryAccent.withValues(alpha: 0.06);
    final borderColor = isDark
        ? AppTheme.darkBorder
        : AppTheme.lightBorder;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(color: borderColor, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.push_pin_rounded,
              size: 14,
              color: AppTheme.primaryAccent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                postTitle,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LiveOption extends StatelessWidget {
  final int minutes;
  final VoidCallback onTap;

  const _LiveOption({required this.minutes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.secondaryAccent.withValues(alpha: 0.2),
        child: const Icon(Iconsax.location_tick, color: AppTheme.secondaryAccent, size: 20),
      ),
      title: Text('$minutes min'),
      onTap: onTap,
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
  final VoidCallback? onStopLiveSharing;
  final VoidCallback? onTapLocation;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final void Function(Message)? onLongPressMessage;
  final void Function(String replyToId)? onTapReplyQuote;

  const _MessageBubble({
    required this.message,
    required this.currentUserId,
    this.senderAvatar = '',
    this.senderInitial = '?',
    this.isPending = false,
    this.isLiveSharing = false,
    this.onStopLiveSharing,
    this.onTapLocation,
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

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(time.year, time.month, time.day);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (messageDate == today) {
      return timeStr;
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (messageDate == yesterday) {
      return 'Yesterday $timeStr';
    }
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekday = days[time.weekday - 1];
    return '$weekday $timeStr';
  }

  int? _minutesLeft(DateTime? liveUntil) {
    if (liveUntil == null) return null;
    final d = liveUntil.difference(DateTime.now());
    if (d.isNegative) return 0;
    return d.inMinutes + (d.inSeconds % 60 > 0 ? 1 : 0);
  }

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
          GestureDetector(
            onLongPress: onLongPressMessage != null ? () => onLongPressMessage!(message) : null,
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
                ] else if (isLocation) ...[
                  GestureDetector(
                    onTap: onTapLocation,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 260,
                        height: 140,
                        child: _LocationMapPreview(
                          latitude: message.latitude!,
                          longitude: message.longitude!,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (message.isLiveLocation && (message.liveUntil == null || message.liveUntil!.isAfter(DateTime.now()))) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Iconsax.location_tick,
                          size: 14,
                          color: message.isMe ? Colors.white70 : AppTheme.primaryAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Live location (${_minutesLeft(message.liveUntil) ?? 0} min left)',
                          style: TextStyle(
                            fontSize: 12,
                            color: message.isMe ? Colors.white70 : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                          ),
                        ),
                      ],
                    ),
                    if (isLiveSharing && onStopLiveSharing != null) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: onStopLiveSharing,
                        icon: const Icon(Icons.stop_circle_outlined, size: 16),
                        label: const Text('Stop sharing'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: message.isMe ? Colors.white : AppTheme.errorRed,
                        ),
                      ),
                    ],
                  ],
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
                      _formatTime(message.timestamp),
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
          ), // GestureDetector
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

/// Animated "..." bubble shown when the other participant is typing.
class _TypingIndicator extends StatefulWidget {
  final bool isDark;
  final String userName;

  const _TypingIndicator({required this.isDark, required this.userName});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = widget.isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final bgColor = widget.isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = widget.isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    // Left-align to match received message bubbles:
    // ListView has 12px left padding, avatar column is 28px + 4px gap = 44px total.
    return Padding(
      padding: const EdgeInsets.only(left: 44, bottom: 6),
      child: Row(
        // mainAxisSize defaults to max — fills width so the bubble anchors left
        // instead of being centred by the parent Column.
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(18),
              ),
              border: Border.all(color: borderColor, width: 0.5),
            ),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (_, __) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    // Stagger each dot by 200ms
                    final t = (_controller.value - i * 0.22).clamp(0.0, 1.0);
                    final opacity = (0.3 + 0.7 * (0.5 - (t - 0.5).abs() * 2).clamp(0.0, 1.0));
                    return Padding(
                      padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                      child: Opacity(
                        opacity: opacity,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                        ),
                      ),
                    );
                  }),
                );
              },
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

  String _label() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final d = DateTime(date.year, date.month, date.day);
    if (d == today) return 'Today';
    if (d == yesterday) return 'Yesterday';
    if (today.difference(d).inDays < 7) {
      const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return days[date.weekday - 1];
    }
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month]} ${date.day}';
  }

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

class _LocationMapPreview extends StatelessWidget {
  final double latitude;
  final double longitude;

  const _LocationMapPreview({required this.latitude, required this.longitude});

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(latitude, longitude),
        zoom: 15,
      ),
      markers: {
        Marker(
          markerId: const MarkerId('loc'),
          position: LatLng(latitude, longitude),
        ),
      },
      liteModeEnabled: true,
      zoomControlsEnabled: false,
      scrollGesturesEnabled: false,
      zoomGesturesEnabled: false,
      myLocationButtonEnabled: false,
      mapToolbarEnabled: false,
    );
  }
}

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

  int? get _minutesLeft {
    final u = _message.liveUntil;
    if (u == null) return null;
    final d = u.difference(DateTime.now());
    if (d.isNegative) return 0;
    return d.inMinutes + (d.inSeconds % 60 > 0 ? 1 : 0);
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
        title: Text(_message.isLiveLocation ? 'Live location' : 'Location'),
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
                      const Icon(Iconsax.timer_1, color: AppTheme.primaryAccent),
                      const SizedBox(width: 12),
                      Text(
                        'Live sharing: ${_minutesLeft ?? 0} min left',
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

// ── Message long-press action sheet ─────────────────────────────────────────

class _MessageActionsSheet extends StatelessWidget {
  final Message message;
  final bool canDeleteForEveryone;
  final VoidCallback? onCopy;
  final VoidCallback onReply;
  final VoidCallback onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;

  const _MessageActionsSheet({
    required this.message,
    required this.canDeleteForEveryone,
    required this.onCopy,
    required this.onReply,
    required this.onDeleteForMe,
    this.onDeleteForEveryone,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;

    final preview = message.text.isNotEmpty
        ? (message.text.length > 80 ? '${message.text.substring(0, 80)}…' : message.text)
        : message.isImage
            ? 'Photo'
            : message.isFile
                ? 'File'
                : 'Location';

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                preview,
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: message.text.isEmpty ? FontStyle.italic : FontStyle.normal,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            Divider(
              height: 1,
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
            if (onCopy != null)
              _ActionTile(
                icon: Icons.content_copy_rounded,
                label: 'Copy',
                onTap: onCopy!,
              ),
            _ActionTile(
              icon: Icons.reply_rounded,
              label: 'Reply',
              onTap: onReply,
            ),
            _ActionTile(
              icon: Icons.delete_outline_rounded,
              label: 'Delete for me',
              onTap: onDeleteForMe,
              color: AppTheme.errorRed,
            ),
            if (onDeleteForEveryone != null)
              _ActionTile(
                icon: Icons.delete_forever_rounded,
                label: 'Delete for everyone',
                onTap: onDeleteForEveryone!,
                color: AppTheme.errorRed,
              ),
            if (!message.isMe)
              _ActionTile(
                icon: Icons.flag_outlined,
                label: 'Report',
                onTap: () => Navigator.pop(context),
                color: AppTheme.warningOrange,
              ),
            const SizedBox(height: 8),
          ],
        ),
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
    final accentColor = AppTheme.primaryAccent;
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

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = color ?? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 15)),
      dense: true,
      onTap: onTap,
    );
  }
}

/// Minimal post detail page when opening from chat (post_id linked).
class _PostDetailPage extends StatelessWidget {
  final PostModel post;

  const _PostDetailPage({required this.post});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (post.images.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(
                  post.images.first,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                    child: const Icon(Icons.image_not_supported, size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            Text(
              post.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              post.description,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(
              '${post.location} • ${formatPriceDisplay(post.price)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
