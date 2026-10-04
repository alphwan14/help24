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
// drag to pan while zoomed (all [ZoomableImage]), and drag down to dismiss
// when not.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../theme/app_icons.dart';
import '../theme/system_bars.dart';
import '../widgets/zoomable_image.dart';

class ImageViewerScreen extends StatefulWidget {
  final String imageUrl;

  /// Shared tag with the thumbnail so the photo appears to lift out of the
  /// conversation rather than replacing it. Null disables the transition.
  final String? heroTag;

  /// Caption shown over the image, if the sender wrote one.
  final String? caption;

  /// Where the image is cached, and under what key. A private chat photo
  /// passes its own cache (whose downloads carry the user's token) and the
  /// message-keyed entry its thumbnail already filled; null is the app's
  /// default cache, keyed by URL.
  final String? cacheKey;
  final BaseCacheManager? cacheManager;

  const ImageViewerScreen({
    super.key,
    required this.imageUrl,
    this.heroTag,
    this.caption,
    this.cacheKey,
    this.cacheManager,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  /// Vertical drag offset while swiping to dismiss.
  double _dragY = 0;
  bool _dragging = false;

  /// Reported by [ZoomableImage]. While zoomed the dismiss handlers are not
  /// even attached: a vertical-drag recogniser wins the arena before the
  /// viewer's pan does, so merely ignoring its updates left the image unable
  /// to pan up or down.
  bool _isZoomed = false;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dragY += details.delta.dy;
    });
  }

  void _onDragEnd(DragEndDetails details) {
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
      cacheKey: widget.cacheKey,
      cacheManager: widget.cacheManager,
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
            Icon(AppIcons.imageBroken, size: 56, color: Colors.white54),
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
        systemOverlayStyle: SystemBars.immersive,
      ),
      body: GestureDetector(
        onVerticalDragUpdate: _isZoomed ? null : _onDragUpdate,
        onVerticalDragEnd: _isZoomed ? null : _onDragEnd,
        child: Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  // Shrinks slightly as it is thrown away — the standard cue
                  // that the content is leaving.
                  scale: _dragging ? (1 - progress * 0.15).clamp(0.85, 1.0) : 1.0,
                  child: ZoomableImage(
                    onZoomChanged: (zoomed) => setState(() => _isZoomed = zoomed),
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
