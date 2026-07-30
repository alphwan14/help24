import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The Flutter half of the launch screen.
///
/// Deliberately a PIXEL CONTINUATION of the Android launch theme rather than a
/// screen of its own: same `#0A0A0A` field, same 116dp badge, same centre. The
/// native splash paints until the first Flutter frame and this paints from that
/// frame onward, so the handoff between them is not an event the user can see —
/// there is no flash, no resize and no second brand moment.
///
/// It exists so the launch has somewhere to happen. Before it, the first Flutter
/// frame WAS Discover: skeletons, then the disk cache, then a chronological
/// page, then the ranked one, each landing in front of the user and each
/// re-keying the feed list. See [LaunchSequence] for the rule this enforces —
/// the feed settles behind this screen, and the user meets the finished article.
///
/// There is no spinner and no progress text on purpose. A launch that resolves
/// in a few hundred milliseconds does not need narrating, and one that takes
/// the full deadline is better spent looking calm than looking busy.
class LaunchSplash extends StatelessWidget {
  const LaunchSplash({super.key});

  /// Matches `android/app/src/main/res/values/colors.xml` → `splash_background`
  /// and the `windowSplashScreenBackground` used by the Android 12+ theme. If
  /// one changes, both change.
  static const Color background = Color(0xFF0A0A0A);

  /// The badge's logical size, taken from the mdpi drawable (116×116 px at
  /// 1×). The bundled asset is the xxxhdpi copy, so it renders at native
  /// resolution on every screen density.
  static const double _badgeSize = 116;

  /// Named so `main()` can decode it before the first frame.
  ///
  /// This matters more than it looks. An [AssetImage] resolves ASYNCHRONOUSLY,
  /// so without a warm cache the first Flutter frame paints the brand field
  /// with NOTHING on it and the badge appears a frame or two later — arriving
  /// immediately after the native splash has faded its own icon out. Two logos
  /// disappearing and reappearing in the space of a few frames is exactly what
  /// "the splash screen blinks" describes.
  static const String asset = 'assets/splash_badge.png';

  @override
  Widget build(BuildContext context) {
    // The bars must stay as the Android launch theme left them — light icons on
    // the brand field. Without this the app-wide overlay style, which is
    // resolved from the user's THEME, would flip a light-mode user's status bar
    // icons to dark the instant Flutter takes over — invisible on #0A0A0A, and
    // visibly flashing back a second later. An AnnotatedRegion is applied at
    // paint time, so it wins over the imperative call made during build.
    return const AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: background,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: ColoredBox(
        color: background,
        child: Center(
          child: Image(
            image: AssetImage(asset),
            width: _badgeSize,
            height: _badgeSize,
            filterQuality: FilterQuality.medium,
            // Warmed in main(), so this resolves synchronously from the cache
            // and the badge is in the very first frame. gaplessPlayback keeps
            // it painted across the rebuilds the app does while the splash is
            // up, rather than blanking back to the empty field.
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  /// Decode the badge into the image cache. Awaited by `main()` while the
  /// native splash is still on screen, so it costs nothing visible — and
  /// bounded, so a decode problem can never delay the launch.
  static Future<void> warm() {
    final completer = Completer<void>();
    final stream =
        const AssetImage(asset).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void done() {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    }

    listener = ImageStreamListener(
      (_, __) => done(),
      onError: (_, __) => done(),
    );
    stream.addListener(listener);
    return completer.future
        .timeout(const Duration(milliseconds: 500), onTimeout: () {});
  }
}
