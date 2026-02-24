import 'dart:async';
import 'package:flutter/material.dart';
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
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../widgets/loading_empty_offline.dart';

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Text(
              'Messages',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),

          // Conversations List
          Expanded(
            child: Consumer2<AppProvider, ConnectivityProvider>(
              builder: (context, provider, connectivity, _) {
                final conversations = provider.conversations;

                if (provider.isLoadingConversations && conversations.isEmpty) {
                  return const LoadingView(message: 'Loading messages...');
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

                return RefreshIndicator(
                  onRefresh: _refreshConversations,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
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
      return '${time.day}/${time.month}';
    }
  }

  Widget _avatarLoadingPlaceholder() {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryAccent),
        ),
      ),
    );
  }

  Widget _avatarPlaceholder(String initial) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          ),
        ),
        child: Row(
          children: [
            // Avatar (network image from Supabase or initial)
            Builder(
              builder: (context) {
                final avatarUrl = conversation.userAvatar;
                final initial = conversation.userName.isNotEmpty
                    ? conversation.userName.substring(0, 1).toUpperCase()
                    : '?';
                if (avatarUrl.isNotEmpty) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: CachedNetworkImage(
                        imageUrl: avatarUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _avatarLoadingPlaceholder(),
                        errorWidget: (_, __, ___) => _avatarPlaceholder(initial),
                      ),
                    ),
                  );
                }
                return _avatarPlaceholder(initial);
              },
            ),
            const SizedBox(width: 14),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        conversation.userName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        _formatTime(conversation.lastMessageTime),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.lastMessage,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: conversation.unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (conversation.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryAccent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            conversation.unreadCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<Message> _pendingMessages = []; // Optimistic until send completes
  List<Message> _messages = [];
  bool _loadingMessages = true;
  Timer? _pollTimer;
  bool _isSending = false;
  StreamSubscription? _liveLocationSubscription;
  Timer? _liveEndTimer;
  String? _liveMessageId;
  int _lastMessageCount = 0;

  String get _chatId => widget.conversation.id;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMessages();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _loadMessages();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _liveLocationSubscription?.cancel();
    _liveEndTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Fetch messages for this chat only (no Realtime). Sorted by created_at ascending.
  Future<void> _loadMessages() async {
    if (_chatId.isEmpty) return;
    try {
      final list = await ChatServiceSupabase.getMessages(_chatId, widget.currentUserId);
      if (mounted) {
        setState(() {
          _messages = list;
          _loadingMessages = false;
        });
        if (list.length > _lastMessageCount) {
          _lastMessageCount = list.length;
          _scrollToBottom();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMessages = false);
    }
  }

  void _onScroll() {
    // Optional: load older messages for pagination later
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
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

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    _messageController.clear();

    final optimistic = Message(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: _chatId,
      senderId: widget.currentUserId,
      receiverId: '',
      text: text,
      timestamp: DateTime.now(),
      isMe: true,
      type: 'text',
    );
    setState(() => _pendingMessages.add(optimistic));
    _scrollToBottom();
    try {
      await ChatServiceSupabase.sendMessage(
        chatIdParam: _chatId,
        senderId: widget.currentUserId,
        content: text,
      );
      if (mounted) {
        setState(() => _pendingMessages.removeWhere((m) => m.id == optimistic.id));
        _loadMessages(); // Re-fetch immediately so new message appears
      }
    } catch (e) {
      if (mounted) {
        setState(() => _pendingMessages.removeWhere((m) => m.id == optimistic.id));
        _messageController.text = text;
        _showError('Failed to send. It may sync when back online.');
      }
    }
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
    final position = await LocationService.getCurrentPosition();
    if (!mounted) return;
    if (position == null) {
      setState(() => _isSending = false);
      _showError('Location unavailable. Enable location and try again.');
      return;
    }
    try {
      await ChatServiceSupabase.sendLocation(
        chatId: widget.conversation.id,
        senderId: widget.currentUserId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (mounted) {
        setState(() => _isSending = false);
        _loadMessages();
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
    final position = await LocationService.getCurrentPosition();
    if (!mounted) return;
    if (position == null) {
      setState(() => _isSending = false);
      _showError('Location unavailable. Enable location and try again.');
      return;
    }
    try {
      final message = await ChatServiceSupabase.sendLiveLocation(
        chatId: widget.conversation.id,
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
      _loadMessages();

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      onPopInvokedWithResult: (_, __) {},
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: GestureDetector(
            onTap: widget.conversation.postId != null && widget.conversation.postId!.isNotEmpty
                ? () => _openPostFromChat(widget.conversation.postId!)
                : null,
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppTheme.primaryAccent,
                        AppTheme.secondaryAccent,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: widget.conversation.userAvatar.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              widget.conversation.userAvatar,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Text(
                                widget.conversation.userName.isNotEmpty
                                    ? widget.conversation.userName.substring(0, 1).toUpperCase()
                                    : 'U',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          )
                        : Text(
                            widget.conversation.userName.isNotEmpty
                                ? widget.conversation.userName.substring(0, 1).toUpperCase()
                                : 'U',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.conversation.userName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16),
                      ),
                      if (widget.conversation.postId != null && widget.conversation.postId!.isNotEmpty)
                        Text(
                          'Tap to view post',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
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
            // Messages: fetch on load, re-fetch after send, poll every 4s (no Realtime)
            Expanded(
              child: Builder(
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
                            size: 48,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Start the conversation',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    itemCount: combined.length,
                    itemBuilder: (context, index) {
                      final msg = combined[index];
                      final isPending = msg.id.startsWith('pending_');
                      return _MessageBubble(
                        message: msg,
                        currentUserId: widget.currentUserId,
                        isPending: isPending,
                        isLiveSharing: _liveMessageId == msg.id,
                        onStopLiveSharing: msg.id == _liveMessageId ? _stopLiveSharing : null,
                        onTapLocation: msg.hasValidCoordinates ? () => _openFullScreenMap(msg) : null,
                      );
                    },
                  );
                },
              ),
            ),
            // Input
            Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 12,
                bottom: MediaQuery.of(context).padding.bottom + 12,
              ),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                border: Border(
                  top: BorderSide(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_isSending,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _isSending ? null : _sendMessage,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _isSending 
                            ? AppTheme.primaryAccent.withValues(alpha: 0.5)
                            : AppTheme.primaryAccent,
                        borderRadius: BorderRadius.circular(24),
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
                              size: 22,
                            ),
                    ),
                  ),
                ],
              ),
            ),
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
  final bool isPending;
  final bool isLiveSharing;
  final VoidCallback? onStopLiveSharing;
  final VoidCallback? onTapLocation;

  const _MessageBubble({
    required this.message,
    required this.currentUserId,
    this.isPending = false,
    this.isLiveSharing = false,
    this.onStopLiveSharing,
    this.onTapLocation,
  });

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLocation = message.isLocation && message.hasValidCoordinates;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            message.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: message.isMe
                  ? AppTheme.primaryAccent
                  : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(message.isMe ? 20 : 4),
                bottomRight: Radius.circular(message.isMe ? 4 : 20),
              ),
              border: message.isMe
                  ? null
                  : Border.all(
                      color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isLocation) ...[
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
                      fontSize: 14,
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
                        fontSize: 10,
                      ),
                    ),
                    if (isPending) ...[
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            message.isMe ? Colors.white70 : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Sending...',
                        style: TextStyle(
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                          color: message.isMe
                              ? Colors.white.withValues(alpha: 0.8)
                              : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
                        ),
                      ),
                    ] else if (message.isMe) ...[
                      const SizedBox(width: 6),
                      Text(
                        'Sent',
                        style: TextStyle(
                          fontSize: 10,
                          color: message.isMe
                              ? Colors.white.withValues(alpha: 0.6)
                              : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 200.ms).slideX(
      begin: message.isMe ? 0.2 : -0.2,
      end: 0,
    );
  }
}

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
