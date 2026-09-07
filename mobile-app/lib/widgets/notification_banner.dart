import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/app_notification.dart';
import '../theme/app_theme.dart';

// ── Tuning ───────────────────────────────────────────────────────────────────
// One place for every number the interaction depends on, so "the swipe feels
// wrong" is a one-line change rather than a hunt through the build method.

const double _kInset = 12; // card inset from the screen edges
const double _kRadius = 22;

const Duration _kEnter = Duration(milliseconds: 340);
const Duration _kLeave = Duration(milliseconds: 220);
const Duration _kSettle = Duration(milliseconds: 280);
const Duration _kFling = Duration(milliseconds: 190);

/// How far across its own width the card must travel before releasing counts
/// as "dismiss" rather than "put it back".
const double _kDismissFraction = 0.28;

/// The same idea vertically. Upward only — see [_NotificationBannerState._onVerticalUpdate].
const double _kUpDismissFraction = 0.42;

/// A flick this fast dismisses even if the card barely moved.
const double _kFlingVelocity = 620; // logical px/s

/// …but it must have moved at least this far, so a stray fast tap-and-lift
/// cannot throw a message away before it has been read.
const double _kIntentSlop = 8;

/// How much of a downward drag the card actually gives. Down is not a
/// dismissal direction, so it resists rather than follows.
const double _kDownResistance = 0.22;

/// Help24's in-app notification banner.
///
/// ONE BANNER, ONE OWNER
/// ---------------------
/// [NotificationBannerOverlay.show] is called from the foreground FCM handler
/// in main.dart and from nowhere else. It REPLACES whatever is on screen
/// rather than stacking or queueing: two messages arriving a second apart are
/// about to be read in the same place, so the newer one supersedes the older.
///
/// Everything upstream of this file is untouched by it — the FCM payload, the
/// suppression rules for the active and muted chats, the deep-link router, and
/// the background isolate that renders the OS notification. This file owns
/// presentation and gesture, and nothing else.
class NotificationBannerOverlay {
  NotificationBannerOverlay._();

  static _BannerHandle? _current;

  /// Whether a banner is mounted right now.
  @visibleForTesting
  static bool get isVisible => _current != null;

  /// [overlay] is the OverlayState to insert into. Callers holding a
  /// `GlobalKey<NavigatorState>` MUST pass `key.currentState?.overlay`: the
  /// navigator's context is the context OF the Navigator widget, and that
  /// navigator's Overlay is its DESCENDANT, so an ancestor lookup from there
  /// finds nothing. `Overlay.of` on such a context threw
  /// "Null check operator used on a null value" on every foreground push —
  /// and because the OS card is deliberately suppressed in the foreground,
  /// the user saw nothing at all.
  ///
  /// [type] is the wire `type` from the push payload. It is presentation only:
  /// it selects the eyebrow label, the icon and the tone from the notification
  /// registry that already exists for the notifications screen. Routing still
  /// happens entirely in the caller's [onTap].
  static void show({
    required BuildContext context,
    required String title,
    required String body,
    String type = '',
    /// The sender's photo, when the app already holds it. Resolved by the
    /// caller from data it has in memory — the banner never fetches it.
    String avatarUrl = '',
    OverlayState? overlay,
    VoidCallback? onTap,
    Duration displayDuration = const Duration(seconds: 4),
  }) {
    // maybeOf, never of: a missing overlay must degrade to "no banner", not
    // to an unhandled exception on the notification path.
    final resolved = overlay ?? Overlay.maybeOf(context, rootOverlay: true);
    if (resolved == null) {
      debugPrint('[BANNER] no overlay available — in-app banner skipped');
      return;
    }

    // Replace, never stack. Doing it here rather than waiting for the outgoing
    // banner's own exit animation is what keeps two cards from overlapping;
    // the handle is what makes it safe — see [_BannerHandle].
    _current?.removeNow();

    final handle = _BannerHandle(displayDuration);
    handle.entry = OverlayEntry(
      builder: (_) => _NotificationBanner(
        title: title,
        body: body,
        kind: NotificationKind.of(type),
        avatarUrl: avatarUrl,
        handle: handle,
        onTap: onTap,
      ),
    );
    _current = handle;
    resolved.insert(handle.entry!);
    handle.startTimer();
  }

  /// Animate away whatever is showing, if anything.
  static void dismiss() => _current?.requestExit();

  /// Tear the current banner down without animating. Test-only: a banner
  /// left mounted between tests carries its auto-dismiss Timer with it.
  @visibleForTesting
  static void debugReset() => _current?.removeNow();
}

/// The lifetime of ONE banner: its overlay entry and its auto-dismiss timer.
///
/// WHY A HANDLE AND NOT TWO STATICS
/// --------------------------------
/// Dismissal used to be a static method closing over a static `_entry`. An
/// exit animation runs for a fifth of a second, and a second message arriving
/// inside that window replaced `_entry` before the first animation finished —
/// so the first banner's completion callback removed the SECOND banner. A
/// message could vanish 200ms after appearing and nothing in the code read as
/// wrong.
///
/// A handle belongs to exactly one banner and [removeNow] is idempotent, so a
/// late callback can only ever remove its own entry, and only once.
class _BannerHandle {
  _BannerHandle(this.displayDuration);

  final Duration displayDuration;

  OverlayEntry? entry;
  Timer? _timer;

  /// Set by the mounted [_NotificationBanner] so the auto-dismiss timer can
  /// ask for an ANIMATED exit instead of yanking the entry out from under the
  /// user. Null before the first build and again after dispose; [requestExit]
  /// falls back to an immediate removal in both cases, so a timer can never be
  /// left holding a banner nobody can close.
  VoidCallback? beginExit;

  bool _gone = false;

  void startTimer() {
    _timer?.cancel();
    if (_gone) return;
    _timer = Timer(displayDuration, requestExit);
  }

  /// Stops the countdown while the user is touching the card. Deciding whether
  /// to open a message should not be a race against a timer.
  void pauseTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void requestExit() {
    if (_gone) return;
    final begin = beginExit;
    if (begin == null) {
      removeNow();
    } else {
      begin();
    }
  }

  void removeNow() {
    if (_gone) return;
    _gone = true;
    _timer?.cancel();
    _timer = null;
    beginExit = null;
    entry?.remove();
    entry = null;
    if (identical(NotificationBannerOverlay._current, this)) {
      NotificationBannerOverlay._current = null;
    }
  }
}

class _NotificationBanner extends StatefulWidget {
  const _NotificationBanner({
    required this.title,
    required this.body,
    required this.kind,
    required this.handle,
    this.avatarUrl = '',
    this.onTap,
  });

  final String title;
  final String body;
  final NotificationKind kind;
  final String avatarUrl;
  final _BannerHandle handle;
  final VoidCallback? onTap;

  @override
  State<_NotificationBanner> createState() => _NotificationBannerState();
}

class _NotificationBannerState extends State<_NotificationBanner>
    with TickerProviderStateMixin {
  /// Entrance, and the exit for every path that is not a swipe.
  late final AnimationController _enter;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  /// Settle-back and fling-out. Separate from [_enter] so a swipe that starts
  /// mid-entrance does not have to fight the entrance animation for the same
  /// controller.
  late final AnimationController _drag;
  Offset _dragFrom = Offset.zero;
  Offset _dragTo = Offset.zero;
  Curve _dragCurve = Curves.easeOutCubic;

  /// The live drag translation.
  ///
  /// A ValueNotifier rather than setState: a pointer move then rebuilds only
  /// the Transform/Opacity wrapper, while the card itself is built once and
  /// handed through as a `child`. Dragging a banner should not rebuild an
  /// SVG, three Texts and an avatar sixty times a second.
  final ValueNotifier<Offset> _offset = ValueNotifier<Offset>(Offset.zero);

  /// The raw accumulated drag, before the downward rubber band is applied.
  /// Kept separately so the resistance is a function of how far the finger has
  /// travelled and not of how many move events happened to arrive — scaling the
  /// running total on every update compounds, so the same gesture resisted
  /// differently at 60Hz and at 120Hz.
  Offset _raw = Offset.zero;

  /// One-way latch. The tap, the ✕, a swipe and the auto-dismiss timer can all
  /// reach the exit; exactly one of them gets to act on it. This is also what
  /// makes a double tap open one chat rather than two.
  bool _closing = false;

  final GlobalKey _cardKey = GlobalKey();

  Size get _cardSize {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.size : Size.zero;
  }

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: _kEnter,
      reverseDuration: _kLeave,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.25),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _enter,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));
    _fade = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0, 0.65, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    _drag = AnimationController(vsync: this, duration: _kSettle)
      ..addListener(() {
        _offset.value =
            Offset.lerp(_dragFrom, _dragTo, _dragCurve.transform(_drag.value))!;
      });
    _enter.forward();
    widget.handle.beginExit = _exitUpward;
  }

  @override
  void dispose() {
    // Hand the timer back its fallback before the controllers go. After this
    // the handle removes the entry directly instead of asking a dead State to
    // animate.
    widget.handle.beginExit = null;
    _enter.dispose();
    _drag.dispose();
    _offset.dispose();
    super.dispose();
  }

  // ── Exit paths ─────────────────────────────────────────────────────────────

  /// The banner leaves the way it arrived, back up under the status bar.
  /// Used by the ✕, by the auto-dismiss timer, and after a tap.
  Future<void> _exitUpward() async {
    if (_closing) return;
    _closing = true;
    widget.handle.pauseTimer();
    await _enter.reverse();
    // If the entry was already removed the reverse is cancelled and this line
    // is never reached — which is correct, there is nothing left to remove.
    if (!mounted) return;
    widget.handle.removeNow();
  }

  void _flingOut(Offset target) {
    if (_closing) return;
    _closing = true;
    widget.handle.pauseTimer();
    _animateOffsetTo(target, _kFling, Curves.easeOutCubic).then((_) {
      if (!mounted) return;
      widget.handle.removeNow();
    });
  }

  TickerFuture _animateOffsetTo(Offset target, Duration d, Curve curve) {
    _raw = target;
    _dragFrom = _offset.value;
    _dragTo = target;
    _dragCurve = curve;
    _drag.duration = d;
    return _drag.forward(from: 0);
  }

  void _handleTap() {
    if (_closing) return;
    widget.handle.pauseTimer();
    // Route FIRST. The old order animated for 300ms and only THEN called
    // onTap — and the auto-dismiss timer, still running, could remove the
    // entry inside that window. Removing it disposed the controller, which
    // cancelled the very animation whose completion was carrying the
    // navigation, and the tap was lost in silence. Routing now happens on the
    // frame of the tap; the card fades out over the route it just opened.
    widget.onTap?.call();
    _exitUpward();
  }

  // ── Gesture ────────────────────────────────────────────────────────────────

  /// Up is followed 1:1; down is rubber-banded, because down is not a
  /// dismissal and a card that slides freely off its anchor reads as a bug.
  void _setRaw(Offset raw) {
    _raw = raw;
    _offset.value =
        Offset(raw.dx, raw.dy <= 0 ? raw.dy : raw.dy * _kDownResistance);
  }

  void _onDragDown() {
    widget.handle.pauseTimer();
    if (_drag.isAnimating) _drag.stop();
    // Resume from wherever the card actually is, so grabbing it mid-spring-back
    // does not make it jump.
    final shown = _offset.value;
    _raw = Offset(
      shown.dx,
      shown.dy <= 0 ? shown.dy : shown.dy / _kDownResistance,
    );
  }

  /// A drag that never became a drag — the tap recogniser won the arena, or
  /// the pointer was cancelled. Either way nobody is holding the card any
  /// more, so the countdown may run again. (On a tap this fires just before
  /// onTap, which pauses it again immediately.)
  void _onDragCancel() {
    if (_closing) return;
    widget.handle.startTimer();
  }

  void _onHorizontalUpdate(DragUpdateDetails d) {
    if (_closing) return;
    _setRaw(Offset(_raw.dx + d.delta.dx, _raw.dy));
  }

  void _onHorizontalEnd(DragEndDetails d) {
    if (_closing) return;
    final width =
        _cardSize.width == 0 ? MediaQuery.sizeOf(context).width : _cardSize.width;
    final dx = _offset.value.dx;
    final vx = d.velocity.pixelsPerSecond.dx;
    final travelled = dx.abs() >= width * _kDismissFraction;
    final flung = vx.abs() >= _kFlingVelocity && dx.abs() > _kIntentSlop;
    if (travelled || flung) {
      final direction = dx != 0 ? dx.sign : (vx.sign == 0 ? 1.0 : vx.sign);
      _flingOut(Offset(direction * (width + _kInset * 2), _offset.value.dy));
    } else {
      _settleBack();
    }
  }

  void _onVerticalUpdate(DragUpdateDetails d) {
    if (_closing) return;
    _setRaw(Offset(_raw.dx, _raw.dy + d.delta.dy));
  }

  void _onVerticalEnd(DragEndDetails d) {
    if (_closing) return;
    final height = _cardSize.height == 0 ? 96.0 : _cardSize.height;
    final dy = _offset.value.dy;
    final vy = d.velocity.pixelsPerSecond.dy;
    if (dy <= -height * _kUpDismissFraction ||
        (vy <= -_kFlingVelocity && dy < -_kIntentSlop)) {
      _flingOut(Offset(
        _offset.value.dx,
        -(height + MediaQuery.paddingOf(context).top + 40),
      ));
    } else {
      _settleBack();
    }
  }

  /// Not enough travel to mean it. Spring back, and give the countdown a fresh
  /// full duration — the user touched the card, so the four seconds it had
  /// already spent on screen no longer describe how long they have looked at it.
  void _settleBack() {
    _animateOffsetTo(Offset.zero, _kSettle, Curves.easeOutBack);
    widget.handle.startTimer();
  }

  double _opacityFor(Offset off, Size card) {
    final w = card.width == 0 ? 1.0 : card.width;
    final h = card.height == 0 ? 1.0 : card.height;
    final horizontal = (off.dx.abs() / w).clamp(0.0, 1.0);
    final vertical = off.dy < 0 ? (-off.dy / h).clamp(0.0, 1.0) : 0.0;
    final progress = horizontal > vertical ? horizontal : vertical;
    return 1.0 - 0.85 * progress;
  }

  // ── Paint ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPadding = MediaQuery.paddingOf(context).top;

    return Positioned(
      top: topPadding + 8,
      left: _kInset,
      right: _kInset,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: ValueListenableBuilder<Offset>(
            valueListenable: _offset,
            builder: (context, off, child) => Transform.translate(
              offset: off,
              child: Opacity(opacity: _opacityFor(off, _cardSize), child: child),
            ),
            // Built once. The drag rebuilds the wrapper above, never this.
            child: GestureDetector(
              // Opaque so a drag that starts on the banner belongs to the
              // banner. Without it the pointer falls through to the route
              // underneath and the feed scrolls while the user is trying to
              // push the notification away.
              behavior: HitTestBehavior.opaque,
              onTap: _handleTap,
              onHorizontalDragDown: (_) => _onDragDown(),
              onHorizontalDragUpdate: _onHorizontalUpdate,
              onHorizontalDragEnd: _onHorizontalEnd,
              onHorizontalDragCancel: _onDragCancel,
              onVerticalDragDown: (_) => _onDragDown(),
              onVerticalDragUpdate: _onVerticalUpdate,
              onVerticalDragEnd: _onVerticalEnd,
              onVerticalDragCancel: _onDragCancel,
              child: _card(context, isDark),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, bool isDark) {
    final tone = widget.kind.tone.color(isDark);
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary =
        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final isMessage = widget.kind.category == NotificationCategory.messages;

    return Semantics(
      button: true,
      container: true,
      liveRegion: true,
      // An OverlayEntry is mounted outside the Scaffold, so nothing in this
      // subtree inherits a DefaultTextStyle. Without a Material ancestor every
      // Text falls back to DefaultTextStyle.fallback() — monospace, with the
      // yellow debug underline — which is exactly how it rendered on device.
      // Transparency, not a surface: the card paints its own colour, border
      // and two-layer shadow in the BoxDecoration below.
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: _cardKey,
          decoration: BoxDecoration(
            // Opaque, deliberately. The old card sat at 0.97 alpha and the
            // screen behind it — a page title, a search field — read straight
            // through the message. In dark mode the same card was #1C1C1E on a
            // #0A0A0A background under a black shadow, which is to say invisible.
            color: isDark ? const Color(0xFF232327) : Colors.white,
            borderRadius: BorderRadius.circular(_kRadius),
            border: Border.all(
              color: isDark ? const Color(0xFF35353B) : const Color(0x14111827),
            ),
            // Two shadows, not one: a tight contact shadow so the card has an
            // edge, and a wide soft one so it reads as floating above the page.
            boxShadow: isDark
                ? const [
                    BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 28,
                        offset: Offset(0, 12)),
                    BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 6,
                        offset: Offset(0, 2)),
                  ]
                : const [
                    BoxShadow(
                        color: Color(0x1F111827),
                        blurRadius: 28,
                        offset: Offset(0, 12)),
                    BoxShadow(
                        color: Color(0x0F111827),
                        blurRadius: 5,
                        offset: Offset(0, 2)),
                  ],
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _leading(isMessage, tone),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _eyebrow(isDark, textTertiary),
                    const SizedBox(height: 3),
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.body,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.32,
                          color: textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              _closeButton(isDark, textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  /// The Help24 mark plus the notification's own category, in the app's
  /// vocabulary. Both come from data that already exists: the mark is the same
  /// asset the sign-in screen renders, and the label is the category from the
  /// notification registry the notifications screen already sorts by — so a new
  /// backend type gets a correct banner without a second table to update.
  Widget _eyebrow(bool isDark, Color textTertiary) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset(
          isDark
              ? 'assets/brand/help24-mark-on-dark.svg'
              : 'assets/brand/help24-mark.svg',
          width: 12,
        ),
        const SizedBox(width: 6),
        Text(
          widget.kind.category.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            height: 1,
            color: textTertiary,
          ),
        ),
      ],
    );
  }

  /// The sender, as a person: their photo when the app already has it, their
  /// initials when it does not.
  ///
  /// The URL is handed in by the caller, read out of the conversation list
  /// that is already in memory. The banner issues NO query of its own — the
  /// push payload carries no avatar, and putting a round trip on the
  /// notification path to decorate a card that lives four seconds would be a
  /// bad trade. A chat this device has never opened simply shows initials.
  Widget _leading(bool isMessage, Color tone) {
    if (isMessage) {
      final fallback = _initialsAvatar();
      if (widget.avatarUrl.isEmpty) return fallback;
      return SizedBox(
        width: 44,
        height: 44,
        child: ClipOval(
          // Never a visible load, exactly as the Messages list does it: a
          // cached photo paints on the same frame, and one that is uncached or
          // broken stays on the initials. A spinner inside a four-second card
          // would be worse than no photo at all.
          child: CachedNetworkImage(
            imageUrl: widget.avatarUrl,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholderFadeInDuration: Duration.zero,
            placeholder: (_, __) => fallback,
            errorWidget: (_, __, ___) => fallback,
          ),
        ),
      );
    }
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(widget.kind.icon, color: tone, size: 20),
    );
  }

  Widget _initialsAvatar() => Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: AppTheme.primaryAccent,
          shape: BoxShape.circle,
        ),
        child: Text(
          initialsOf(widget.title),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      );

  Widget _closeButton(bool isDark, Color textTertiary) {
    return Semantics(
      button: true,
      label: 'Dismiss notification',
      child: GestureDetector(
        // A 44pt target around an 15pt glyph. The old ✕ was a bare 18pt Icon
        // with no padding at all, so the tappable area was the glyph itself.
        behavior: HitTestBehavior.opaque,
        onTap: _exitUpward,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.07)
                    : const Color(0x0D111827),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.close_rounded, size: 15, color: textTertiary),
            ),
          ),
        ),
      ),
    );
  }
}

/// First letter of the first and last word, upper-cased. Runes rather than
/// `substring`, so a name that starts outside the BMP does not get sliced in
/// half.
@visibleForTesting
String initialsOf(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return '?';
  String first(String word) => String.fromCharCode(word.runes.first);
  final letters =
      parts.length == 1 ? first(parts.first) : first(parts.first) + first(parts.last);
  return letters.toUpperCase();
}
