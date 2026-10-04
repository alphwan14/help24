import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/theme/app_theme.dart';

/// Shared plumbing for rendering chat surfaces in a widget test — for the
/// redesign's screenshots and for the checks that need real glyph metrics
/// (geometry parity, large system text).
///
/// The test environment draws every glyph as a box unless the real fonts are
/// loaded, so [loadAppFonts] reads the app's own FontManifest (Inter, the
/// Material icons and Iconsax) and registers each family.

/// Where screenshots go. Empty means "do not write any" — the checks still run.
const String kShotsDir = String.fromEnvironment('CHAT_SHOTS_DIR');

/// The canvas phone: 390 logical px wide, 1:1 with the design.
const double kPhoneWidth = 390;

Future<void> loadAppFonts() async {
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest) {
    final family = (entry as Map)['family'] as String;
    final loader = FontLoader(family);
    for (final font in entry['fonts'] as List) {
      loader.addFont(rootBundle.load((font as Map)['asset'] as String));
    }
    await loader.load();
  }
}

ThemeData themeFor(Brightness b) =>
    b == Brightness.dark ? AppTheme.darkTheme : AppTheme.lightTheme;

/// A photo-like fixture: a warm landscape gradient with a few shapes, so a
/// crop and a scrim read as they would on a real picture.
Future<Uint8List> fixturePhotoPng({int width = 800, int height = 600}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        const [Color(0xFF6FA8DC), Color(0xFFF6D7A7), Color(0xFF6B8E4E)],
        const [0, 0.55, 1],
      ),
  );
  final hill = Path()
    ..moveTo(0, height * 0.72)
    ..quadraticBezierTo(width * 0.35, height * 0.52, width * 0.7, height * 0.7)
    ..quadraticBezierTo(width * 0.85, height * 0.78, width.toDouble(), height * 0.66)
    ..lineTo(width.toDouble(), height.toDouble())
    ..lineTo(0, height.toDouble())
    ..close();
  canvas.drawPath(hill, Paint()..color = const Color(0xFF3F6B35));
  canvas.drawCircle(
      Offset(width * 0.78, height * 0.22), height * 0.09, Paint()..color = const Color(0xFFFFF4D6));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Serves one fixture image for every chat photo, through the same
/// `CachedNetworkImage` path the app uses — no network, no seam in the app.
class FixtureImageCache implements BaseCacheManager {
  FixtureImageCache._(this._file);

  /// The file lives in the cache manager's own in-memory file system, so the
  /// harness needs no direct dependency on `package:file`.
  static Future<FixtureImageCache> create(Uint8List bytes) async {
    final file = await MemoryCacheSystem().createFile('fixture.png');
    await file.writeAsBytes(bytes);
    return FixtureImageCache._(file);
  }

  final dynamic _file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      Stream.value(FileInfo(_file, FileSource.Cache,
          DateTime.now().add(const Duration(days: 1)), url));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A drawn street map with a pin. Light streets on a pale ground, or the night
/// treatment, so the screenshots show which style each theme asks for.
class FixtureMap extends StatelessWidget {
  const FixtureMap({super.key, required this.night});

  final bool night;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _MapPainter(night), size: Size.infinite);
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.night);
  final bool night;

  @override
  void paint(Canvas canvas, Size size) {
    final ground = night ? const Color(0xFF1D2C3A) : const Color(0xFFEDEBE6);
    final block = night ? const Color(0xFF243646) : const Color(0xFFE1DED6);
    final park = night ? const Color(0xFF1E3A2E) : const Color(0xFFCDE8C9);
    final road = night ? const Color(0xFF3A4E63) : const Color(0xFFFFFFFF);
    final major = night ? const Color(0xFF5B6F86) : const Color(0xFFF6D9A0);
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    final rnd = math.Random(7);
    for (var i = 0; i < 14; i++) {
      final r = Rect.fromLTWH(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height,
          30 + rnd.nextDouble() * 60, 20 + rnd.nextDouble() * 40);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = block);
    }
    canvas.drawRect(Rect.fromLTWH(size.width * 0.05, size.height * 0.55, size.width * 0.3, size.height * 0.35),
        Paint()..color = park);
    final roadPaint = Paint()
      ..color = road
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, size.height * 0.4), Offset(size.width, size.height * 0.3), roadPaint);
    canvas.drawLine(Offset(size.width * 0.3, 0), Offset(size.width * 0.45, size.height), roadPaint);
    canvas.drawLine(Offset(size.width * 0.7, 0), Offset(size.width * 0.62, size.height), roadPaint);
    canvas.drawLine(Offset(0, size.height * 0.78), Offset(size.width, size.height * 0.85),
        roadPaint..color = major..strokeWidth = 8);
    final pin = Offset(size.width / 2, size.height / 2);
    final head = Paint()..color = const Color(0xFFE5483E);
    final path = Path()
      ..moveTo(pin.dx, pin.dy + 4)
      ..lineTo(pin.dx - 8, pin.dy - 10)
      ..arcToPoint(Offset(pin.dx + 8, pin.dy - 10), radius: const Radius.circular(9.5))
      ..close();
    canvas.drawPath(path, head);
    canvas.drawCircle(Offset(pin.dx, pin.dy - 13), 9.5, head);
    canvas.drawCircle(Offset(pin.dx, pin.dy - 13), 3.5, Paint()..color = const Color(0xFF8A1A14));
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => old.night != night;
}

/// One screenshot frame: a phone-width column on the theme's chat ground.
class ShotFrame extends StatelessWidget {
  const ShotFrame({
    super.key,
    required this.brightness,
    required this.child,
    this.textScale = 1,
    this.width = kPhoneWidth,
    this.background,
  });

  final Brightness brightness;
  final Widget child;
  final double textScale;
  final double width;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFor(brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 2000),
          devicePixelRatio: 2,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Builder(
          builder: (context) => Material(
            color: background ?? Theme.of(context).scaffoldBackgroundColor,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: RepaintBoundary(
                  key: const ValueKey('shot'),
                  child: ColoredBox(
                    color: background ?? Theme.of(context).scaffoldBackgroundColor,
                    // Content height, not the screen's: each shot is cropped
                    // to what it shows.
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [child],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pumps [frame], lets images decode for real, and returns the tester for
/// further inspection. Image IO only completes inside `runAsync`.
Future<void> pumpShot(WidgetTester tester, Widget frame) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 2, 4000);
  tester.view.devicePixelRatio = 2;
  await tester.pumpWidget(frame);
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Writes the frame's PNG to `$kShotsDir/<path>.png` when screenshots are on.
Future<void> saveShot(WidgetTester tester, String path) async {
  if (kShotsDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = io.File('$kShotsDir/$path.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}
