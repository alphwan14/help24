import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/post_model.dart';
import '../theme/tokens.dart';

/// THE MOMENT A REQUEST GOES UP.
///
/// Someone asking for help wants to know two things: that it worked, and
/// what happens now. This card says both, and nothing else.
///
/// ── Where it sits ────────────────────────────────────────────────────────
/// A small card in the middle of the screen, over the composer's "Preview &
/// Post" page, which stays where it was under a light dim (owner's call,
/// 2026-11-25, after Reddit's launch: the app stays put and only a small mark
/// moves in the centre). No blur, no full-screen takeover, no buttons. The
/// page underneath does not change: the "Post Now" button keeps its words,
/// and taps on it are held off by the dim, not by greying it out.
///
/// ── When it runs ─────────────────────────────────────────────────────────
/// From the tap on "Post Now", and its pace is the work's pace, not a script:
///   1. the dim and the card arrive, the bars slide in from the card's edges
///      and the amber crossbar grows between them (1 s), then breathes while
///      the request is saved and its photos upload ("Uploading photo 1 of 2",
///      from the real upload);
///   2. the moment the server confirms, "Your request is live." The
///      crossbar gives one small settle and the phone a light tap. The only
///      floor is [minFinding] (1.2 s from the tap), so a fast network does
///      not flash the first state; nothing is added after the confirmation;
///   3. [liveFor] later it closes by itself, and the composer with it, back
///      to Discover, where the request now is. Back closes it sooner.
/// A failure never reaches this card's words: the composer takes the card
/// away, and the form is still there underneath, with the error and Retry
/// it always showed.
///
/// ── The mark ─────────────────────────────────────────────────────────────
/// Built from the logo, not from category art, so it reads the same for
/// Plumbing or a custom "TV Repair". The two bars are the customer and the
/// provider; the amber crossbar is escrow, the trust between them. Plain
/// boxes in the theme's ink and amber: no Lottie, no image asset, nothing a
/// Shorebird patch could not carry.
///
/// ── What it does NOT say ─────────────────────────────────────────────────
/// No counts of people, no "Sent to 12 providers nearby". Nothing is sent
/// anywhere when a request is posted, so such a number would be invented.
/// The only number on screen is the photo upload, which is real.
///
/// ── Nothing moves but the mark ───────────────────────────────────────────
/// The words sit in one fixed-height area sized for the tallest state, so
/// neither the mark nor the card's edges shift when "Finding…" becomes
/// "Your request is live.".
///
/// ── Reduce motion ────────────────────────────────────────────────────────
/// With animations off on the phone the card and mark are drawn still and
/// the words change without a fade. The pace stays: it follows the work, not
/// a movement.
class FindingHelpView extends StatefulWidget {
  const FindingHelpView({
    super.key,
    required this.line,
    required this.onClose,
    this.upload,
    this.posted,
    this.minFinding = const Duration(milliseconds: 1200),
    this.liveFor = const Duration(milliseconds: 2000),
  });

  /// "Finding plumbing help near Westlands, Nairobi…" ([findingHelpLine]).
  final String line;

  /// Photos uploaded so far, once the upload has started; null before it,
  /// and always null for a request without photos.
  final ({int done, int total})? upload;

  /// The request as the server returned it. Null until it confirms.
  final PostModel? posted;

  /// The card closing by itself once the request has been live for
  /// [liveFor].
  final VoidCallback onClose;

  /// The shortest time "Finding…" shows, so a fast confirmation does not
  /// flash it.
  final Duration minFinding;

  /// How long "Your request is live." shows before the card closes itself.
  final Duration liveFor;

  /// The card is never wider than this, however wide the phone.
  static const double maxCardWidth = 232;

  @override
  State<FindingHelpView> createState() => _FindingHelpViewState();
}

/// "Finding plumbing help near Westlands, Nairobi…", from the request itself.
///
/// The category is lower case, as it reads mid-sentence, except a short
/// all-capital word, which is an abbreviation ("TV repair", "AC repair",
/// "IT"). "Other" (or none) names nothing, so the line is "Finding help";
/// a name already ending in "help" is not doubled; no place reads "near you".
String findingHelpLine({required String category, required String location}) {
  final name = category.trim();
  final place = location.trim();
  final where = place.isEmpty ? 'you' : place;
  if (name.isEmpty || name.toLowerCase() == 'other') return 'Finding help near $where…';
  final words = name.split(RegExp(r'\s+')).map(_inSentence).join(' ');
  final what = words.toLowerCase().split(' ').last == 'help' ? words : '$words help';
  return 'Finding $what near $where…';
}

String _inSentence(String word) {
  final abbreviation = word.length >= 2 &&
      word.length <= 4 &&
      word == word.toUpperCase() &&
      RegExp('[A-Z]').hasMatch(word);
  return abbreviation ? word : word.toLowerCase();
}

/// The upload, in words: "Uploading photo 2 of 3" while it runs, then
/// "3 photos uploaded" while the request finishes saving. Null when there is
/// nothing to upload.
String? uploadProgressLine(({int done, int total})? upload) {
  if (upload == null || upload.total <= 0) return null;
  if (upload.done < upload.total) {
    return 'Uploading photo ${upload.done + 1} of ${upload.total}';
  }
  return upload.total == 1 ? 'Photo uploaded' : '${upload.total} photos uploaded';
}

const String kRequestLiveTitle = 'Your request is live.';
const String kRequestLiveBody = "We'll notify you when providers send offers.";

/// How much the page under the card is dimmed: enough to set the card on
/// top, little enough that the page still reads. Dark needs more, because a
/// dim over a near-black page has less room to show.
double findingHelpDimAlpha(Brightness brightness) => brightness == Brightness.dark ? 0.40 : 0.12;

class _FindingHelpViewState extends State<FindingHelpView>
    with TickerProviderStateMixin {
  /// The dim and the card arriving.
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: AppMotion.transition,
  );

  /// The bars arriving and the crossbar growing. Done before [minFinding]
  /// ends, so "live" never interrupts the mark mid-formation.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  /// One slow breath in or out of the crossbar's halo while the request goes
  /// up; repeats in reverse, eased both ways.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// The crossbar's one small settle when the server confirms.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  late final Animation<double> _cardScale = Tween<double>(begin: 0.96, end: 1).animate(
    CurvedAnimation(parent: _arrive, curve: AppMotion.enter),
  );

  Timer? _minimumTimer;
  Timer? _closeTimer;
  bool _minimumPassed = false;
  bool _live = false;
  bool _still = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_live && !_still) {
        _breath.repeat(reverse: true);
      }
    });
    _minimumTimer = Timer(widget.minFinding, () {
      _minimumPassed = true;
      _goLiveWhenReady();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (!_started) {
      _started = true;
      _still = still;
      if (still) {
        _arrive.value = 1;
        _intro.value = 1;
      } else {
        _arrive.forward();
        _intro.forward();
      }
      return;
    }
    if (still && !_still) {
      // Turned off mid-way: stop where it would have ended, at rest.
      _arrive.value = 1;
      _intro.value = 1;
      _breath.stop();
      _breath.value = 0;
      _settle.value = 1;
    }
    _still = still;
  }

  @override
  void didUpdateWidget(FindingHelpView old) {
    super.didUpdateWidget(old);
    if (old.posted == null && widget.posted != null) _goLiveWhenReady();
  }

  /// "Your request is live." the moment both are true: the server has
  /// confirmed, and "Finding…" has had its minimum time.
  void _goLiveWhenReady() {
    if (!mounted || _live || !_minimumPassed || widget.posted == null) return;
    setState(() => _live = true);
    HapticFeedback.lightImpact();
    if (_still) {
      _breath.value = 0;
    } else {
      // The halo breathes out to rest rather than vanishing mid-breath, and
      // the crossbar settles once.
      _breath.animateTo(0, duration: AppMotion.sheet, curve: AppMotion.enter);
      _settle.forward(from: 0);
    }
    _closeTimer = Timer(widget.liveFor, () {
      if (mounted) widget.onClose();
    });
  }

  @override
  void dispose() {
    _minimumTimer?.cancel();
    _closeTimer?.cancel();
    _arrive.dispose();
    _intro.dispose();
    _breath.dispose();
    _settle.dispose();
    super.dispose();
  }

  /// One state of the words: laid out always (that is what fixes the
  /// area's height), shown and heard only while it is current.
  Widget _state({required bool current, required Duration fade, required Widget child}) {
    return AnimatedOpacity(
      opacity: current ? 1 : 0,
      duration: fade,
      curve: current ? AppMotion.enter : AppMotion.exit,
      child: ExcludeSemantics(
        excluding: !current,
        child: Semantics(liveRegion: current, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final brightness = Theme.of(context).brightness;
    final fade = _still ? Duration.zero : AppMotion.transition;
    final progress = uploadProgressLine(widget.upload);

    final cardWidth = math.min(
      FindingHelpView.maxCardWidth,
      MediaQuery.sizeOf(context).width - 2 * AppSpace.xl,
    );

    final finding = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.line,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: AppTypeScale.headingS.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        // The upload line keeps its height with nothing to say, so the first
        // "Uploading photo 1 of 2" does not push anything.
        Visibility(
          visible: progress != null,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Text(
            progress ?? 'Uploading photo 1 of 1',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypeScale.bodyS.copyWith(
              fontFamily: AppTypeScale.family,
              color: c.contentSecondary,
            ),
          ),
        ),
      ],
    );

    final live = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          kRequestLiveTitle,
          textAlign: TextAlign.center,
          style: AppTypeScale.headingS.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          kRequestLiveBody,
          textAlign: TextAlign.center,
          style: AppTypeScale.bodyS.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentSecondary,
          ),
        ),
      ],
    );

    final card = Container(
      key: const ValueKey('finding-help-card'),
      width: cardWidth,
      // Clipped to its own corners: the bars slide in from beyond the card's
      // edges and are cut by them, never drawn over the dim.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.lgAll,
        boxShadow: AppElevation.floating(brightness),
      ),
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.xl, AppSpace.lg, AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: _FindingMark(
              intro: _intro,
              breath: _breath,
              settle: _settle,
              // From just past the card's edge to the bar's place in the mark.
              travel: (cardWidth - _FindingMark._w) / 2 + _FindingMark._barW,
              ink: c.contentPrimary,
              amber: c.accentFill,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          // Both states laid out on top of each other: the area is as tall
          // as the taller one in every frame.
          Stack(
            alignment: Alignment.topCenter,
            children: [
              _state(current: !_live, fade: fade, child: finding),
              _state(current: _live, fade: fade, child: live),
            ],
          ),
        ],
      ),
    );

    // The page under the card stays as it was, dimmed a little; nothing on
    // it can be tapped, and a screen reader hears only the card.
    return BlockSemantics(
      child: AbsorbPointer(
        child: FadeTransition(
          opacity: _arrive,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: findingHelpDimAlpha(brightness)),
            child: Center(
              child: ScaleTransition(scale: _cardScale, child: card),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Help24 mark in motion: `|` `▬` `|` on the 60 × 56 grid of
/// assets/brand/help24-mark.svg, scaled to sit in a small card.
///
/// One builder over three controllers, four plain boxes and a transform
/// each. No Opacity layer, no clipping, no shader, no layout work per frame:
/// cheap enough for the slowest phone Help24 supports.
class _FindingMark extends StatelessWidget {
  const _FindingMark({
    required this.intro,
    required this.breath,
    required this.settle,
    required this.travel,
    required this.ink,
    required this.amber,
  });

  final Animation<double> intro;
  final Animation<double> breath;
  final Animation<double> settle;

  /// How far each bar starts from its place: from just past the edge of the
  /// card, which clips it.
  final double travel;
  final Color ink;
  final Color amber;

  /// Scale of the 60 × 56 source grid.
  static const double _s = 1.1;
  static const double _w = 60 * _s;
  static const double _h = 56 * _s;
  static const double _barW = 11 * _s;
  static const double _pillW = 22 * _s;
  static const double _pillH = 12 * _s;
  static const double _pillLeft = 19 * _s;
  static const double _pillTop = 22 * _s;

  /// The halo around the crossbar, at the bottom and the top of a breath.
  /// The crossbar sits 8 units from each bar; the halo stops 4 short of
  /// them, so it never touches the bars.
  static const double _haloRest = 1.5 * _s;
  static const double _haloFull = 4 * _s;
  static const double _haloAlpha = 0.14;

  // The intro, as slices of its second: the bars arrive (sliding, at full
  // ink, never fading), and the crossbar grows between them as they land.
  static const _barsMove = Interval(0.0, 0.6, curve: Curves.easeOutCubic);
  static const _pillGrow = Interval(0.45, 1.0, curve: Curves.easeOutBack);
  static const _pillFade = Interval(0.45, 0.65, curve: Curves.easeOut);

  /// One small settle: a little smaller, then back to rest.
  static final Animatable<double> _settleScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.9).chain(CurveTween(curve: Curves.easeOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.9, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 65,
    ),
  ]);

  static Widget _box(double width, double height, Color color) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: color, borderRadius: AppRadius.pillAll),
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Help24',
      image: true,
      child: SizedBox(
        width: _w,
        height: _h,
        child: AnimatedBuilder(
          animation: Listenable.merge([intro, breath, settle]),
          builder: (context, _) {
            final t = intro.value;
            final slide = (1 - _barsMove.transform(t)) * travel;
            final b = Curves.easeInOut.transform(breath.value);
            final pillScale = (0.3 + 0.7 * _pillGrow.transform(t)) *
                (1 + 0.03 * b) *
                _settleScale.transform(settle.value);
            final pillColor = amber.withValues(alpha: _pillFade.transform(t).clamp(0.0, 1.0));
            final halo = _haloRest + (_haloFull - _haloRest) * b;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (b > 0)
                  Positioned(
                    left: _pillLeft - halo,
                    top: _pillTop - halo,
                    child: _box(
                      _pillW + 2 * halo,
                      _pillH + 2 * halo,
                      amber.withValues(alpha: _haloAlpha * b),
                    ),
                  ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: Transform.translate(
                    offset: Offset(-slide, 0),
                    child: _box(_barW, _h, ink),
                  ),
                ),
                Positioned(
                  left: _w - _barW,
                  top: 0,
                  child: Transform.translate(
                    offset: Offset(slide, 0),
                    child: _box(_barW, _h, ink),
                  ),
                ),
                Positioned(
                  left: _pillLeft,
                  top: _pillTop,
                  child: Transform.scale(
                    scale: pillScale,
                    child: _box(_pillW, _pillH, pillColor),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
