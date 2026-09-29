// ─────────────────────────────────────────────────────────────────────────────
// One image that can be inspected.
//
// Help24 photos are evidence, not decoration: a leaking joint, a meter, a
// receipt, the work a provider did last week. Every full-screen image in the
// app goes through this widget, so they all answer the same gestures — the
// ones people already know from their gallery app:
//
//   pinch        zoom, up to [maxScale]
//   double-tap   zoom in on the point touched; double-tap again to reset
//   drag         pan, while zoomed
//
// It used to be two implementations. The chat viewer had double-tap; the post
// gallery — where most photos are — had pinch only, so a double-tap on a
// request's photo did nothing at all.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.child,
    this.onZoomChanged,
    this.maxScale = 5,
    this.doubleTapScale = 2.5,
  });

  /// The image, already fitted to the viewport (typically `BoxFit.contain`
  /// inside a `Center`).
  final Widget child;

  /// Called when the image goes from fitted to zoomed and back — not on every
  /// frame. A parent that also reads drags (a gallery's page swipe, a viewer's
  /// drag-to-dismiss) must stand down while zoomed, or it steals the pan.
  final ValueChanged<bool>? onZoomChanged;

  final double maxScale;

  /// How far one double-tap zooms in.
  final double doubleTapScale;

  @override
  State<ZoomableImage> createState() => ZoomableImageState();
}

/// Public so a viewer can open already zoomed in — see [zoomIn].
class ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomAnimation;
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _animation.addListener(() {
      final value = _zoomAnimation?.value;
      if (value != null) _transform.value = value;
    });
    _transform.addListener(_reportZoom);
  }

  @override
  void dispose() {
    _transform.removeListener(_reportZoom);
    _transform.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _reportZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  void _animateTo(Matrix4 target) {
    _zoomAnimation = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    _animation.forward(from: 0);
  }

  /// Zoom in on [at] (viewport coordinates) exactly as a double-tap there
  /// would. Used to finish a double-tap that began on a small preview.
  void zoomIn(Offset at) {
    if (_zoomed) return;
    _animateTo(zoomAtPoint(at, widget.doubleTapScale.clamp(1.0, widget.maxScale)));
  }

  /// Zooms toward the point touched rather than the centre — double-tapping a
  /// detail should magnify THAT detail. Zoomed at all (by pinch or by an
  /// earlier double-tap), it resets instead.
  void _handleDoubleTap() {
    HapticFeedback.selectionClick();
    if (_zoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    zoomIn(_doubleTapAt);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: widget.maxScale,
        child: widget.child,
      ),
    );
  }
}

/// The transform that magnifies by [scale] while keeping [point] (in viewport
/// coordinates) where it is on screen: `p ↦ scale·p + (1 − scale)·point`.
///
/// Because the point stays inside the viewport, so does the translation — the
/// result never exposes anything beyond the image's own bounds.
@visibleForTesting
Matrix4 zoomAtPoint(Offset point, double scale) {
  return Matrix4.diagonal3Values(scale, scale, 1)
    ..setTranslationRaw(-point.dx * (scale - 1), -point.dy * (scale - 1), 0);
}

/// Where a point tapped on a COVER-fitted preview of an image lands when the
/// same image is shown whole and centred in a full-screen viewer.
///
/// A post's header crops its photo to fill the box; the viewer shows all of
/// it, letterboxed. The same detail is therefore at a different place on
/// screen in each, and zooming the viewer at the raw tap position would
/// magnify the wrong thing. This goes through the image's own pixels:
/// preview point → image pixel → viewer point.
///
/// The viewer side is [BoxFit.scaleDown] because that is what an image with
/// no size of its own does inside a `Center`: shrunk to fit, never enlarged.
Offset previewPointInViewer({
  required Offset tap,
  required Size preview,
  required Size viewer,
  required Size image,
}) {
  final whole = Offset.zero & image;
  // Cover: which part of the image the preview shows, stretched over the box.
  final shown = Alignment.center
      .inscribe(applyBoxFit(BoxFit.cover, image, preview).source, whole);
  final pixel = Offset(
    shown.left + tap.dx / preview.width * shown.width,
    shown.top + tap.dy / preview.height * shown.height,
  );
  // Where the whole image sits in the viewer.
  final placed = Alignment.center.inscribe(
      applyBoxFit(BoxFit.scaleDown, image, viewer).destination, Offset.zero & viewer);
  return Offset(
    placed.left + pixel.dx / image.width * placed.width,
    placed.top + pixel.dy / image.height * placed.height,
  );
}
