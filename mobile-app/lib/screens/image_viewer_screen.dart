// ─────────────────────────────────────────────────────────────────────────────
// Fullscreen image viewer.
//
// Images in a chat are content, not decoration: a 220×180 thumbnail is enough
// to recognise a photo but not to read a meter, a receipt, a serial number or
// a house number — which is exactly what Help24 users send each other. This
// screen makes them inspectable.
//
// Gestures follow the platform conventions people already know, so nothing has
// to be taught: pinch to zoom, double-tap to toggle zoom at the point touched,
// drag to pan while zoomed, and drag down to dismiss when not.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, SystemUiOverlayStyle;

class ImageViewerScreen extends StatefulWidget {
  final String imageUrl;

  /// Shared tag with the thumbnail so the photo appears to lift out of the
  /// conversation rather than replacing it. Null disables the transition.
  final String? heroTag;

  /// Caption shown over the image, if the sender wrote one.
  final String? caption;

  const ImageViewerScreen({
    super.key,
    required this.imageUrl,
    this.heroTag,
    this.caption,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomAnimation;

  /// Vertical drag offset while swiping to dismiss.
  double _dragY = 0;
  bool _dragging = false;

  bool get _isZoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    _animation.addListener(() {
      final value = _zoomAnimation?.value;
      if (value != null) _transform.value = value;
    });
    // Rebuild on zoom changes so the dismiss gesture enables/disables and the
    // chrome can respond.
    _transform.addListener(_onTransform);
  }

  void _onTransform() => setState(() {});

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _transform.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 target) {
    _zoomAnimation = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    _animation.forward(from: 0);
  }

  /// Double-tap zooms toward the point touched rather than the image centre —
  /// tapping a detail should magnify THAT detail, which is the whole reason
  /// someone double-taps a photo of a serial number.
  void _handleDoubleTap(TapDownDetails details) {
    HapticFeedback.selectionClick();
    if (_isZoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    const scale = 2.5;
    final position = details.localPosition;
    _animateTo(
      Matrix4.identity()
        ..translate(-position.dx * (scale - 1), -position.dy * (scale - 1))
        ..scale(scale),
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // Only while un-zoomed: once zoomed, vertical drags are panning, and
    // stealing them would make the image feel stuck.
    if (_isZoomed) return;
    setState(() {
      _dragging = true;
      _dragY += details.delta.dy;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_isZoomed) return;
    final velocity = details.velocity.pixelsPerSecond.dy;
    // A deliberate flick, or dragged far enough to read as intent.
    if (_dragY.abs() > 120 || velocity > 700) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _dragging = false;
      _dragY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The backdrop fades as the image is dragged away, so dismissal feels like
    // a direct manipulation rather than a button press.
    final progress = (_dragY.abs() / 400).clamp(0.0, 1.0);
    final backdrop = (1 - progress).clamp(0.0, 1.0);

    Widget image = CachedNetworkImage(
      imageUrl: widget.imageUrl,
      fit: BoxFit.contain,
      // Progressive: the cached thumbnail from the conversation is usually
      // already on disk, so the full image resolves over a spinner instead of
      // a blank screen.
      placeholder: (_, __) => const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
        ),
      ),
      errorWidget: (_, __, ___) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 56, color: Colors.white54),
            SizedBox(height: 12),
            Text("Couldn't load this image",
                style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
    );

    if (widget.heroTag != null) {
      image = Hero(tag: widget.heroTag!, child: image);
    }

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: backdrop),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: GestureDetector(
        onDoubleTapDown: _handleDoubleTap,
        // onDoubleTap must exist for onDoubleTapDown to fire.
        onDoubleTap: () {},
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  // Shrinks slightly as it is thrown away — the standard cue
                  // that the content is leaving.
                  scale: _dragging ? (1 - progress * 0.15).clamp(0.85, 1.0) : 1.0,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: 5,
                    child: Center(child: image),
                  ),
                ),
              ),
            ),
            if ((widget.caption ?? '').trim().isNotEmpty && !_dragging)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    MediaQuery.of(context).padding.bottom + 20,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: Text(
                    widget.caption!,
                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
