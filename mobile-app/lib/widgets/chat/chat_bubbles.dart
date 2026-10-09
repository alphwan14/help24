import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../models/chat_presentation.dart';
import '../../models/post_model.dart';
import '../../services/chat_attachments.dart';
import '../../services/chat_media_store.dart';
import '../../services/chat_documents.dart';
import '../../services/outbox_delivery.dart' show OutboxIds;
import '../../services/place_name_cache.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import '../../utils/format_utils.dart';
import '../location_experience.dart';

// =============================================================================
// THE CHAT'S MESSAGE COMPONENTS.
//
// One rule above all the others here: every colour is a ChatColors token and
// every size a ChatGeometry constant, so light and dark are the same component
// with different paint — never a branch. And every message keeps a visible
// time: disputes are settled on these stamps.
// =============================================================================

// ── Widths ───────────────────────────────────────────────────────────────────

/// How wide things may be on THIS screen: the canvas values on a 390-wide
/// phone, scaled down on a narrower one.
class ChatWidths {
  const ChatWidths._();

  static double _screen(BuildContext context) => MediaQuery.sizeOf(context).width;

  static double text(BuildContext context) =>
      math.min(ChatGeometry.textMaxWidth, _screen(context) * ChatGeometry.textMaxFraction);

  static double media(BuildContext context) =>
      math.min(ChatGeometry.mediaWidth, _screen(context) * ChatGeometry.mediaMaxFraction);

  static double offer(BuildContext context) =>
      math.min(ChatGeometry.offerCardWidth, _screen(context) * ChatGeometry.textMaxFraction);
}

// ── Shape ────────────────────────────────────────────────────────────────────

/// The corners of one bubble, given where it sits in its run.
///
/// 18 everywhere, except where it meets a neighbour from the same sender:
/// those corners — on the SENDER'S side only — drop to 6, so a run reads as
/// one block. A message on its own is 18 on all four corners. Directional, so
/// the sender's side follows the reading direction.
BorderRadiusDirectional chatBubbleRadius({
  required bool mine,
  bool isFirstInGroup = true,
  bool isLastInGroup = true,
}) {
  const outer = Radius.circular(ChatGeometry.bubbleRadius);
  const join = Radius.circular(ChatGeometry.bubbleJoinRadius);
  final top = isFirstInGroup ? outer : join;
  final bottom = isLastInGroup ? outer : join;
  return mine
      ? BorderRadiusDirectional.only(topStart: outer, bottomStart: outer, topEnd: top, bottomEnd: bottom)
      : BorderRadiusDirectional.only(topStart: top, bottomStart: bottom, topEnd: outer, bottomEnd: outer);
}

BorderRadiusDirectional _radiusFor(Message m, RunPosition p) =>
    chatBubbleRadius(mine: m.isMe, isFirstInGroup: p.first, isLastInGroup: p.last);

// ── Time and ticks ───────────────────────────────────────────────────────────

/// The width each state's indicator occupies after the time, so the space a
/// bubble reserves for its meta is exact.
double _statusSlot(ChatSendState? s) => switch (s) {
      null || ChatSendState.failed => 0,
      ChatSendState.queued => 13,
      ChatSendState.sent => ChatGeometry.tickSize,
      ChatSendState.delivered || ChatSendState.read => ChatGeometry.doubleTickWidth,
    };

const double _statusGap = 3;

String _stateWords(ChatSendState s) => switch (s) {
      ChatSendState.queued => 'Waiting to send',
      ChatSendState.sent => 'Sent',
      ChatSendState.delivered => 'Delivered',
      ChatSendState.read => 'Read',
      ChatSendState.failed => 'Not sent',
    };

/// Clock, one tick, two ticks, two coloured ticks.
class ChatStatusIcon extends StatelessWidget {
  const ChatStatusIcon({super.key, required this.state, required this.color, required this.readColor});

  final ChatSendState state;
  final Color color;
  final Color readColor;

  @override
  Widget build(BuildContext context) {
    final Widget icon = switch (state) {
      ChatSendState.queued => Icon(AppIcons.messageSending, size: 12.5, color: color),
      ChatSendState.sent => Icon(AppIcons.messageSent, size: ChatGeometry.tickSize, color: color),
      ChatSendState.delivered => Icon(AppIcons.messageDelivered, size: 16, color: color),
      ChatSendState.read => Icon(AppIcons.messageDelivered, size: 16, color: readColor),
      ChatSendState.failed => const SizedBox.shrink(),
    };
    return Semantics(
      label: _stateWords(state),
      child: SizedBox(
        width: _statusSlot(state),
        height: ChatGeometry.statusSlotHeight,
        child: Center(
          child: AnimatedSwitcher(
            duration: AppMotion.transition,
            child: KeyedSubtree(key: ValueKey(state), child: icon),
          ),
        ),
      ),
    );
  }
}

/// "1:15 PM ✓✓" — the time and, on your own messages, its state.
class ChatMeta extends StatelessWidget {
  const ChatMeta({
    super.key,
    required this.time,
    required this.color,
    this.state,
    this.readColor,
    this.fontSize = ChatGeometry.metaSize,
    this.fontWeight = FontWeight.w400,
  });

  final String time;
  final ChatSendState? state;
  final Color color;
  final Color? readColor;
  final double fontSize;
  final FontWeight fontWeight;

  static TextStyle styleFor(double size, FontWeight weight, Color color) => TextStyle(
        fontSize: size,
        height: ChatGeometry.metaLine / ChatGeometry.metaSize,
        fontWeight: weight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// The exact width this meta will occupy — what a text bubble reserves at
  /// the end of its last line.
  static double measure(
    BuildContext context,
    String time,
    ChatSendState? state, {
    double fontSize = ChatGeometry.metaSize,
    FontWeight fontWeight = FontWeight.w400,
  }) {
    final style = DefaultTextStyle.of(context).style.merge(styleFor(fontSize, fontWeight, Colors.transparent));
    final tp = TextPainter(
      text: TextSpan(text: time, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = tp.width;
    tp.dispose();
    final slot = _statusSlot(state);
    return width + (slot > 0 ? _statusGap + slot : 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(time, maxLines: 1, softWrap: false, style: styleFor(fontSize, fontWeight, color)),
        if (s != null && _statusSlot(s) > 0) ...[
          const SizedBox(width: _statusGap),
          ChatStatusIcon(state: s, color: color, readColor: readColor ?? color),
        ],
      ],
    );
  }
}

/// The time pill on a photo or a map: black at 55% under white, the same in
/// both themes because it sits on a picture.
class ChatMediaPill extends StatelessWidget {
  const ChatMediaPill({super.key, required this.time, this.state});

  final String time;
  final ChatSendState? state;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: ChatGeometry.mediaPillHeight),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: c.mediaScrim,
        borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.mediaPillRadius)),
      ),
      child: ChatHug(
        child: ChatMeta(
          time: time,
          state: state,
          color: c.onMedia,
          readColor: c.statusRead,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Centres [child] within a capsule's minimum height while sizing to it.
///
/// A `Container(alignment: …)` does the centring but also STRETCHES to fill
/// whatever room its parent offers — which is how a day pill came out the
/// width of the screen. This hugs the content in both directions.
class ChatHug extends StatelessWidget {
  const ChatHug({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [child],
      );
}

// ── Text with the time on its last line ──────────────────────────────────────

/// Body text whose time sits INLINE at the end of the last line, and moves to
/// a line of its own only when that line has no room for it.
///
/// The text is laid out once with the same style, scaler and width the
/// [Text] below uses, so the decision is exact rather than estimated: the
/// last line's width plus the meta's width either fits or it does not. A
/// one-word "Hello" is therefore a single 34 px bubble.
class ChatInlineText extends StatelessWidget {
  const ChatInlineText({
    super.key,
    required this.text,
    required this.style,
    required this.meta,
    required this.metaWidth,
  });

  final String text;
  final TextStyle style;
  final Widget meta;
  final double metaWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final defaults = DefaultTextStyle.of(context);
      final effective = defaults.style.merge(style);
      final tp = TextPainter(
        text: TextSpan(text: text, style: effective),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textWidthBasis: TextWidthBasis.longestLine,
        textHeightBehavior: defaults.textHeightBehavior,
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final lines = tp.computeLineMetrics();
      final last = lines.isEmpty ? 0.0 : lines.last.width;
      final needed = last + ChatGeometry.metaGap + metaWidth;
      final inline = needed <= constraints.maxWidth;
      final width = math.min(
        constraints.maxWidth,
        (inline ? math.max(tp.width, needed) : math.max(tp.width, metaWidth)).ceilToDouble(),
      );
      // Its own line: as tall as a line of body text, so the rhythm holds.
      final height = inline ? tp.height : tp.height + tp.preferredLineHeight;
      tp.dispose();
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Text(text, style: style, textWidthBasis: TextWidthBasis.longestLine),
            PositionedDirectional(end: 0, bottom: -1, child: meta),
          ],
        ),
      );
    });
  }
}

TextStyle _bodyStyle(Color color) => TextStyle(
      fontSize: ChatGeometry.bodySize,
      height: ChatGeometry.bodyLine / ChatGeometry.bodySize,
      color: color,
    );

/// The colours a bubble is drawn in, by side.
class _Paint {
  _Paint(ChatColors c, bool mine)
      : fill = mine ? c.outgoing : c.surface,
        fg = mine ? c.onOutgoing : c.text,
        muted = mine ? c.onOutgoingMuted : c.textSecondary,
        read = c.statusRead;

  final Color fill;
  final Color fg;
  final Color muted;
  final Color read;
}

/// The quoted message a reply answers, inside the reply's bubble.
class ChatReplyQuote extends StatelessWidget {
  const ChatReplyQuote({super.key, required this.message, this.onTap});

  final Message message;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final mine = message.isMe;
    final preview = message.replyToPreview ?? '';
    return Semantics(
      button: onTap != null,
      label: 'Reply to ${message.replyToSender ?? 'a message'}: $preview',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ClipRRect(
            borderRadius: AppRadius.smAll,
            child: ColoredBox(
              color: mine ? c.quoteOnOutgoing : c.bg,
              child: IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColoredBox(color: mine ? c.onOutgoingMuted : c.accent, child: const SizedBox(width: 3)),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(9, 6, 10, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              message.replyToSender ?? 'Unknown',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: mine ? c.onOutgoing : c.accentText,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: mine ? c.onOutgoingMuted : c.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Text ─────────────────────────────────────────────────────────────────────

class ChatTextBubble extends StatelessWidget {
  const ChatTextBubble({
    super.key,
    required this.message,
    required this.position,
    required this.time,
    this.state,
    this.onTapQuote,
  });

  final Message message;
  final RunPosition position;
  final String time;
  final ChatSendState? state;
  final VoidCallback? onTapQuote;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final p = _Paint(c, message.isMe);
    final hasQuote = message.replyToId != null && message.replyToPreview != null;
    return Container(
      constraints: BoxConstraints(maxWidth: ChatWidths.text(context)),
      padding: ChatGeometry.textPadding,
      decoration: BoxDecoration(color: p.fill, borderRadius: _radiusFor(message, position)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasQuote) ChatReplyQuote(message: message, onTap: onTapQuote),
          ChatInlineText(
            text: message.text,
            style: _bodyStyle(p.fg),
            metaWidth: ChatMeta.measure(context, time, state),
            meta: ChatMeta(time: time, state: state, color: p.muted, readColor: p.read),
          ),
        ],
      ),
    );
  }
}

/// A message its sender deleted for everyone. It keeps its place and its
/// time — the record that something was said is part of the job record.
class ChatTombstoneBubble extends StatelessWidget {
  const ChatTombstoneBubble({super.key, required this.message, required this.position, required this.time});

  final Message message;
  final RunPosition position;
  final String time;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final style = _bodyStyle(c.textSecondary).copyWith(fontStyle: FontStyle.italic, fontSize: 14);
    return Container(
      constraints: BoxConstraints(maxWidth: ChatWidths.text(context)),
      padding: ChatGeometry.textPadding,
      decoration: BoxDecoration(
        borderRadius: _radiusFor(message, position),
        border: Border.all(color: c.border),
      ),
      child: ChatInlineText(
        text: 'This message was deleted',
        style: style,
        metaWidth: ChatMeta.measure(context, time, null),
        meta: ChatMeta(time: time, color: c.textSecondary),
      ),
    );
  }
}

// ── Photo ────────────────────────────────────────────────────────────────────

/// Photo shapes already measured this session, by message id, so a photo
/// scrolled back into view opens at its real height rather than re-settling.
class ChatPhotoAspects {
  ChatPhotoAspects._();
  static final Map<String, double> _byId = {};

  static double? of(String id) => _byId[_key(id)];
  static void remember(String id, double aspect) => _byId[_key(id)] = aspect;

  /// A queued photo and its delivered row share one entry.
  static String _key(String id) => (OutboxIds.serverIdOf(id) ?? id).toLowerCase();
}

/// The photo IS the bubble: no mat, the group's corners, a width of 264, and
/// a height from the photo's own shape, clamped to 132–330 and centre-cropped.
///
/// The time rides on the photo in a pill; a caption moves it inline under the
/// photo instead. A photo still sending shows its upload as a ring on the
/// photo itself — tap the ring to stop it.
class ChatPhotoBubble extends StatefulWidget {
  const ChatPhotoBubble({
    super.key,
    required this.message,
    required this.position,
    required this.time,
    this.state,
    this.localPath,
    this.onOpen,
    this.onCancel,
  });

  final Message message;
  final RunPosition position;
  final String time;
  final ChatSendState? state;

  /// The queued copy on this phone, until the server has the photo.
  final String? localPath;
  final VoidCallback? onOpen;

  /// Stop sending (queued or uploading photos only).
  final VoidCallback? onCancel;

  @override
  State<ChatPhotoBubble> createState() => _ChatPhotoBubbleState();
}

class _ChatPhotoBubbleState extends State<ChatPhotoBubble> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;

  bool get _hasCaption {
    final t = widget.message.text.trim();
    return t.isNotEmpty && t != 'Image';
  }

  ImageProvider _provider(BuildContext context) {
    final local = widget.localPath;
    if (local != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      // Decoded at bubble size: a queue of photos must not hold
      // full-resolution bitmaps in memory.
      return ResizeImage(FileImage(File(local)), width: (ChatGeometry.mediaWidth * dpr).round());
    }
    return CachedNetworkImageProvider(
      // Private: fetched by message id with the user's token, never from a
      // storage address.
      ChatAttachments.urlFor(widget.message.id).toString(),
      cacheKey: ChatAttachments.cacheKeyFor(widget.message.id),
      cacheManager: ChatAttachmentCache.instance,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aspect ??= ChatPhotoAspects.of(widget.message.id);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ChatPhotoBubble old) {
    super.didUpdateWidget(old);
    if (old.localPath != widget.localPath || old.message.id != widget.message.id) _resolve();
  }

  void _resolve() {
    final stream = _provider(context).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _unlisten();
    _listener = ImageStreamListener(_onImage, onError: (_, __) {
      // The full photo is out of reach (offline, or evicted from the image
      // cache): take the shape from the thumbnail kept on this phone.
      final thumb = _thumb;
      if (thumb == null || _aspect != null) return;
      FileImage(thumb)
          .resolve(createLocalImageConfiguration(context))
          .addListener(ImageStreamListener(_onImage, onError: (_, __) {}));
    });
    _stream = stream..addListener(_listener!);
  }

  void _onImage(ImageInfo info, bool _) {
    final w = info.image.width, h = info.image.height;
    if (w <= 0 || h <= 0) return;
    final aspect = w / h;
    ChatPhotoAspects.remember(widget.message.id, aspect);
    if (mounted && (_aspect == null || (_aspect! - aspect).abs() > 0.01)) {
      setState(() => _aspect = aspect);
    }
  }

  /// The photo's thumbnail on this phone (ChatMediaStore) — what the bubble
  /// shows while the full photo loads, and instead of it when it cannot.
  File? get _thumb => widget.localPath != null ? null : ChatMediaStore.thumbFor(widget.message.id);

  void _unlisten() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _listener = null;
  }

  @override
  void dispose() {
    _unlisten();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final p = _Paint(c, widget.message.isMe);
    final width = ChatWidths.media(context);
    // Until the photo's shape is known, 4:3 — the shape most phone photos are.
    final aspect = _aspect ?? 4 / 3;
    final height = (width / aspect).clamp(ChatGeometry.photoMinHeight, ChatGeometry.photoMaxHeight);
    final caption = _hasCaption;
    final serverId = OutboxIds.serverIdOf(widget.message.id);
    final thumb = _thumb;

    final photo = SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(
            // The message id is stable and unique, so the photo lifts into
            // the viewer instead of cutting to it.
            tag: 'chat_image_${widget.message.id}',
            child: Image(
              image: _provider(context),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: (_, child, frame, sync) => sync || frame != null
                  ? child
                  : (thumb != null
                      ? Image.file(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                      : ColoredBox(color: c.surface)),
              errorBuilder: (_, __, ___) => thumb != null
                  ? Image.file(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                  : ColoredBox(
                      color: c.surface,
                      child: Center(child: Icon(AppIcons.imageBroken, size: 36, color: c.iconSecondary)),
                    ),
            ),
          ),
          if (!caption)
            PositionedDirectional(
              end: ChatGeometry.mediaPillInset,
              bottom: ChatGeometry.mediaPillInset,
              child: ChatMediaPill(time: widget.time, state: widget.state),
            ),
          if (widget.onCancel != null && serverId != null)
            Center(child: _UploadRing(messageId: serverId, onCancel: widget.onCancel!, label: 'Stop sending this photo')),
        ],
      ),
    );

    final semantics = [
      'Photo',
      if (caption) widget.message.text.trim(),
      widget.time,
      if (widget.state != null) _stateWords(widget.state!),
    ].join('. ');

    return Semantics(
      button: widget.onOpen != null,
      label: widget.onOpen != null ? '$semantics. Double tap to view full screen.' : semantics,
      child: GestureDetector(
        onTap: widget.onOpen,
        child: ClipRRect(
          borderRadius: _radiusFor(widget.message, widget.position),
          child: ColoredBox(
            color: caption ? p.fill : c.surface,
            child: caption
                ? SizedBox(
                    width: width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        photo,
                        Padding(
                          padding: ChatGeometry.textPadding,
                          child: ChatInlineText(
                            text: widget.message.text.trim(),
                            style: _bodyStyle(p.fg),
                            metaWidth: ChatMeta.measure(context, widget.time, widget.state),
                            meta: ChatMeta(time: widget.time, state: widget.state, color: p.muted, readColor: p.read),
                          ),
                        ),
                      ],
                    ),
                  )
                : photo,
          ),
        ),
      ),
    );
  }
}

/// Upload progress drawn on the attachment itself, with a ✕ to stop it.
/// While a request is open the ring fills; while the attachment only waits
/// for a network it is an empty ring — still stoppable.
class _UploadRing extends StatelessWidget {
  const _UploadRing({required this.messageId, required this.onCancel, required this.label});

  final String messageId;
  final VoidCallback onCancel;
  final String label;
  static const double diameter = 40;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onCancel();
        },
        child: SizedBox(
          width: math.max(diameter, ChatGeometry.minTouch),
          height: math.max(diameter, ChatGeometry.minTouch),
          child: Center(
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(color: c.mediaScrim, shape: BoxShape.circle),
              child: ValueListenableBuilder<double?>(
                valueListenable: ChatUploads.progressOf(messageId),
                builder: (_, progress, __) => Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: diameter - 8,
                      height: diameter - 8,
                      child: CircularProgressIndicator(
                        value: progress ?? 0,
                        strokeWidth: 2.5,
                        color: c.onMedia,
                        backgroundColor: c.onMedia.withValues(alpha: 0.3),
                      ),
                    ),
                    Icon(AppIcons.close, size: diameter * 0.45, color: c.onMedia),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Location ─────────────────────────────────────────────────────────────────

/// A shared place: the map edge to edge at the top, the time on the map, and
/// a footer that says WHERE — the name the sender gave it, then the area.
///
/// Directions only on a pin you RECEIVED: the sender is the one person who
/// does not need them. Tapping anywhere else opens the full map, which has
/// Directions and Copy address for both sides.
class ChatLocationBubble extends StatefulWidget {
  const ChatLocationBubble({
    super.key,
    required this.message,
    required this.position,
    required this.time,
    this.state,
    this.viewerLat,
    this.viewerLng,
    this.onOpen,
  });

  final Message message;
  final RunPosition position;
  final String time;
  final ChatSendState? state;

  /// Where the viewer is — set only when location permission was ALREADY
  /// granted; this card never asks.
  final double? viewerLat;
  final double? viewerLng;
  final VoidCallback? onOpen;

  @override
  State<ChatLocationBubble> createState() => _ChatLocationBubbleState();
}

class _ChatLocationBubbleState extends State<ChatLocationBubble> {
  String? _area;

  double get _lat => widget.message.latitude!;
  double get _lng => widget.message.longitude!;

  @override
  void initState() {
    super.initState();
    _area = PlaceNameCache.peek(_lat, _lng);
    if (_area == null) {
      // The phone's own geocoder: free, cached for the session, never blocks.
      PlaceNameCache.resolve(_lat, _lng).then((name) {
        if (mounted && name != null && name != _area) setState(() => _area = name);
      });
    }
  }

  String get _label {
    final t = widget.message.text.trim();
    return t.isEmpty || t == 'Location' ? '' : t;
  }

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final mine = widget.message.isMe;
    final p = _Paint(c, mine);
    final width = ChatWidths.media(context);
    final title = _label.isNotEmpty ? _label : (_area ?? 'Pinned location');
    final distance = mine
        ? null
        : distanceAwayText(fromLat: widget.viewerLat, fromLng: widget.viewerLng, toLat: _lat, toLng: _lng);
    final area = _area != null && _area != title ? _area : null;
    final second = [if (distance != null) distance, if (area != null) area].join(' · ');

    final footer = Stack(
      children: [
        Padding(
          padding: ChatGeometry.locationFooterPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Icon(AppIcons.location, size: ChatGeometry.pinIcon, color: mine ? p.fg : c.iconSecondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, height: 19 / 14.5, fontWeight: FontWeight.w600, color: p.fg),
                    ),
                    if (second.isNotEmpty)
                      Text(
                        second,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, height: 17 / 12.5, color: p.muted),
                      ),
                  ],
                ),
              ),
              // Room for the Directions button, which is drawn over this
              // corner so its 44 px target can reach into the padding.
              if (!mine) const SizedBox(width: ChatGeometry.directionsDiameter - 4),
            ],
          ),
        ),
        if (!mine)
          PositionedDirectional(
            end: ChatGeometry.locationFooterPadding.end - (ChatGeometry.minTouch - ChatGeometry.directionsDiameter) / 2,
            top: 0,
            bottom: 0,
            child: Center(
              child: _DirectionsButton(
                label: 'Directions to $title',
                onTap: () => launchDirections(_lat, _lng, label: title),
              ),
            ),
          ),
      ],
    );

    return Semantics(
      label: [
        mine ? 'You shared a place' : 'Shared place',
        title,
        if (second.isNotEmpty) second,
        widget.time,
        if (widget.state != null) _stateWords(widget.state!),
      ].join('. '),
      child: ClipRRect(
        borderRadius: _radiusFor(widget.message, widget.position),
        child: Material(
          color: p.fill,
          child: InkWell(
            onTap: widget.onOpen,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: width,
                    height: ChatGeometry.mapHeight,
                    child: Stack(
                      // The map is a picture of the place, never a layer that
                      // can spill into the footer under it.
                      clipBehavior: Clip.hardEdge,
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(child: MapThumbnail(latitude: _lat, longitude: _lng)),
                        PositionedDirectional(
                          end: ChatGeometry.mediaPillInset,
                          bottom: ChatGeometry.mediaPillInset,
                          child: ChatMediaPill(time: widget.time, state: widget.state),
                        ),
                      ],
                    ),
                  ),
                  footer,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionsButton extends StatelessWidget {
  const _DirectionsButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: ChatGeometry.minTouch,
        height: ChatGeometry.minTouch,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Center(
              child: Container(
                width: ChatGeometry.directionsDiameter,
                height: ChatGeometry.directionsDiameter,
                decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                child: Icon(AppIcons.directions, size: 18, color: c.onAccent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── File ─────────────────────────────────────────────────────────────────────

/// Sizes already known this session, by message: from the queued copy while a
/// file is sending, or the downloaded copy once opened. Nothing is fetched
/// only to measure it.
class ChatFileSizes {
  ChatFileSizes._();
  static final Map<String, int> _byId = {};

  static String _key(String id) => (OutboxIds.serverIdOf(id) ?? id).toLowerCase();
  static int? of(String id) => _byId[_key(id)];
  static void remember(String id, int bytes) => _byId[_key(id)] = bytes;
}

/// A document: its first page (or a type badge), its name on one line, then
/// "PDF · 148 KB" with the time and state at the end.
class ChatFileBubble extends StatefulWidget {
  const ChatFileBubble({
    super.key,
    required this.message,
    required this.position,
    required this.time,
    this.state,
    this.localPath,
    this.onOpen,
    this.onCancel,
  });

  final Message message;
  final RunPosition position;
  final String time;
  final ChatSendState? state;
  final String? localPath;
  final VoidCallback? onOpen;
  final VoidCallback? onCancel;

  @override
  State<ChatFileBubble> createState() => _ChatFileBubbleState();
}

class _ChatFileBubbleState extends State<ChatFileBubble> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = ChatFileSizes.of(widget.message.id);
    if (_bytes == null) unawaited(_measure());
  }

  @override
  void didUpdateWidget(covariant ChatFileBubble old) {
    super.didUpdateWidget(old);
    if (_bytes == null && old.localPath != widget.localPath) unawaited(_measure());
  }

  Future<void> _measure() async {
    try {
      int? size;
      final local = widget.localPath;
      if (local != null) {
        size = await File(local).length();
      } else if (!OutboxIds.isPending(widget.message.id)) {
        size = await (await ChatDocuments.cached(widget.message.id))?.length();
      }
      if (size != null && size > 0) {
        ChatFileSizes.remember(widget.message.id, size);
        if (mounted) setState(() => _bytes = size);
      }
    } catch (_) {
      // Unknown size is simply left off the line.
    }
  }

  String get _name {
    final t = widget.message.text.trim();
    return t.isEmpty || t == 'File' ? 'Document' : t;
  }

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final p = _Paint(c, widget.message.isMe);
    final width = ChatWidths.media(context);
    final metaLine = chatFileMetaLine(_name, bytes: _bytes);
    final serverId = OutboxIds.serverIdOf(widget.message.id);
    final cancel = widget.onCancel;

    final content = Padding(
      padding: ChatGeometry.filePadding,
      child: Row(
        children: [
          _FileThumb(name: _name, messageId: serverId ?? widget.message.id, sending: cancel != null),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, height: 19 / 13.5, fontWeight: FontWeight.w600, color: p.fg),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 17 / 12, color: p.muted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ChatMeta(time: widget.time, state: widget.state, color: p.muted, readColor: p.read, fontSize: 12),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: widget.onOpen != null,
      label: [
        'Document',
        _name,
        metaLine,
        widget.time,
        if (widget.state != null) _stateWords(widget.state!),
        if (widget.onOpen != null) 'Double tap to open',
      ].join('. '),
      child: ClipRRect(
        borderRadius: _radiusFor(widget.message, widget.position),
        child: Material(
          color: p.fill,
          child: InkWell(
            onTap: widget.onOpen,
            child: SizedBox(
              width: width,
              child: Stack(
                children: [
                  content,
                  if (cancel != null && serverId != null)
                    // A 44 px target centred on the 34×42 thumbnail, reaching
                    // into the bubble's padding.
                    PositionedDirectional(
                      start: ChatGeometry.filePadding.start -
                          (ChatGeometry.minTouch - ChatGeometry.fileThumbWidth) / 2,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Semantics(
                          button: true,
                          label: 'Stop sending this document',
                          excludeSemantics: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              cancel();
                            },
                            child: const SizedBox(width: ChatGeometry.minTouch, height: ChatGeometry.minTouch),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The document's first page, drawn: white paper, four lines of "text", and a
/// strip naming its type — red for PDF, as the brief specifies. Upload and
/// download progress are drawn ON it.
class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.name, required this.messageId, required this.sending});

  final String name;
  final String messageId;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final kind = chatFileKindOf(name);
    final badge = switch (kind) {
      ChatFileKind.pdf => c.fileBadgePdf,
      ChatFileKind.word => c.fileBadgeWord,
      ChatFileKind.other => c.fileBadgeOther,
    };
    Widget line(double top, double end) => PositionedDirectional(
          start: 6,
          end: end,
          top: top,
          child: Container(
            height: 2,
            decoration: BoxDecoration(color: c.filePageLines, borderRadius: AppRadius.pillAll),
          ),
        );
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.fileThumbRadius)),
      child: SizedBox(
        width: ChatGeometry.fileThumbWidth,
        height: ChatGeometry.fileThumbHeight,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: c.filePage)),
            line(6, 6),
            line(11, 9),
            line(16, 6),
            line(21, 12),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 13,
              child: ColoredBox(
                color: badge,
                child: Center(
                  child: Text(
                    chatFileTypeLabel(name),
                    maxLines: 1,
                    textScaler: TextScaler.noScaling, // a drawing, not reading text
                    style: TextStyle(
                      fontSize: 8,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: c.onFileBadge,
                    ),
                  ),
                ),
              ),
            ),
            // Sending: the upload's ring and a ✕. Opening: the download's ring.
            Positioned.fill(
              child: ValueListenableBuilder<double?>(
                valueListenable:
                    sending ? ChatUploads.progressOf(messageId) : ChatDocuments.progressOf(messageId),
                builder: (_, progress, __) {
                  if (!sending && progress == null) return const SizedBox.shrink();
                  return ColoredBox(
                    color: c.mediaScrim,
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              value: sending ? (progress ?? 0) : (progress! < 0 ? null : progress),
                              strokeWidth: 2.2,
                              color: c.onMedia,
                              backgroundColor: c.onMedia.withValues(alpha: 0.3),
                            ),
                          ),
                          if (sending) Icon(AppIcons.close, size: 12, color: c.onMedia),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Cards in a bubble (location request, live journey) ───────────────────────

/// A purpose-built card — the location request, a live journey — inside the
/// bubble shape, with the time at its foot.
class ChatCardBubble extends StatelessWidget {
  const ChatCardBubble({
    super.key,
    required this.message,
    required this.position,
    required this.time,
    required this.child,
    this.state,
  });

  final Message message;
  final RunPosition position;
  final String time;
  final ChatSendState? state;
  final Widget child;

  /// The width a card inside lays itself out to.
  static double innerWidth(BuildContext context) => ChatWidths.media(context) - 24;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final p = _Paint(c, message.isMe);
    return Container(
      constraints: BoxConstraints(maxWidth: ChatWidths.media(context)),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 10, 7),
      decoration: BoxDecoration(color: p.fill, borderRadius: _radiusFor(message, position)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Align(alignment: AlignmentDirectional.centerStart, widthFactor: 1, child: child),
          const SizedBox(height: 4),
          ChatMeta(time: time, state: state, color: p.muted, readColor: p.read),
        ],
      ),
    );
  }
}

// ── Offer ────────────────────────────────────────────────────────────────────

class ChatOfferCard extends StatelessWidget {
  const ChatOfferCard({super.key, required this.offer, required this.time, this.onTap});

  final ChatThreadOffer offer;
  final String time;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final p = _Paint(c, offer.mine);
    final (String chip, Color chipFill, Color chipText) = switch (offer.status) {
      ChatOfferStatus.accepted => (
          'Accepted by ${offer.acceptedBy ?? 'them'}',
          offer.mine ? c.quoteOnOutgoing : c.successTile,
          offer.mine ? c.onOutgoing : c.success,
        ),
      ChatOfferStatus.notSelected => (
          'Not selected',
          offer.mine ? c.quoteOnOutgoing : c.bg,
          offer.mine ? c.onOutgoing : c.textSecondary,
        ),
      ChatOfferStatus.pending => (
          'Waiting for a reply',
          offer.mine ? c.quoteOnOutgoing : c.bg,
          offer.mine ? c.onOutgoing : c.textSecondary,
        ),
    };
    final price = formatPriceDisplay(offer.price);
    return Semantics(
      button: onTap != null,
      label: '${offer.mine ? 'Your offer' : 'Offer'}: $price. $chip. '
          '${offer.message.isEmpty ? '' : '${offer.message}. '}$time',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: ChatWidths.offer(context),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          decoration: BoxDecoration(
            color: p.fill,
            borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.bubbleRadius)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    offer.mine ? 'YOUR OFFER' : 'OFFER',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.88, color: p.muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: ChatGeometry.mediaPillHeight),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: chipFill,
                          borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.mediaPillRadius)),
                        ),
                        child: ChatHug(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (offer.status == ChatOfferStatus.accepted) ...[
                                Icon(AppIcons.check, size: 12, color: chipText),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  chip,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: chipText),
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
              const SizedBox(height: 4),
              Text(
                price,
                style: TextStyle(
                  fontSize: 22,
                  height: 28 / 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: p.fg,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (offer.message.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(offer.message.trim(), style: TextStyle(fontSize: 14, height: 19 / 14, color: p.fg)),
              ],
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: ChatMeta(time: time, color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pills ────────────────────────────────────────────────────────────────────

/// The day, as a pill — no rules either side. The same pill is pinned to the
/// top of the thread while it scrolls.
class ChatDayPill extends StatelessWidget {
  const ChatDayPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      header: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: ChatGeometry.datePillHeight),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: c.dateChipFill,
          border: Border.all(color: c.border),
          borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.datePillRadius)),
        ),
        child: ChatHug(
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, color: c.dateChipText),
          ),
        ),
      ),
    );
  }
}

/// A job event — paid and held, arrived, completed, released, dispute
/// opened — centred in the thread with its time.
class ChatEventPill extends StatelessWidget {
  const ChatEventPill({super.key, required this.event, required this.time});

  final ChatEvent event;
  final String time;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final (IconData icon, Color tint) = switch (event.kind) {
      ChatEventKind.paidHeld => (AppIcons.escrow, c.success),
      ChatEventKind.arrived => (AppIcons.locationConfirmed, c.success),
      ChatEventKind.completionRequested => (AppIcons.completedWork, c.accentText),
      ChatEventKind.completed => (AppIcons.successFilled, c.success),
      ChatEventKind.released => (AppIcons.escrowReleased, c.success),
      ChatEventKind.disputeOpened => (AppIcons.dispute, c.danger),
    };
    return Semantics(
      label: '${event.label}, $time',
      excludeSemantics: true,
      child: Container(
        constraints: BoxConstraints(
          minHeight: ChatGeometry.eventPillHeight,
          maxWidth: MediaQuery.sizeOf(context).width - 2 * ChatGeometry.sidePadding,
        ),
        // 4.5 + 17 + 4.5, plus the 1 px border Container adds on each side: 28.
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4.5),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          border: Border.all(color: c.border),
          borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.eventPillRadius)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: event.label),
                  TextSpan(text: ' · $time', style: ChatMeta.styleFor(12.5, FontWeight.w400, c.textSecondary)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 17 / 12.5, color: c.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── A row of the thread ──────────────────────────────────────────────────────

/// One message as the thread places it: on the sender's side, 8 above a new
/// run and 2 within one, with its send state around it and long-press to act
/// on it — reporting the bubble's own rectangle, so the menu opens over it.
///
/// A widget rather than inline composition in the screen, so the tests mount
/// exactly what the thread ships. The inline version once captured its own
/// result in a closure and built itself until the stack overflowed — on a
/// phone, where it drew one grey box over the whole thread — and no test saw
/// it because none built the screen's rows.
class ChatMessageRow extends StatelessWidget {
  const ChatMessageRow({
    super.key,
    required this.mine,
    required this.position,
    required this.bubble,
    this.state,
    this.onLongPress,
    this.onRetry,
  });

  final bool mine;
  final RunPosition position;
  final Widget bubble;

  /// Outgoing messages only.
  final ChatSendState? state;

  /// Given the bubble's global rectangle.
  final void Function(Rect bubbleRect)? onLongPress;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final press = onLongPress;
    final Widget pressable = Builder(
      builder: (bubbleContext) => GestureDetector(
        onLongPress: press == null
            ? null
            : () {
                final box = bubbleContext.findRenderObject() as RenderBox?;
                press(box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : Rect.zero);
              },
        child: bubble,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(
        top: position.first ? ChatGeometry.betweenGroupsGap : ChatGeometry.inGroupGap,
      ),
      child: Align(
        alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: mine ? ChatSendFrame(state: state, onRetry: onRetry, child: pressable) : pressable,
      ),
    );
  }
}

// ── Sending states ───────────────────────────────────────────────────────────

/// How an outgoing bubble carries its state: queued at 85%, failed at 70%
/// with an alert beside it and "Not sent. Tap to retry" under it in danger —
/// and the whole failed message is the retry button.
class ChatSendFrame extends StatelessWidget {
  const ChatSendFrame({super.key, required this.state, required this.child, this.onRetry});

  final ChatSendState? state;
  final Widget child;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final s = state;
    if (s != ChatSendState.failed) {
      return AnimatedOpacity(
        duration: AppMotion.state,
        opacity: s == ChatSendState.queued ? 0.85 : 1,
        child: child,
      );
    }
    return Semantics(
      button: onRetry != null,
      label: 'Not sent. Double tap to retry.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRetry == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onRetry!();
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: Icon(AppIcons.messageNotSent, size: 18, color: c.danger)),
                const SizedBox(width: 8),
                Flexible(child: Opacity(opacity: 0.7, child: child)),
              ],
            ),
            const SizedBox(height: 5),
            ExcludeSemantics(
              child: Text(
                'Not sent. Tap to retry',
                style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
