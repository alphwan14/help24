import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/support_thread.dart';
import '../providers/auth_provider.dart';
import '../services/notification_store.dart';
import '../services/support_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/error_mapper.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';

/// Message Help24: the member's one conversation with Help24, like a chat.
///
/// Staff answer from the dashboard Inbox; their answers arrive here, signed
/// "Help24 Support", with a notification. The backend is the source of truth
/// (/support/app/*); this screen shows a message the moment it is written and
/// marks it "Not sent" if the send fails, with a retry that cannot store it
/// twice (the client id).
///
/// Copy lives here, not in en.json: a Shorebird patch cannot change assets.
class SupportThreadScreen extends StatefulWidget {
  /// Injected in tests; the app uses [SupportService.instance].
  final SupportApi? api;

  const SupportThreadScreen({super.key, this.api});

  @override
  State<SupportThreadScreen> createState() => _SupportThreadScreenState();
}

class _SupportThreadScreenState extends State<SupportThreadScreen> with WidgetsBindingObserver {
  static const _uuid = Uuid();

  late final SupportApi _api = widget.api ?? SupportService.instance;
  final _composer = TextEditingController();
  final _store = NotificationStore.instance;

  List<SupportMessage> _messages = const [];
  bool _loading = true;
  Object? _error;
  bool _readSent = false;

  String get _uid => context.read<AuthProvider>().currentUserId ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.addListener(_onNotifications);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onNotifications);
    _composer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the background: an answer may have arrived meanwhile.
    if (state == AppLifecycleState.resumed) _load(quiet: true);
  }

  /// A new answer arrived while the thread is open: show it, and its
  /// notification is already read, because the member is looking at it.
  void _onNotifications() {
    final fresh = [
      for (final n in _store.all)
        if (n.type == 'support_reply' && !n.read) n,
    ];
    if (fresh.isEmpty) return;
    for (final n in fresh) {
      unawaited(_store.markRead(n.id));
    }
    _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    final uid = _uid;
    if (uid.isEmpty) {
      setState(() {
        _loading = false;
        _error = SupportException('Not signed in', statusCode: 401);
      });
      return;
    }
    if (!quiet && _messages.isEmpty) setState(() => _loading = true);
    try {
      final thread = await _api.thread(uid);
      if (!mounted) return;
      setState(() {
        // Messages still in flight or not sent stay at the bottom until they land.
        final local = [
          for (final m in _messages)
            if (m.state != SupportSendState.sent) m,
        ];
        _messages = [...thread.messages, ...local];
        _loading = false;
        _error = null;
      });
      _onNotificationsSeen();
      if (thread.unread > 0 || !_readSent) {
        _readSent = true;
        unawaited(_api.markRead(uid).catchError((_) {}));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A quiet refresh that fails keeps what is on screen.
        if (_messages.isEmpty) _error = e;
      });
    }
  }

  /// Opening the thread reads its notifications too.
  void _onNotificationsSeen() {
    for (final n in _store.all) {
      if (n.type == 'support_reply' && !n.read) unawaited(_store.markRead(n.id));
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    final pending = SupportMessage(
      id: 'local-${_uuid.v4()}',
      mine: true,
      body: text,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      state: SupportSendState.sending,
      clientId: _uuid.v4(),
    );
    setState(() => _messages = [..._messages, pending]);
    await _deliver(pending);
  }

  Future<void> _deliver(SupportMessage m) async {
    try {
      final stored = await _api.send(userId: _uid, body: m.body, clientId: m.clientId!);
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final x in _messages)
            if (x.id == m.id) x.copyWith(id: stored.id, createdAt: stored.createdAt, state: SupportSendState.sent) else x,
        ];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final x in _messages)
            if (x.id == m.id) x.copyWith(state: SupportSendState.failed) else x,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.toMessage(e, context: ErrorContext.sendMessage))),
      );
    }
  }

  void _retry(SupportMessage m) {
    if (m.state != SupportSendState.failed) return;
    final again = m.copyWith(state: SupportSendState.sending);
    setState(() => _messages = [for (final x in _messages) if (x.id == m.id) again else x]);
    _deliver(again);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      appBar: AppBar(title: const Text('Help24 Support'), elevation: 0),
      body: ReconnectListener(
        onReconnect: () => _load(quiet: true),
        child: Column(
          children: [
            Expanded(child: _body(c)),
            if (_error == null && !_loading) _composerBar(c),
          ],
        ),
      ),
    );
  }

  Widget _body(AppColors c) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorRetryView.fromError(_error, onRetry: () => _load());
    }
    if (_messages.isEmpty) return _intro(c);
    final items = _messages.reversed.toList();
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView.builder(
        reverse: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.lg, AppSpace.gutter, AppSpace.lg),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final m = items[i];
          // In a reversed list the item below is the one BEFORE it in time.
          final previous = i + 1 < items.length ? items[i + 1] : null;
          final firstOfRun = previous == null || previous.mine != m.mine;
          return Padding(
            padding: EdgeInsets.only(top: firstOfRun ? AppSpace.md : AppSpace.xs),
            child: _bubble(c, m, showName: firstOfRun && !m.mine),
          );
        },
      ),
    );
  }

  Widget _intro(AppColors c) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        const SizedBox(height: AppSpace.xxxl),
        Icon(AppIcons.support, size: AppSpace.xxxl, color: c.contentTertiary),
        const SizedBox(height: AppSpace.lg),
        Text(
          'Message Help24',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.contentPrimary),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'Ask us anything about a job, a payment or your account. '
          'We answer here, and you get a notification when we do.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.4, color: c.contentSecondary),
        ),
      ],
    );
  }

  Widget _bubble(AppColors c, SupportMessage m, {required bool showName}) {
    final chat = ChatColors.of(context);
    final mine = m.mine;
    final fill = mine ? chat.outgoing : chat.surfaceRaised;
    final ink = mine ? chat.onOutgoing : chat.text;
    final meta = mine ? chat.onOutgoingMuted : chat.textSecondary;
    final status = switch (m.state) {
      SupportSendState.sending => 'Sending',
      SupportSendState.failed => 'Not sent. Tap to try again.',
      SupportSendState.sent => _time(m.createdAt),
    };
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * ChatGeometry.textMaxFraction),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (showName)
              Padding(
                padding: const EdgeInsets.only(left: AppSpace.xs, bottom: AppSpace.xs),
                child: Text(
                  'Help24 Support',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.contentSecondary),
                ),
              ),
            GestureDetector(
              onTap: m.state == SupportSendState.failed ? () => _retry(m) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                decoration: BoxDecoration(color: fill, borderRadius: AppRadius.lgAll),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      m.body,
                      style: TextStyle(fontSize: ChatGeometry.bodySize, height: 1.33, color: ink),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: ChatGeometry.metaSize,
                        color: m.state == SupportSendState.failed ? c.criticalText : meta,
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

  Widget _composerBar(AppColors c) {
    return SafeArea(
      top: false,
      child: Container(
        color: c.surface,
        padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.sm, AppSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 5,
                maxLength: 10000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Write to Help24',
                  counterText: '',
                  border: OutlineInputBorder(borderRadius: AppRadius.pillAll, borderSide: BorderSide.none),
                  filled: true,
                  fillColor: c.surfaceSunken,
                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
                ),
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            IconButton.filled(
              onPressed: _send,
              tooltip: 'Send',
              icon: const Icon(AppIcons.send),
            ),
          ],
        ),
      ),
    );
  }

  static const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "14:05" today, "3 Nov, 14:05" before.
  String _time(String iso) {
    final utc = parseServerTimeOrNull(iso);
    if (utc == null) return '';
    final local = utc.toLocal();
    final now = DateTime.now();
    final clock = formatClockTime(context, utc);
    final today = local.year == now.year && local.month == now.month && local.day == now.day;
    return today ? clock : '${local.day} ${_months[local.month - 1]}, $clock';
  }
}
