import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
import '../widgets/chat/chat_bubbles.dart';
import '../widgets/loading_empty_offline.dart';
import 'image_viewer_screen.dart';

/// Message Help24: the member's one conversation with Help24, like a chat.
///
/// Staff answer from the dashboard Inbox; their answers arrive here, signed
/// "Help24 Support", with a notification. The backend is the source of truth
/// (/support/app/*); this screen shows a message the moment it is written and
/// marks it "Not sent" if the send fails, with a retry that cannot store it
/// twice (the client id).
///
/// Photos (migration 143): up to 5 per message, from the camera or the
/// gallery, shrunk on the phone and uploaded to a private bucket; a message may
/// be photos only. They show at once from the phone, then from short-lived
/// links once stored.
///
/// Copy lives here, not in en.json: a Shorebird patch cannot change assets.
/// Every icon used was already in release 1b473b7.
class SupportThreadScreen extends StatefulWidget {
  /// Injected in tests; the app uses [SupportService.instance].
  final SupportApi? api;

  /// Injected in tests; the app uses the device's gallery and camera.
  final Future<List<XFile>> Function(ImageSource source, int max)? pickPhotos;

  const SupportThreadScreen({super.key, this.api, this.pickPhotos});

  @override
  State<SupportThreadScreen> createState() => _SupportThreadScreenState();
}

class _SupportThreadScreenState extends State<SupportThreadScreen> with WidgetsBindingObserver {
  static const _uuid = Uuid();
  static const _maxPhotos = 5;

  late final SupportApi _api = widget.api ?? SupportService.instance;
  final _composer = TextEditingController();
  final _store = NotificationStore.instance;

  List<SupportMessage> _messages = const [];
  List<SupportPhoto> _staged = const [];
  bool _loading = true;
  Object? _error;
  bool _readSent = false;
  bool _hasText = false;

  String get _uid => context.read<AuthProvider>().currentUserId ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.addListener(_onNotifications);
    _composer.addListener(() {
      final has = _composer.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
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

  // ── Photos ────────────────────────────────────────────────────────────────

  Future<List<XFile>> _pick(ImageSource source, int max) async {
    final injected = widget.pickPhotos;
    if (injected != null) return injected(source, max);
    final picker = ImagePicker();
    // Shrunk on the phone: a support photo needs to be readable, not print-sized.
    // One photo (the camera, or one slot left): the multi-picker's limit must be 2 or more.
    if (source == ImageSource.camera || max < 2) {
      final one = await picker.pickImage(source: source, maxWidth: 1600, imageQuality: 82);
      return one == null ? const [] : [one];
    }
    return picker.pickMultiImage(maxWidth: 1600, imageQuality: 82, limit: max);
  }

  Future<void> _addPhotos(ImageSource source) async {
    final room = _maxPhotos - _staged.length;
    if (room <= 0) return;
    List<XFile> picked;
    try {
      picked = await _pick(source, room);
    } catch (e) {
      _toast(source == ImageSource.camera ? 'Could not open the camera.' : 'Could not open your photos.');
      return;
    }
    final photos = <SupportPhoto>[];
    var skipped = false;
    for (final f in picked.take(room)) {
      final bytes = await f.readAsBytes();
      final mime = SupportPhoto.sniffMime(bytes);
      if (mime == null) {
        skipped = true;
        continue;
      }
      photos.add(SupportPhoto(bytes: bytes, mime: mime));
    }
    if (!mounted) return;
    if (skipped) _toast('Only JPG, PNG or WebP photos can be sent.');
    if (photos.isNotEmpty) setState(() => _staged = [..._staged, ...photos]);
  }

  void _choosePhotoSource() {
    final c = AppColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(AppIcons.camera, color: c.contentSecondary),
                title: const Text('Take a photo'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _addPhotos(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Icon(AppIcons.gallery, color: c.contentSecondary),
                title: const Text('Choose from your photos'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _addPhotos(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty && _staged.isEmpty) return;
    _composer.clear();
    final pending = SupportMessage(
      id: 'local-${_uuid.v4()}',
      mine: true,
      body: text,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      state: SupportSendState.sending,
      clientId: _uuid.v4(),
      localPhotos: _staged,
    );
    setState(() {
      _messages = [..._messages, pending];
      _staged = const [];
    });
    await _deliver(pending);
  }

  Future<void> _deliver(SupportMessage m) async {
    try {
      final paths = await _api.uploadPhotos(userId: _uid, photos: m.localPhotos);
      final stored = await _api.send(userId: _uid, body: m.body, clientId: m.clientId!, photoPaths: paths);
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final x in _messages)
            if (x.id == m.id)
              x.copyWith(
                id: stored.id,
                createdAt: stored.createdAt,
                state: SupportSendState.sent,
                attachments: stored.attachments,
                // Keep showing the phone's copy until the stored ones are loaded
                // on the next refresh; the same pictures, no flicker.
                localPhotos: stored.attachments.isEmpty ? const [] : x.localPhotos,
              )
            else
              x,
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
      _toast(ErrorMapper.toMessage(e, context: m.localPhotos.isEmpty ? ErrorContext.sendMessage : ErrorContext.upload));
    }
  }

  void _retry(SupportMessage m) {
    if (m.state != SupportSendState.failed) return;
    final again = m.copyWith(state: SupportSendState.sending);
    setState(() => _messages = [for (final x in _messages) if (x.id == m.id) again else x]);
    _deliver(again);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Layout ────────────────────────────────────────────────────────────────

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
          'You can add photos too. We answer here, and you get a notification when we do.',
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
    final hasPhotos = m.localPhotos.isNotEmpty || m.attachments.isNotEmpty;
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
              // Photos sit as they do in Messages: the photo IS the bubble, edge
              // to edge, no coloured mat around it. With no words, the time rides
              // on the photo in a pill; with words, they follow under the photo.
              child: hasPhotos && m.body.isEmpty
                  ? ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.bubbleRadius)),
                      child: Stack(
                        children: [
                          _photos(m),
                          PositionedDirectional(
                            end: ChatGeometry.mediaPillInset,
                            bottom: ChatGeometry.mediaPillInset,
                            child: ChatMediaPill(time: status),
                          ),
                        ],
                      ),
                    )
                  : ClipRRect(
                      borderRadius: hasPhotos
                          ? const BorderRadius.all(Radius.circular(ChatGeometry.bubbleRadius))
                          : AppRadius.lgAll,
                      child: ColoredBox(
                        color: fill,
                        child: SizedBox(
                          width: hasPhotos ? ChatWidths.media(context) : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasPhotos) _photos(m),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
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
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The message's photos, edge to edge: one keeps its own shape (as tall as
  /// 132 to 330, cropped from the centre, like Messages); several sit in a
  /// two-column album with a hairline gap. The phone's own copies show while
  /// sending, then the stored ones, which open full screen.
  Widget _photos(SupportMessage m) {
    final local = m.localPhotos.isNotEmpty;
    final count = local ? m.localPhotos.length : m.attachments.length;
    final width = ChatWidths.media(context);
    final empty = ColoredBox(color: AppColors.of(context).surfaceSunken);

    Widget image(int i, {double? w, double? h}) {
      final Widget img = local
          ? Image.memory(m.localPhotos[i].bytes, width: w, height: h, fit: BoxFit.cover, gaplessPlayback: true)
          : Image.network(
              m.attachments[i].url,
              width: w,
              height: h,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              semanticLabel: 'Photo',
              frameBuilder: (_, child, frame, sync) =>
                  sync || frame != null ? child : SizedBox(width: w, height: h ?? ChatGeometry.photoMinHeight, child: empty),
              errorBuilder: (_, __, ___) => SizedBox(width: w, height: h ?? ChatGeometry.photoMinHeight, child: empty),
            );
      if (local) return img;
      return GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ImageViewerScreen(imageUrl: m.attachments[i].url)),
        ),
        child: img,
      );
    }

    if (count == 1) {
      return SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: ChatGeometry.photoMinHeight,
            maxHeight: ChatGeometry.photoMaxHeight,
          ),
          child: ClipRect(child: image(0, w: width)),
        ),
      );
    }
    const gap = 2.0;
    final tile = (width - gap) / 2;
    return SizedBox(
      width: width,
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (var i = 0; i < count; i++) image(i, w: tile, h: tile)],
      ),
    );
  }

  Widget _composerBar(AppColors c) {
    final canSend = _hasText || _staged.isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        color: c.surface,
        padding: const EdgeInsets.fromLTRB(AppSpace.xs, AppSpace.sm, AppSpace.sm, AppSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_staged.isNotEmpty) _stagedStrip(c),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _staged.length >= _maxPhotos ? null : _choosePhotoSource,
                  tooltip: 'Add a photo',
                  icon: Icon(AppIcons.attachment, color: c.contentSecondary),
                ),
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
                  onPressed: canSend ? _send : null,
                  tooltip: 'Send',
                  icon: const Icon(AppIcons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Photos picked for the next message, each removable before sending.
  Widget _stagedStrip(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.sm, 0, 0, AppSpace.sm),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _staged.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpace.sm),
          itemBuilder: (context, i) => Stack(
            children: [
              ClipRRect(
                borderRadius: AppRadius.mdAll,
                child: Image.memory(_staged[i].bytes, width: 64, height: 64, fit: BoxFit.cover),
              ),
              // Inside the photo's corner, so the whole button takes a tap.
              Positioned(
                top: AppSpace.xs,
                right: AppSpace.xs,
                child: Material(
                  color: c.contentPrimary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _staged = [..._staged]..removeAt(i)),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.xs / 2),
                      child: Icon(AppIcons.close, size: 14, color: c.page, semanticLabel: 'Remove photo'),
                    ),
                  ),
                ),
              ),
            ],
          ),
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
