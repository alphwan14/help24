import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/post_model.dart';
import '../services/chat_service_supabase.dart';
import '../services/report_service.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import 'job_status_card.dart';

// =============================================================================
// Chat UI kit — conversation command menu, job status sheet, in-conversation
// search, report flow, and the message long-press context menu.
//
// Everything here is presentation-only: data flows in via parameters and out
// via callbacks, so messaging behavior (realtime, delivery, deletion rules)
// stays owned by ChatScreen and the services.
// =============================================================================

/// Actions offered by the conversation three-dot menu.
enum ChatMenuAction { viewPost, jobStatus, search, mute, clear, report }

/// Builds the three-dot menu entries. Contextual actions (post, job) appear
/// only when the chat is scoped to a post — no dead items, no clutter.
List<PopupMenuEntry<ChatMenuAction>> buildChatMenuItems({
  required bool isDark,
  required bool hasPost,
  required bool isMuted,
}) {
  final divider = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
  return [
    if (hasPost) ...[
      _menuItem(
        ChatMenuAction.viewPost,
        icon: Icons.description_outlined,
        label: 'View post',
        isDark: isDark,
      ),
      _menuItem(
        ChatMenuAction.jobStatus,
        icon: Icons.receipt_long_rounded,
        label: 'Job status',
        isDark: isDark,
      ),
    ],
    _menuItem(
      ChatMenuAction.search,
      icon: Icons.search_rounded,
      label: 'Search conversation',
      isDark: isDark,
    ),
    _menuItem(
      ChatMenuAction.mute,
      icon: isMuted
          ? Icons.notifications_active_outlined
          : Icons.notifications_off_outlined,
      label: isMuted ? 'Unmute notifications' : 'Mute notifications',
      isDark: isDark,
    ),
    PopupMenuDivider(height: 9, color: divider),
    _menuItem(
      ChatMenuAction.clear,
      icon: Icons.cleaning_services_outlined,
      label: 'Clear conversation',
      isDark: isDark,
      color: AppTheme.errorRed,
    ),
    _menuItem(
      ChatMenuAction.report,
      icon: Icons.flag_outlined,
      label: 'Report user',
      isDark: isDark,
      color: AppTheme.errorRed,
    ),
  ];
}

PopupMenuItem<ChatMenuAction> _menuItem(
  ChatMenuAction action, {
  required IconData icon,
  required String label,
  required bool isDark,
  Color? color,
}) {
  final c = color ?? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
  return PopupMenuItem<ChatMenuAction>(
    value: action,
    height: 44,
    child: Row(
      children: [
        Icon(icon, size: 20, color: color ?? (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary)),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final maxH = MediaQuery.of(context).size.height * 0.82;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.receipt_long_rounded,
                      size: 20,
                      color: AppTheme.primaryAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Job status',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        if (postTitle != null && postTitle!.isNotEmpty)
                          Text(
                            postTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: tertiary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 22),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 16),
                child: JobStatusCard(
                  postId: postId,
                  currentUserId: currentUserId,
                  emptyPlaceholder: _EmptyJobState(isDark: isDark),
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
  final bool isDark;
  const _EmptyJobState({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 28),
      child: Column(
        children: [
          Icon(Icons.hourglass_empty_rounded, size: 40, color: tertiary),
          const SizedBox(height: 14),
          Text(
            'No active job yet',
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: secondary),
          ),
          const SizedBox(height: 6),
          Text(
            'Job tracking starts once a provider is selected for this post. '
            'Payment protection, completion and payout will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: tertiary),
          ),
        ],
      ),
    );
  }
}

/// Shared drag handle for all chat sheets.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

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
  State<ConversationSearchSheet> createState() => _ConversationSearchSheetState();
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final height = MediaQuery.of(context).size.height * 0.88;

    return Padding(
      // Keep the sheet above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                  hintStyle: TextStyle(color: tertiary, fontSize: 15),
                  prefixIcon: Icon(Icons.search_rounded, size: 21, color: tertiary),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (_, value, __) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: Icon(Icons.close_rounded, size: 19, color: tertiary),
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                            },
                          ),
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: border, width: 0.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppTheme.primaryAccent, width: 1.2),
                  ),
                ),
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: border),
            Expanded(child: _buildBody(isDark, tertiary, border)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color tertiary, Color border) {
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
        icon: Icons.manage_search_rounded,
        title: 'Search messages',
        subtitle: 'Find prices, addresses or anything said in this conversation.',
        tertiary: tertiary,
      );
    }
    if (_results.isEmpty) {
      return _hint(
        icon: Icons.search_off_rounded,
        title: 'No messages found',
        subtitle: 'Nothing in this conversation matches "$_lastQuery".',
        tertiary: tertiary,
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
        color: border.withValues(alpha: 0.6),
      ),
      itemBuilder: (context, index) {
        final m = _results[index];
        return _SearchResultRow(
          message: m,
          partnerName: widget.partnerName,
          query: _lastQuery,
          isDark: isDark,
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
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: tertiary,
              ),
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
  final bool isDark;
  final VoidCallback onTap;

  const _SearchResultRow({
    required this.message,
    required this.partnerName,
    required this.query,
    required this.isDark,
    required this.onTap,
  });

  String _dateLabel(BuildContext context, DateTime t) =>
      formatMessageStamp(context, t);

  /// Bolds every case-insensitive occurrence of [query] in [text].
  TextSpan _highlight(String text, Color base) {
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
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppTheme.primaryAccent,
        ),
      ));
      start = idx + q.length;
    }
    return TextSpan(style: TextStyle(fontSize: 13.5, height: 1.4, color: base), children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final primary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
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
                      color: message.isMe
                          ? AppTheme.primaryAccent
                          : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                    ),
                  ),
                ),
                Text(
                  _dateLabel(context, message.timestamp),
                  style: TextStyle(fontSize: 11, color: tertiary),
                ),
              ],
            ),
            const SizedBox(height: 3),
            RichText(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              text: _highlight(message.text, primary),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Report user ──────────────────────────────────────────────────────────────

/// Confidential report flow. Reasons mirror the server-side CHECK constraint.
class ReportUserSheet extends StatefulWidget {
  final String reporterId;
  final String reportedUserId;
  final String reportedUserName;
  final String? chatId;
  final String? postId;
  final String? messageId;

  const ReportUserSheet({
    super.key,
    required this.reporterId,
    required this.reportedUserId,
    required this.reportedUserName,
    this.chatId,
    this.postId,
    this.messageId,
  });

  static Future<void> show(
    BuildContext context, {
    required String reporterId,
    required String reportedUserId,
    required String reportedUserName,
    String? chatId,
    String? postId,
    String? messageId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReportUserSheet(
        reporterId: reporterId,
        reportedUserId: reportedUserId,
        reportedUserName: reportedUserName,
        chatId: chatId,
        postId: postId,
        messageId: messageId,
      ),
    );
  }

  @override
  State<ReportUserSheet> createState() => _ReportUserSheetState();
}

class _ReportUserSheetState extends State<ReportUserSheet> {
  ReportReason? _selected;
  final _details = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_selected == null || _submitting) return false;
    if (_selected == ReportReason.other && _details.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    final ok = await ReportService.submitUserReport(
      reporterId: widget.reporterId,
      reportedUserId: widget.reportedUserId,
      reason: _selected!,
      details: _details.text,
      chatId: widget.chatId,
      postId: widget.postId,
      messageId: widget.messageId,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    // Capture before pop — the sheet's context deactivates on pop.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Report submitted. Our team will review it.'
            : 'Could not submit the report. Please try again later.'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: ok ? null : AppTheme.errorRed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetHandle(),
                const SizedBox(height: 8),
                Text(
                  'Report ${widget.reportedUserName}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your report is confidential — ${widget.reportedUserName} won\'t know. '
                  'Our team reviews every report.',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: tertiary),
                ),
                const SizedBox(height: 16),
                ...ReportReason.values.map((r) => _reasonRow(r, isDark, border, secondary)),
                const SizedBox(height: 12),
                TextField(
                  controller: _details,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 500,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: _selected == ReportReason.other
                        ? 'Tell us what happened (required)'
                        : 'Add details (optional)',
                    hintStyle: TextStyle(color: tertiary, fontSize: 13.5),
                    counterStyle: TextStyle(color: tertiary, fontSize: 11),
                    filled: true,
                    fillColor: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                    contentPadding: const EdgeInsets.all(14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: border, width: 0.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppTheme.primaryAccent, width: 1.2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.errorRed,
                      disabledBackgroundColor: AppTheme.errorRed.withValues(alpha: 0.35),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Submit report',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reasonRow(ReportReason r, bool isDark, Color border, Color secondary) {
    final selected = _selected == r;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _selected = r),
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primaryAccent.withValues(alpha: isDark ? 0.14 : 0.08)
                : (isDark ? AppTheme.darkCard : AppTheme.lightBackground),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppTheme.primaryAccent : border,
              width: selected ? 1.2 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                size: 19,
                color: selected ? AppTheme.primaryAccent : secondary,
              ),
              const SizedBox(width: 11),
              Text(
                r.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected
                      ? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary)
                      : secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
      onDeleteForMe: onDeleteForMe,
      onDeleteForEveryone: onDeleteForEveryone,
      onReport: onReport,
    ),
    transitionBuilder: (_, animation, __, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _MessageContextMenu extends StatelessWidget {
  final Message message;
  final Rect bubbleRect;
  final VoidCallback? onReply;
  final VoidCallback? onCopy;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;
  final VoidCallback? onReport;

  const _MessageContextMenu({
    required this.message,
    required this.bubbleRect,
    this.onReply,
    this.onCopy,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.onReport,
  });

  int get _actionCount => [
        onReply,
        onCopy,
        onDeleteForMe,
        onDeleteForEveryone,
        onReport,
      ].where((a) => a != null).length;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
        ? Rect.fromLTWH(screen.width * 0.12, screen.height * 0.30, screen.width * 0.6, 48)
        : bubbleRect;

    // Anchor at the bubble's own position; clamp so preview + menu fit.
    final maxTop = screen.height - bottomSafe - menuH - gap - 120 - 12;
    final top =
        anchor.top.clamp(topSafe + 12, math.max(topSafe + 12, maxTop)).toDouble();
    final maxPreviewH = screen.height - bottomSafe - top - menuH - gap - 24;

    // Horizontal alignment follows the bubble's side.
    final alignRight = message.isMe;

    return Stack(
      children: [
        // Blur + dim everything behind (the chat stays recognizable).
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: Container(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.25),
              ),
            ),
          ),
        ),
        Positioned(
          top: top,
          left: alignRight ? null : math.max(12, anchor.left),
          right: alignRight ? math.max(12, screen.width - anchor.right) : null,
          child: Column(
            crossAxisAlignment:
                alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The "lifted" copy of the pressed bubble.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: screen.width * 0.76,
                  maxHeight: math.max(56, maxPreviewH),
                ),
                child: _BubblePreview(message: message, isDark: isDark),
              ),
              const SizedBox(height: gap),
              _ActionsCard(
                isDark: isDark,
                width: menuWidth,
                children: [
                  if (onReply != null)
                    _actionRow(context, Icons.reply_rounded, 'Reply', onReply!,
                        isDark: isDark),
                  if (onCopy != null)
                    _actionRow(context, Icons.content_copy_rounded, 'Copy', onCopy!,
                        isDark: isDark),
                  if ((onReply != null || onCopy != null) &&
                      (onDeleteForMe != null || onDeleteForEveryone != null || onReport != null))
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    ),
                  if (onDeleteForMe != null)
                    _actionRow(context, Icons.delete_outline_rounded, 'Delete for me',
                        onDeleteForMe!,
                        isDark: isDark, color: AppTheme.errorRed),
                  if (onDeleteForEveryone != null)
                    _actionRow(context, Icons.delete_forever_rounded, 'Delete for everyone',
                        onDeleteForEveryone!,
                        isDark: isDark, color: AppTheme.errorRed),
                  if (onReport != null)
                    _actionRow(context, Icons.flag_outlined, 'Report', onReport!,
                        isDark: isDark, color: AppTheme.warningOrange),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionRow(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    required bool isDark,
    Color? color,
  }) {
    final c = color ?? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
    final iconColor =
        color ?? (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop();
        onTap();
      },
      child: SizedBox(
        height: 46,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: c),
                ),
              ),
              Icon(icon, size: 20, color: iconColor),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  final bool isDark;
  final double width;
  final List<Widget> children;

  const _ActionsCard({
    required this.isDark,
    required this.width,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.16),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
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
/// messages render a compact representation.
class _BubblePreview extends StatelessWidget {
  final Message message;
  final bool isDark;

  const _BubblePreview({required this.message, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final mine = message.isMe;
    final bg = mine
        ? AppTheme.primaryAccent
        : (isDark ? AppTheme.darkCard : AppTheme.lightCard);
    final fg = mine
        ? Colors.white
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);

    Widget content;
    if (message.isImage && (message.attachmentUrl?.isNotEmpty ?? false)) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CachedNetworkImage(
          imageUrl: message.attachmentUrl!,
          width: 200,
          height: 150,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            width: 200,
            height: 150,
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            child: const Icon(Icons.broken_image_outlined, size: 40),
          ),
        ),
      );
    } else if (message.isFile) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_rounded, size: 22, color: mine ? Colors.white70 : AppTheme.primaryAccent),
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
          Icon(Icons.location_on_rounded, size: 20, color: mine ? Colors.white70 : AppTheme.primaryAccent),
          const SizedBox(width: 6),
          Text(
            message.isLiveLocation ? 'Live location' : 'Location',
            style: TextStyle(color: fg, fontSize: 14.5),
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
          style: TextStyle(color: fg, fontSize: 15, height: 1.35),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 6),
          bottomRight: Radius.circular(mine ? 6 : 18),
        ),
        border: mine
            ? null
            : Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                width: 0.5,
              ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: content,
    );
  }
}
