import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_presentation.dart';
import '../models/post_model.dart';
import '../services/chat_attachments.dart';
import '../services/chat_service_supabase.dart';
import 'primitives.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/time_utils.dart';
import 'chat/chat_bubbles.dart';
import 'job_status_card.dart';

// =============================================================================
// Chat UI kit — conversation command menu, job status sheet, in-conversation
// search, the message long-press context menu and message info.
//
// Everything here is presentation-only: data flows in via parameters and out
// via callbacks, so messaging behavior (realtime, delivery, deletion rules)
// stays owned by ChatScreen and the services. Colour comes from the token
// layer; nothing here branches on brightness.
// =============================================================================

/// Actions offered by the conversation three-dot menu.
enum ChatMenuAction { viewPost, jobStatus, search, mute, clear, report }

/// Builds the three-dot menu entries. Contextual actions (post, job) appear
/// only when the chat is scoped to a post — no dead items, no clutter.
List<PopupMenuEntry<ChatMenuAction>> buildChatMenuItems(
  BuildContext context, {
  required bool hasPost,
  required bool isMuted,
}) {
  final c = AppColors.of(context);
  return [
    if (hasPost) ...[
      _menuItem(context, ChatMenuAction.viewPost,
          icon: AppIcons.fileDocument, label: 'View post'),
      _menuItem(context, ChatMenuAction.jobStatus,
          icon: AppIcons.receipt, label: 'Job status'),
    ],
    _menuItem(context, ChatMenuAction.search,
        icon: AppIcons.search, label: 'Search conversation'),
    _menuItem(
      context,
      ChatMenuAction.mute,
      icon: isMuted ? AppIcons.unmute : AppIcons.mute,
      label: isMuted ? 'Unmute notifications' : 'Mute notifications',
    ),
    PopupMenuDivider(height: 9, color: c.borderHairline),
    _menuItem(context, ChatMenuAction.clear,
        icon: AppIcons.clearChat,
        label: 'Clear conversation',
        color: c.criticalText),
    _menuItem(context, ChatMenuAction.report,
        icon: AppIcons.report, label: 'Report user', color: c.criticalText),
  ];
}

PopupMenuItem<ChatMenuAction> _menuItem(
  BuildContext context,
  ChatMenuAction action, {
  required IconData icon,
  required String label,
  Color? color,
}) {
  final c = AppColors.of(context);
  return PopupMenuItem<ChatMenuAction>(
    value: action,
    height: ChatGeometry.minTouch,
    child: Row(
      children: [
        Icon(icon, size: 20, color: color ?? c.contentSecondary),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: color ?? c.contentPrimary),
          ),
        ),
      ],
    ),
  );
}

// ── Job status sheet ─────────────────────────────────────────────────────────

/// Dedicated job-tracking surface, opened from the three-dot menu. Reuses the
/// production [JobStatusCard] (same states, same actions, same lifecycle
/// link), presented like tracking details instead of consuming chat space.
class JobStatusSheet extends StatelessWidget {
  final String postId;
  final String currentUserId;
  final String? postTitle;

  const JobStatusSheet({
    super.key,
    required this.postId,
    required this.currentUserId,
    this.postTitle,
  });

  static Future<void> show(
    BuildContext context, {
    required String postId,
    required String currentUserId,
    String? postTitle,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => JobStatusSheet(
        postId: postId,
        currentUserId: currentUserId,
        postTitle: postTitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final maxH = MediaQuery.of(context).size.height * 0.82;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.sheetTop,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.accentSubtle,
                      borderRadius: AppRadius.mdAll,
                    ),
                    child:
                        Icon(AppIcons.receipt, size: 20, color: c.accentText),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Job status',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        if (postTitle != null && postTitle!.isNotEmpty)
                          Text(
                            postTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: c.contentTertiary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(AppIcons.close, size: 22),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: c.borderHairline),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 16),
                child: JobStatusCard(
                  postId: postId,
                  currentUserId: currentUserId,
                  emptyPlaceholder: const _EmptyJobState(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyJobState extends StatelessWidget {
  const _EmptyJobState();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 28),
      child: Column(
        children: [
          Icon(AppIcons.pending, size: 40, color: c.contentTertiary),
          const SizedBox(height: 14),
          Text(
            'No active job yet',
            style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: c.contentSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            'Job tracking starts once a provider is selected for this post. '
            'Payment protection, completion and payout will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.5, color: c.contentTertiary),
          ),
        ],
      ),
    );
  }
}

// The chat sheets' drag handle used to be defined here, and four surfaces
// imported it from a file about chat. It is `SheetHandle` in primitives.dart
// now — the same widget the other fourteen sheets were hand-rolling.

// ── Conversation search ──────────────────────────────────────────────────────

/// Full-height search sheet over one conversation. Queries the server
/// (case-insensitive, tombstones excluded) with a debounce; results the chat
/// screen has locally hidden are filtered out via [isVisible].
class ConversationSearchSheet extends StatefulWidget {
  final String chatId;
  final String currentUserId;
  final String partnerName;
  final bool Function(Message) isVisible;

  /// Called AFTER the sheet closes when the user taps a result.
  final void Function(Message message)? onResultTap;

  const ConversationSearchSheet({
    super.key,
    required this.chatId,
    required this.currentUserId,
    required this.partnerName,
    required this.isVisible,
    this.onResultTap,
  });

  static Future<void> show(
    BuildContext context, {
    required String chatId,
    required String currentUserId,
    required String partnerName,
    required bool Function(Message) isVisible,
    void Function(Message message)? onResultTap,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ConversationSearchSheet(
        chatId: chatId,
        currentUserId: currentUserId,
        partnerName: partnerName,
        isVisible: isVisible,
        onResultTap: onResultTap,
      ),
    );
  }

  @override
  State<ConversationSearchSheet> createState() =>
      _ConversationSearchSheetState();
}

class _ConversationSearchSheetState extends State<ConversationSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Message> _results = const [];
  bool _searching = false;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _lastQuery = '';
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final results = await ChatServiceSupabase.searchMessages(
        widget.chatId,
        widget.currentUserId,
        q,
      );
      if (!mounted) return;
      setState(() {
        _results = results.where(widget.isVisible).toList();
        _searching = false;
        _lastQuery = q;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final height = MediaQuery.of(context).size.height * 0.88;

    return Padding(
      // Keep the sheet above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: AppRadius.sheetTop,
        ),
        child: Column(
          children: [
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onQueryChanged,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Search this conversation…',
                  hintStyle: TextStyle(color: c.contentTertiary, fontSize: 15),
                  prefixIcon:
                      Icon(AppIcons.search, size: 21, color: c.contentTertiary),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (_, value, __) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: Icon(AppIcons.close,
                                size: 19, color: c.contentTertiary),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                            },
                          ),
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: c.surfaceSunken,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: AppRadius.mdAll,
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadius.mdAll,
                    borderSide: BorderSide(color: c.borderHairline, width: 0.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadius.mdAll,
                    borderSide: BorderSide(color: c.accentText, width: 1.2),
                  ),
                ),
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: c.borderHairline),
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_lastQuery.isEmpty) {
      return _hint(
        icon: AppIcons.search,
        title: 'Search messages',
        subtitle:
            'Find prices, addresses or anything said in this conversation.',
        tertiary: c.contentTertiary,
      );
    }
    if (_results.isEmpty) {
      return _hint(
        icon: AppIcons.searchNoResults,
        title: 'No messages found',
        subtitle: 'Nothing in this conversation matches "$_lastQuery".',
        tertiary: c.contentTertiary,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _results.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        thickness: 0.5,
        indent: 16,
        endIndent: 16,
        color: c.borderHairline,
      ),
      itemBuilder: (context, index) {
        final m = _results[index];
        return _SearchResultRow(
          message: m,
          partnerName: widget.partnerName,
          query: _lastQuery,
          onTap: () {
            final onTap = widget.onResultTap;
            Navigator.of(context).pop();
            if (onTap != null) onTap(m);
          },
        );
      },
    );
  }

  Widget _hint({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color tertiary,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: tertiary),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: tertiary),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: tertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  final Message message;
  final String partnerName;
  final String query;
  final VoidCallback onTap;

  const _SearchResultRow({
    required this.message,
    required this.partnerName,
    required this.query,
    required this.onTap,
  });

  /// Bolds every case-insensitive occurrence of [query] in [text].
  TextSpan _highlight(String text, Color base, Color mark) {
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: TextStyle(fontWeight: FontWeight.w700, color: mark),
      ));
      start = idx + q.length;
    }
    return TextSpan(
        style: TextStyle(fontSize: 13.5, height: 1.4, color: base),
        children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    message.isMe ? 'You' : partnerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: message.isMe ? c.accentText : c.contentSecondary,
                    ),
                  ),
                ),
                Text(
                  formatMessageStamp(context, message.timestamp),
                  style: TextStyle(fontSize: 11, color: c.contentTertiary),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text.rich(
              _highlight(message.text, c.contentPrimary, c.accentText),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// The report flow lives in widgets/report_sheet.dart (ReportSheet): one sheet
// for accounts, listings, applications and messages.

// ── Message info ─────────────────────────────────────────────────────────────

/// The full record of one message: the date and time it was sent and, for
/// your own, when it was delivered and read. Bubbles show only the clock; a
/// dispute needs the rest, so long-press → Info always has it.
Future<void> showMessageInfo(BuildContext context, Message message) {
  final c = AppColors.of(context);
  final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
  final state = message.isMe ? chatSendStateOf(message) : null;
  String stamp(DateTime t) => chatInfoStamp(t, use24Hour: use24);
  final rows = <(String, String)>[
    (message.isMe ? 'Sent' : 'Received', stamp(message.timestamp)),
    if (state == ChatSendState.queued) ('Status', 'Waiting to send'),
    if (state == ChatSendState.failed) ('Status', 'Not sent'),
    if (message.deliveredAt != null) ('Delivered', stamp(message.deliveredAt!)),
    if (message.isMe && state == ChatSendState.sent) ('Delivered', 'Not yet'),
    if (message.seenAt != null) ('Read', stamp(message.seenAt!)),
    if (message.isMe && message.seenAt == null && state == ChatSendState.read)
      ('Read', 'Yes'),
  ];
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: SheetHandle()),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text('Message info',
                  style: Theme.of(sheet).textTheme.titleLarge),
            ),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 12.5, color: c.contentSecondary)),
                    const SizedBox(height: 2),
                    SelectableText(value,
                        style:
                            TextStyle(fontSize: 15, color: c.contentPrimary)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ── Message long-press context menu ──────────────────────────────────────────

/// Anchored context menu for a message: the pressed bubble "lifts" above a
/// blurred backdrop with the action card beneath it — replaces the old
/// bottom-sheet list. Actions are callbacks; null hides the row.
Future<void> showMessageContextMenu(
  BuildContext context, {
  required Message message,
  required Rect bubbleRect,
  VoidCallback? onReply,
  VoidCallback? onCopy,
  VoidCallback? onInfo,
  VoidCallback? onDeleteForMe,
  VoidCallback? onDeleteForEveryone,
  VoidCallback? onReport,
}) {
  HapticFeedback.mediumImpact();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Message actions',
    barrierColor: Colors.transparent, // blur layer supplies the dim
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, _, __) => _MessageContextMenu(
      message: message,
      bubbleRect: bubbleRect,
      onReply: onReply,
      onCopy: onCopy,
      onInfo: onInfo,
      onDeleteForMe: onDeleteForMe,
      onDeleteForEveryone: onDeleteForEveryone,
      onReport: onReport,
    ),
    transitionBuilder: (_, animation, __, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _MessageContextMenu extends StatelessWidget {
  final Message message;
  final Rect bubbleRect;
  final VoidCallback? onReply;
  final VoidCallback? onCopy;
  final VoidCallback? onInfo;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;
  final VoidCallback? onReport;

  const _MessageContextMenu({
    required this.message,
    required this.bubbleRect,
    this.onReply,
    this.onCopy,
    this.onInfo,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.onReport,
  });

  int get _actionCount => [
        onReply,
        onCopy,
        onInfo,
        onDeleteForMe,
        onDeleteForEveryone,
        onReport,
      ].where((a) => a != null).length;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;
    final topSafe = media.padding.top;
    final bottomSafe = media.padding.bottom;

    const menuWidth = 236.0;
    const rowH = 46.0;
    final menuH = _actionCount * rowH + 12; // + card padding
    const gap = 8.0;

    // Defensive: if rect capture ever failed, anchor to a sane center spot
    // instead of positioning off-screen.
    final anchor = bubbleRect == Rect.zero
        ? Rect.fromLTWH(
            screen.width * 0.12, screen.height * 0.30, screen.width * 0.6, 48)
        : bubbleRect;

    // Anchor at the bubble's own position; clamp so preview + menu fit.
    final maxTop = screen.height - bottomSafe - menuH - gap - 120 - 12;
    final top = anchor.top
        .clamp(topSafe + 12, math.max(topSafe + 12, maxTop))
        .toDouble();
    final maxPreviewH = screen.height - bottomSafe - top - menuH - gap - 24;

    // Horizontal alignment follows the bubble's side.
    final alignRight = message.isMe;

    final hasPrimary = onReply != null || onCopy != null || onInfo != null;
    final hasDestructive = onDeleteForMe != null ||
        onDeleteForEveryone != null ||
        onReport != null;

    // A dialog route brings no Material, so text in the lifted bubble fell
    // back to the framework's error style (yellow underlines) on device.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Blur + dim everything behind (the chat stays recognizable). The dim
          // is the media scrim's black, lighter: it darkens whatever is behind
          // it, in either theme.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: Container(
                    color: ChatColors.of(context)
                        .mediaScrim
                        .withValues(alpha: 0.35)),
              ),
            ),
          ),
          Positioned(
            top: top,
            left: alignRight ? null : math.max(12, anchor.left),
            right:
                alignRight ? math.max(12, screen.width - anchor.right) : null,
            child: Column(
              crossAxisAlignment: alignRight
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The "lifted" copy of the pressed bubble.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: screen.width * 0.76,
                    maxHeight: math.max(56, maxPreviewH),
                  ),
                  child: _BubblePreview(message: message),
                ),
                const SizedBox(height: gap),
                _ActionsCard(
                  width: menuWidth,
                  children: [
                    if (onReply != null)
                      _actionRow(context, AppIcons.reply, 'Reply', onReply!),
                    if (onCopy != null)
                      _actionRow(context, AppIcons.copy, 'Copy', onCopy!),
                    if (onInfo != null)
                      _actionRow(
                          context, AppIcons.messageInfo, 'Info', onInfo!),
                    if (hasPrimary && hasDestructive)
                      Divider(
                          height: 1, thickness: 0.5, color: c.borderHairline),
                    if (onDeleteForMe != null)
                      _actionRow(context, AppIcons.delete, 'Delete for me',
                          onDeleteForMe!,
                          color: c.criticalText),
                    if (onDeleteForEveryone != null)
                      _actionRow(context, AppIcons.delete,
                          'Delete for everyone', onDeleteForEveryone!,
                          color: c.criticalText),
                    if (onReport != null)
                      _actionRow(context, AppIcons.report, 'Report', onReport!,
                          color: c.cautionText),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop();
        onTap();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: color ?? c.contentPrimary),
                ),
              ),
              Icon(icon, size: 20, color: color ?? c.contentSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  final double width;
  final List<Widget> children;

  const _ActionsCard({required this.width, required this.children});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: c.borderHairline, width: 0.5),
        boxShadow: AppElevation.floating(Theme.of(context).brightness),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.lgAll,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

/// Static copy of the pressed bubble shown above the blur. Text-first; media
/// messages render a compact representation. Same shape and paint as the
/// bubble itself — [chatBubbleRadius], [ChatColors].
class _BubblePreview extends StatelessWidget {
  final Message message;

  const _BubblePreview({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final mine = message.isMe;
    final bg = mine ? c.outgoing : c.surface;
    final fg = mine ? c.onOutgoing : c.text;
    final muted = mine ? c.onOutgoingMuted : c.iconSecondary;

    Widget content;
    if (message.isImage && (message.attachmentUrl?.isNotEmpty ?? false)) {
      content = ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: CachedNetworkImage(
          // The same private, message-keyed entry the bubble itself drew.
          imageUrl: ChatAttachments.urlFor(message.id).toString(),
          cacheKey: ChatAttachments.cacheKeyFor(message.id),
          cacheManager: ChatAttachmentCache.instance,
          width: 200,
          height: 150,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            width: 200,
            height: 150,
            color: c.surfaceRaised,
            child: Icon(AppIcons.imageBroken, size: 40, color: c.iconSecondary),
          ),
        ),
      );
    } else if (message.isFile) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.fileDocument, size: 22, color: muted),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message.text.isNotEmpty ? message.text : 'File',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontSize: 14.5),
            ),
          ),
        ],
      );
    } else if (message.isLocation) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.location, size: 20, color: muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message.isLiveLocation
                  ? 'Live location'
                  : (message.text.isNotEmpty && message.text != 'Location'
                      ? message.text
                      : 'Location'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontSize: 14.5),
            ),
          ),
        ],
      );
    } else {
      content = SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Text(
          message.text,
          maxLines: 10,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: fg, fontSize: ChatGeometry.bodySize, height: 1.35),
        ),
      );
    }

    return Container(
      padding: ChatGeometry.textPadding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: chatBubbleRadius(mine: mine),
        boxShadow: AppElevation.floating(Theme.of(context).brightness),
      ),
      child: content,
    );
  }
}
