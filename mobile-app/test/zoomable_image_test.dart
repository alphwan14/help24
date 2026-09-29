import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/widgets/zoomable_image.dart';

/// EVERY PHOTO IN HELP24 ZOOMS THE SAME WAY.
///
/// A double-tap on a request's or offer's photo did nothing: the post gallery
/// had pinch only, and the post header opened the gallery on the first tap of
/// a double-tap and lost the second. The chat viewer had its own double-tap.
/// Both now go through [ZoomableImage]; these tests hold the gestures, the
/// geometry, and the wiring.
void main() {
  group('zoomAtPoint keeps the touched detail under the finger', () {
    for (final point in const [Offset(0, 0), Offset(120, 300), Offset(400, 800)]) {
      test('$point stays put at 2.5×', () {
        final m = zoomAtPoint(point, 2.5);
        final after = MatrixUtils.transformPoint(m, point);
        expect(after.dx, closeTo(point.dx, 1e-9));
        expect(after.dy, closeTo(point.dy, 1e-9));
        expect(m.getMaxScaleOnAxis(), closeTo(2.5, 1e-9));
      });
    }

    test('it never exposes anything beyond the image', () {
      // Viewport 400×800: every corner of the zoomed content stays outside or
      // on the viewport edge, so no empty band appears.
      const viewport = Size(400, 800);
      for (final point in const [Offset(0, 0), Offset(400, 800), Offset(200, 400)]) {
        final m = zoomAtPoint(point, 2.5);
        final topLeft = MatrixUtils.transformPoint(m, Offset.zero);
        final bottomRight =
            MatrixUtils.transformPoint(m, Offset(viewport.width, viewport.height));
        expect(topLeft.dx <= 1e-9 && topLeft.dy <= 1e-9, isTrue, reason: '$point');
        expect(bottomRight.dx >= viewport.width - 1e-9, isTrue, reason: '$point');
        expect(bottomRight.dy >= viewport.height - 1e-9, isTrue, reason: '$point');
      }
    });
  });

  group('a double-tap on the post header zooms the SAME detail in the viewer', () {
    // A square photo in a 400×200 header (cover: the middle band is shown) and
    // a 400×800 viewer (the whole photo, 400×400, centred at y = 200).
    const header = Size(400, 200);
    const viewer = Size(400, 800);
    const square = Size(1000, 1000);

    test('the centre maps to the centre', () {
      final p = previewPointInViewer(
          tap: const Offset(200, 100), preview: header, viewer: viewer, image: square);
      expect(p, const Offset(200, 400));
    });

    test('the header crop is accounted for, not the raw tap position', () {
      // The header's top-left shows the photo's pixel (0, 250) — a quarter of
      // the way down. In the viewer that is y = 200 + 0.25·400 = 300, not 0.
      final p = previewPointInViewer(
          tap: Offset.zero, preview: header, viewer: viewer, image: square);
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(300, 1e-9));
    });

    test('a photo smaller than the screen is not enlarged by the viewer', () {
      // 200×100 is shown at its own size in the viewer, centred at (100, 350);
      // the header shows all of it (cover at 2×). Its bottom-right corner is
      // the viewer's (300, 450).
      final p = previewPointInViewer(
          tap: const Offset(400, 200),
          preview: header,
          viewer: viewer,
          image: const Size(200, 100));
      expect(p.dx, closeTo(300, 1e-9));
      expect(p.dy, closeTo(450, 1e-9));
    });
  });

  group('the gestures', () {
    Future<List<bool>> pumpViewer(WidgetTester tester, {Key? key}) async {
      final changes = <bool>[];
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 800,
            child: ZoomableImage(
              key: key,
              onZoomChanged: changes.add,
              child: const ColoredBox(color: Colors.orange),
            ),
          ),
        ),
      ));
      return changes;
    }

    Future<void> doubleTap(WidgetTester tester, Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    testWidgets('double-tap zooms in, double-tap again resets', (tester) async {
      final changes = await pumpViewer(tester);
      final centre = tester.getCenter(find.byType(ZoomableImage));
      await doubleTap(tester, centre);
      expect(changes, [true]);
      await doubleTap(tester, centre);
      expect(changes, [true, false]);
    });

    testWidgets('a single tap does not zoom', (tester) async {
      final changes = await pumpViewer(tester);
      await tester.tapAt(tester.getCenter(find.byType(ZoomableImage)));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });

    testWidgets('in a gallery, a sideways pinch zooms instead of turning the page',
        (tester) async {
      // The post gallery's exact arrangement: photos in a PageView that stands
      // down while one is zoomed. A pinch whose fingers spread horizontally is
      // the gesture the pager could steal (adb cannot inject a pinch on the
      // test phone — SELinux denies the touchscreen — so it is proven here).
      final pager = PageController();
      var zoomed = false;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => PageView(
            controller: pager,
            physics: zoomed ? const NeverScrollableScrollPhysics() : null,
            children: [
              for (final color in const [Colors.orange, Colors.teal])
                ZoomableImage(
                  onZoomChanged: (z) => setState(() => zoomed = z),
                  child: ColoredBox(color: color),
                ),
            ],
          ),
        ),
      ));
      final centre = tester.getCenter(find.byType(PageView));
      final left = await tester.startGesture(centre - const Offset(40, 0), pointer: 1);
      final right = await tester.startGesture(centre + const Offset(40, 0), pointer: 2);
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(-12, 0));
        await right.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(zoomed, isTrue, reason: 'the pinch must reach the photo');
      expect(pager.page, 0, reason: 'and must not turn the page');

      // Zoomed, a one-finger sideways drag pans the photo — the page stays.
      await tester.dragFrom(centre, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(pager.page, 0);
    });

    testWidgets('zoomIn opens already zoomed, as a header double-tap needs', (tester) async {
      final key = GlobalKey<ZoomableImageState>();
      final changes = await pumpViewer(tester, key: key);
      key.currentState!.zoomIn(const Offset(100, 100));
      await tester.pumpAndSettle();
      expect(changes, [true]);
    });
  });

  group('the wiring', () {
    final gallery = File('lib/screens/post_detail_screen.dart').readAsStringSync();
    final chat = File('lib/screens/image_viewer_screen.dart').readAsStringSync();

    test('the post gallery and the chat viewer both use ZoomableImage', () {
      expect(gallery.contains('ZoomableImage('), isTrue);
      expect(chat.contains('ZoomableImage('), isTrue);
      expect(gallery.contains('InteractiveViewer('), isFalse,
          reason: 'a bare InteractiveViewer is pinch-only — the reported bug');
      expect(chat.contains('InteractiveViewer('), isFalse);
    });

    test('the gallery stops paging while a photo is zoomed', () {
      expect(gallery.contains('physics: _zoomed ? const NeverScrollableScrollPhysics() : null'),
          isTrue, reason: 'otherwise a sideways pan turns the page');
    });

    test('a double-tap on the post header opens the photo zoomed', () {
      expect(gallery.contains('onDoubleTap: () =>'), isTrue);
      expect(gallery.contains('previewPointInViewer('), isTrue);
    });

    test('the chat viewer drops drag-to-dismiss while zoomed', () {
      expect(chat.contains('onVerticalDragUpdate: _isZoomed ? null : _onDragUpdate'), isTrue,
          reason: 'an attached vertical-drag recogniser steals the vertical pan');
    });

    test('dispute evidence photos open in the viewer', () {
      final dispute = File('lib/screens/dispute_thread_screen.dart').readAsStringSync();
      expect(dispute.contains('ImageViewerScreen('), isTrue);
    });
  });
}
