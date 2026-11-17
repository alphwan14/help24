import 'dart:async';

import 'package:flutter/material.dart';

import '../models/post_model.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import 'post_detail_screen.dart';

/// THE MOMENT AFTER A REQUEST GOES UP.
///
/// Someone who has just asked for help wants to know two things: that it
/// worked, and what happens now. This screen says both, and nothing else.
///
/// ── The mark ───────────────────────────────────────────────────────────────
/// Built from the logo, not from category art, so it reads the same for
/// Plumbing, Tutoring or a custom "TV Repair". The two bars are the customer
/// and the provider; they slide in from the sides, and the amber crossbar
/// (escrow, the trust between them) settles between them and breathes while
/// the request is being shown around. Drawn with plain boxes in the theme's own
/// ink and amber: no Lottie, no image asset, nothing a Shorebird patch could
/// not carry.
///
/// ── What it does NOT say ─────────────────────────────────────────────────
/// No counts, no "Sent to 12 providers nearby", no faces popping in. Nothing
/// is sent anywhere when a request is posted: the app writes the row and the
/// feed shows it to the people who open Discover. A number here would be
/// invented, and an invented number is the one thing a trust product cannot
/// show. What IS real is said: the request is live, and the poster is told
/// when a provider sends an offer (the `provider_applied` notification).
///
/// ── Reduce motion ────────────────────────────────────────────────────────
/// With animations turned off on the phone, the mark is drawn still, in its
/// final position, and the words change without a fade. The timing stays,
/// because it is a pause, not a movement.
class FindingHelpScreen extends StatefulWidget {
  const FindingHelpScreen({
    super.key,
    required this.post,
    this.searchFor = const Duration(milliseconds: 2600),
  });

  /// The request just published.
  final PostModel post;

  /// How long "Finding…" shows before the calm state.
  final Duration searchFor;

  @override
  State<FindingHelpScreen> createState() => _FindingHelpScreenState();
}

/// "Finding Plumbing near Westlands, Nairobi…", from the post itself.
///
/// A category of "Other" (or none) names nothing, so the line falls back to
/// "help"; a post with no place says "near you". Public for the tests.
String findingHelpLine(PostModel post) {
  final category = post.category.name.trim();
  final what = (category.isEmpty || category.toLowerCase() == 'other') ? 'help' : category;
  final place = post.location.trim();
  return 'Finding $what near ${place.isEmpty ? 'you' : place}…';
}

const String kRequestLiveTitle = 'Your request is live.';
const String kRequestLiveBody = "We'll notify you when providers send offers.";

class _FindingHelpScreenState extends State<FindingHelpScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  Timer? _settleTimer;
  bool _settled = false;
  bool _still = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_settled && !_still) {
        _pulse.repeat(reverse: true);
      }
    });
    _settleTimer = Timer(widget.searchFor, _settle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (!_started) {
      _started = true;
      _still = still;
      if (still) {
        _intro.value = 1;
      } else {
        _intro.forward();
      }
      return;
    }
    if (still && !_still) {
      // Turned off mid-way: stop where it would have ended, at rest.
      _intro.value = 1;
      _pulse.stop();
      _pulse.value = 0;
    }
    _still = still;
  }

  void _settle() {
    if (!mounted || _settled) return;
    setState(() => _settled = true);
    if (_still) {
      _pulse.value = 0;
    } else {
      // The breathing eases out to rest rather than freezing mid-breath.
      _pulse.animateTo(0, duration: AppMotion.sheet, curve: AppMotion.enter);
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _viewPost() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => PostDetailScreen(post: widget.post)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fade = _still ? Duration.zero : AppMotion.transition;

    return Scaffold(
      backgroundColor: c.page,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                  icon: Icon(AppIcons.close, color: c.contentSecondary),
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RepaintBoundary(
                        child: _FindingMark(
                          intro: _intro,
                          pulse: _pulse,
                          ink: c.contentPrimary,
                          amber: c.accentFill,
                        ),
                      ),
                      const SizedBox(height: AppSpace.xxl),
                      Semantics(
                        liveRegion: true,
                        child: AnimatedSwitcher(
                          duration: fade,
                          switchInCurve: AppMotion.enter,
                          switchOutCurve: AppMotion.exit,
                          child: _settled
                              ? Column(
                                  key: const ValueKey('settled'),
                                  children: [
                                    Text(
                                      kRequestLiveTitle,
                                      textAlign: TextAlign.center,
                                      style: AppTypeScale.headingM.copyWith(
                                        fontFamily: AppTypeScale.family,
                                        color: c.contentPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: AppSpace.sm),
                                    Text(
                                      kRequestLiveBody,
                                      textAlign: TextAlign.center,
                                      style: AppTypeScale.bodyL.copyWith(
                                        fontFamily: AppTypeScale.family,
                                        color: c.contentSecondary,
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  findingHelpLine(widget.post),
                                  key: const ValueKey('finding'),
                                  textAlign: TextAlign.center,
                                  style: AppTypeScale.headingS.copyWith(
                                    fontFamily: AppTypeScale.family,
                                    color: c.contentPrimary,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Held in place while hidden, so nothing above it moves when it
              // arrives.
              AnimatedOpacity(
                opacity: _settled ? 1 : 0,
                duration: fade,
                child: IgnorePointer(
                  ignoring: !_settled,
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _viewPost,
                      child: const Text('View your post'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Help24 mark in motion: `|` `▬` `|` on the 60 × 56 grid of
/// assets/brand/help24-mark.svg, scaled.
///
/// One builder over both controllers, four plain boxes and a transform each.
/// Fades are written into each box's colour rather than an Opacity widget, so
/// no frame needs an offscreen layer; no clipping, no shader, no layout work
/// per frame. Cheap enough for the slowest phone Help24 supports.
class _FindingMark extends StatelessWidget {
  const _FindingMark({
    required this.intro,
    required this.pulse,
    required this.ink,
    required this.amber,
  });

  final Animation<double> intro;
  final Animation<double> pulse;
  final Color ink;
  final Color amber;

  /// Scale of the 60 × 56 source grid.
  static const double _s = 1.6;
  static const double _w = 60 * _s;
  static const double _h = 56 * _s;
  static const double _barW = 11 * _s;
  static const double _pillW = 22 * _s;
  static const double _pillH = 12 * _s;
  static const double _pillLeft = 19 * _s;
  static const double _pillTop = 22 * _s;

  /// How far each bar travels in from its side.
  static const double _travel = 28 * _s;

  // The choreography, as slices of the 900 ms intro: the bars arrive first,
  // the crossbar settles between them as they land (a slight overshoot is
  // the "settle").
  static const _barsMove = Interval(0.0, 0.55, curve: Curves.easeOutCubic);
  static const _barsFade = Interval(0.0, 0.35, curve: Curves.easeOut);
  static const _pillGrow = Interval(0.45, 1.0, curve: Curves.easeOutBack);
  static const _pillFade = Interval(0.45, 0.7, curve: Curves.easeOut);

  static Widget _box(double width, double height, Color color) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: color, borderRadius: AppRadius.pillAll),
      );

  static double _alpha(double v) => v.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Help24',
      image: true,
      child: SizedBox(
        width: _w,
        height: _h,
        child: AnimatedBuilder(
          animation: Listenable.merge([intro, pulse]),
          builder: (context, _) {
            final t = intro.value;
            final slide = (1 - _barsMove.transform(t)) * _travel;
            final barColor = ink.withValues(alpha: _alpha(_barsFade.transform(t)));
            final pillScale = 0.3 + 0.7 * _pillGrow.transform(t);
            final pillColor = amber.withValues(alpha: _alpha(_pillFade.transform(t)));
            final b = Curves.easeInOut.transform(pulse.value);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // The soft ring the crossbar breathes into. Same amber, thinned.
                if (b > 0)
                  Positioned(
                    left: _pillLeft,
                    top: _pillTop,
                    child: Transform.scale(
                      scale: 1 + 0.9 * b,
                      child: _box(_pillW, _pillH, amber.withValues(alpha: 0.28 * b)),
                    ),
                  ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: Transform.translate(
                    offset: Offset(-slide, 0),
                    child: _box(_barW, _h, barColor),
                  ),
                ),
                Positioned(
                  left: _w - _barW,
                  top: 0,
                  child: Transform.translate(
                    offset: Offset(slide, 0),
                    child: _box(_barW, _h, barColor),
                  ),
                ),
                Positioned(
                  left: _pillLeft,
                  top: _pillTop,
                  child: Transform.scale(
                    scale: pillScale * (1 + 0.08 * b),
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
