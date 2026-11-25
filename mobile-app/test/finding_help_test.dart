import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/theme/tokens.dart';
import 'package:help24/widgets/finding_help_view.dart';

/// The moment a request goes up.
///
/// It starts on the tap on Post, follows the real work (the photo upload,
/// then the server's confirmation), never shows "live" before 1.2 s or a
/// moment after the confirmation, and goes away by itself. It is a small
/// card over the page, which stays on screen under a light dim. What it must
/// NEVER show is a count of people: nothing is sent anywhere when a request
/// is posted. The only number allowed is the photo upload, which is real.
PostModel _request() => PostModel(
      id: 'p1',
      title: 'Kitchen sink leaking',
      description: '',
      category: Category.fromName('Plumbing'),
      location: 'Westlands, Nairobi',
      price: 0,
      urgency: Urgency.flexible,
      type: PostType.request,
    );

const _line = 'Finding plumbing help near Westlands, Nairobi…';

/// Stands in for the composer: holds what the work has reported so far.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.onClose, required this.onPageTap});
  final VoidCallback onClose;
  final VoidCallback onPageTap;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  ({int done, int total})? upload;
  PostModel? posted;

  void report({({int done, int total})? upload, PostModel? posted}) => setState(() {
        if (upload != null) this.upload = upload;
        if (posted != null) this.posted = posted;
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(
          children: [
            // The page the card sits over, as the composer's preview does.
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ElevatedButton(onPressed: widget.onPageTap, child: const Text('Post Now')),
              ),
            ),
            Positioned.fill(
              child: FindingHelpView(
                line: _line,
                upload: upload,
                posted: posted,
                onClose: widget.onClose,
              ),
            ),
          ],
        ),
      );
}

class _Harness {
  final key = GlobalKey<_HostState>();
  int closes = 0;
  int pageTaps = 0;
  final haptics = <String>[];

  _HostState get host => key.currentState!;

  Future<void> pump(WidgetTester tester, {bool reduceMotion = false, ThemeData? theme}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: _Host(key: key, onClose: () => closes++, onPageTap: () => pageTaps++),
      ),
    );
  }
}

/// Tear the tree down so no timer outlives the test.
Future<void> _finish(WidgetTester tester) => tester.pumpWidget(const SizedBox());

/// Whether [text] is on show. Both states of the words are always laid out
/// (that fixes the height), and the upload line keeps its space while empty,
/// so "in the tree" is not "on screen".
bool _shown(WidgetTester tester, String text) {
  final f = find.text(text);
  final hidden = tester
      .widgetList<Visibility>(find.ancestor(of: f, matching: find.byType(Visibility)))
      .any((v) => !v.visible);
  if (hidden) return false;
  return tester
      .widgetList<AnimatedOpacity>(find.ancestor(of: f, matching: find.byType(AnimatedOpacity)))
      .every((o) => o.opacity == 1);
}

Finder get _mark => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_FindingMark');

/// Every box the mark draws, with its colour and where it is on screen.
List<({Color color, Rect rect})> _boxes(WidgetTester tester) => [
      for (final e in find.descendant(of: _mark, matching: find.byType(Container)).evaluate())
        (
          color: ((e.widget as Container).decoration! as BoxDecoration).color!,
          rect: tester.getRect(find.byWidget(e.widget)),
        ),
    ];

/// Every Text on screen that is showing, joined, for the "no counts" check.
String _shownText(WidgetTester tester) => [
      for (final e in find.byType(Text).evaluate())
        if ((e.widget as Text).data case final String data)
          if (_shown(tester, data)) data,
    ].join(' | ');

void main() {
  group('the words', () {
    test('category lower case, with "help", from the post', () {
      expect(findingHelpLine(category: 'Plumbing', location: 'Westlands, Nairobi'), _line);
      expect(findingHelpLine(category: 'House Cleaning', location: 'Kilimani'),
          'Finding house cleaning help near Kilimani…');
    });

    test('abbreviations keep their capitals', () {
      expect(findingHelpLine(category: 'TV Repair', location: 'Muhoroni'),
          'Finding TV repair help near Muhoroni…');
      expect(findingHelpLine(category: 'AC Repair', location: 'Mombasa'),
          'Finding AC repair help near Mombasa…');
      expect(findingHelpLine(category: 'IT', location: 'Thika'), 'Finding IT help near Thika…');
    });

    test('"Other" names nothing, "help" is not doubled, no place reads "you"', () {
      expect(findingHelpLine(category: 'Other', location: ''), 'Finding help near you…');
      expect(findingHelpLine(category: '', location: 'Juja'), 'Finding help near Juja…');
      expect(findingHelpLine(category: 'Homework Help', location: 'Juja'),
          'Finding homework help near Juja…');
    });

    test('the upload, as it really goes', () {
      expect(uploadProgressLine(null), isNull);
      expect(uploadProgressLine((done: 0, total: 0)), isNull);
      expect(uploadProgressLine((done: 0, total: 1)), 'Uploading photo 1 of 1');
      expect(uploadProgressLine((done: 0, total: 2)), 'Uploading photo 1 of 2');
      expect(uploadProgressLine((done: 1, total: 2)), 'Uploading photo 2 of 2');
      expect(uploadProgressLine((done: 2, total: 2)), '2 photos uploaded');
      expect(uploadProgressLine((done: 1, total: 1)), 'Photo uploaded');
    });
  });

  testWidgets('starts at once, and waits for the server however long it takes', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    // The first frame after the tap: the mark is already moving.
    expect(_shown(tester, _line), isTrue);
    expect(_shown(tester, kRequestLiveTitle), isFalse);
    expect(tester.hasRunningAnimations, isTrue);

    // A slow network: still finding, still breathing, nothing invented.
    await tester.pump(const Duration(seconds: 5));
    expect(_shown(tester, _line), isTrue);
    expect(_shown(tester, kRequestLiveTitle), isFalse);
    expect(tester.hasRunningAnimations, isTrue);
    expect(h.haptics, isEmpty);

    // The server confirms: live in the very next frame, nothing added.
    h.host.report(posted: _request());
    await tester.pump();
    expect(_shown(tester, kRequestLiveTitle), isTrue);
    expect(_shown(tester, kRequestLiveBody), isTrue);
    expect(_shown(tester, _line), isFalse);
    expect(h.haptics, ['HapticFeedbackType.lightImpact']);
    await _finish(tester);
  });

  testWidgets('a fast confirmation still shows "Finding…" for 1.2 s', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 300));
    h.host.report(posted: _request());
    await tester.pump();
    expect(_shown(tester, kRequestLiveTitle), isFalse);
    await tester.pump(const Duration(milliseconds: 850)); // 1150 ms in
    expect(_shown(tester, kRequestLiveTitle), isFalse);
    expect(h.haptics, isEmpty);
    await tester.pump(const Duration(milliseconds: 60)); // 1210 ms in
    expect(_shown(tester, kRequestLiveTitle), isTrue);
    expect(h.haptics, hasLength(1));
    await _finish(tester);
  });

  testWidgets('settles once, comes to rest, then closes by itself after 2 s', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    h.host.report(posted: _request());
    await tester.pump();

    // The settle runs, then everything is still.
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isFalse);
    // At rest the crossbar is its full size again.
    final pill = find.descendant(of: _mark, matching: find.byType(Transform)).evaluate().last.widget as Transform;
    expect(pill.transform.getMaxScaleOnAxis(), moreOrLessEquals(1.0, epsilon: 1e-6));

    await tester.pump(const Duration(milliseconds: 1400)); // 1.9 s after live
    expect(h.closes, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.closes, 1);
    await _finish(tester);
  });

  testWidgets('shows the real upload, and nothing moves when the words change', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 1100)); // the mark has formed
    final markAt = tester.getRect(_mark);

    h.host.report(upload: (done: 0, total: 2));
    await tester.pump();
    expect(find.text('Uploading photo 1 of 2'), findsOneWidget);
    expect(tester.getRect(_mark), markAt);

    h.host.report(upload: (done: 1, total: 2));
    await tester.pump();
    expect(find.text('Uploading photo 2 of 2'), findsOneWidget);

    h.host.report(upload: (done: 2, total: 2), posted: _request());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(_shown(tester, kRequestLiveTitle), isTrue);
    expect(tester.getRect(_mark), markAt);
    await _finish(tester);
  });

  testWidgets('the bars slide in at full ink; they never fade', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final ink = AppColors.of(tester.element(_mark)).contentPrimary;
    final bars = _boxes(tester).where((b) => b.color == ink).toList();
    expect(bars, hasLength(2));
    final markRect = tester.getRect(_mark);
    // Still on their way in, from outside the mark, at full colour.
    expect(bars.first.rect.left, lessThan(markRect.left - 20));
    expect(bars.last.rect.right, greaterThan(markRect.right + 20));
    await _finish(tester);
  });

  testWidgets('the halo breathes softly and never touches the bars', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 1000));
    final c = AppColors.of(tester.element(_mark));
    var sawHalo = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final boxes = _boxes(tester);
      final bars = boxes.where((b) => b.color == c.contentPrimary).map((b) => b.rect).toList()
        ..sort((a, b) => a.left.compareTo(b.left));
      final halos = boxes.where((b) => b.color.a < 0.5 && b.color.withValues(alpha: 1) == c.accentFill.withValues(alpha: 1));
      for (final halo in halos) {
        sawHalo = true;
        expect(halo.color.a, lessThanOrEqualTo(0.14 + 1e-6), reason: 'softer than before');
        expect(halo.rect.left - bars.first.right, greaterThanOrEqualTo(4), reason: 'clear of the left bar');
        expect(bars.last.left - halo.rect.right, greaterThanOrEqualTo(4), reason: 'clear of the right bar');
      }
    }
    expect(sawHalo, isTrue);
    await _finish(tester);
  });

  testWidgets('without photos, no number ever shows', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    for (var i = 0; i < 12; i++) {
      if (i == 4) h.host.report(posted: _request());
      await tester.pump(const Duration(milliseconds: 400));
      final text = _shownText(tester);
      expect(RegExp(r'\d').hasMatch(text), isFalse, reason: 'a number appeared: $text');
      expect(text.toLowerCase().contains('sent to'), isFalse);
    }
    await _finish(tester);
  });

  testWidgets('a small card in the centre; the page stays, dimmed, and cannot be tapped', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 300));

    final screen = tester.getRect(find.byType(Scaffold));
    final card = tester.getRect(find.byKey(const ValueKey('finding-help-card')));
    expect(card.width, lessThanOrEqualTo(FindingHelpView.maxCardWidth));
    expect(card.height, lessThan(screen.height / 2), reason: 'a card, not a takeover');
    expect(card.center.dx, moreOrLessEquals(screen.center.dx, epsilon: 0.5));
    expect(card.center.dy, moreOrLessEquals(screen.center.dy, epsilon: 0.5));
    // The mark and the words are inside it.
    expect(card.contains(tester.getRect(_mark).center), isTrue);
    expect(card.contains(tester.getCenter(find.text(_line))), isTrue);

    // The page under it is still there, under a light dim, not a blur.
    expect(find.text('Post Now'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final dim = tester.widgetList<ColoredBox>(find.descendant(
      of: find.byType(FindingHelpView),
      matching: find.byType(ColoredBox),
    )).first;
    expect(dim.color.a, moreOrLessEquals(findingHelpDimAlpha(Brightness.light), epsilon: 1e-6));
    expect(dim.color.a, lessThanOrEqualTo(0.15), reason: 'the page must still read');

    // A tap on the page goes nowhere, before and after it is live.
    await tester.tap(find.text('Post Now'), warnIfMissed: false);
    expect(h.pageTaps, 0);
    h.host.report(posted: _request());
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.text('Post Now'), warnIfMissed: false);
    expect(h.pageTaps, 0);

    // No buttons on the card: it closes by itself.
    expect(find.descendant(of: find.byType(FindingHelpView), matching: find.byType(ButtonStyleButton)),
        findsNothing);
    expect(find.text('View your post'), findsNothing);
    await _finish(tester);
  });

  testWidgets('the dim is stronger in dark, where a light one would not show', (tester) async {
    expect(findingHelpDimAlpha(Brightness.dark), greaterThan(findingHelpDimAlpha(Brightness.light)));
    final h = _Harness();
    await h.pump(tester, theme: AppTheme.darkTheme);
    await tester.pump(const Duration(milliseconds: 300));
    final dim = tester.widgetList<ColoredBox>(find.descendant(
      of: find.byType(FindingHelpView),
      matching: find.byType(ColoredBox),
    )).first;
    expect(dim.color.a, moreOrLessEquals(findingHelpDimAlpha(Brightness.dark), epsilon: 1e-6));
    await _finish(tester);
  });

  testWidgets('the bars slide in from the card edges and are cut by them', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 1));
    final card = tester.getRect(find.byKey(const ValueKey('finding-help-card')));
    final ink = AppColors.of(tester.element(_mark)).contentPrimary;
    final bars = _boxes(tester).where((b) => b.color == ink).map((b) => b.rect).toList()
      ..sort((a, b) => a.left.compareTo(b.left));
    // At the very start each bar is just past the card's edge.
    expect(bars.first.right, lessThanOrEqualTo(card.left + 1));
    expect(bars.last.left, greaterThanOrEqualTo(card.right - 1));
    final container = tester.widget<Container>(find.byKey(const ValueKey('finding-help-card')));
    expect(container.clipBehavior, isNot(Clip.none));
    await _finish(tester);
  });

  testWidgets('reduce motion: nothing moves, the pace still follows the work', (tester) async {
    final h = _Harness();
    await h.pump(tester, reduceMotion: true);
    expect(tester.hasRunningAnimations, isFalse);
    expect(_shown(tester, _line), isTrue);

    await tester.pump(const Duration(milliseconds: 500));
    h.host.report(posted: _request());
    await tester.pump(const Duration(milliseconds: 600));
    expect(_shown(tester, kRequestLiveTitle), isFalse); // the 1.2 s floor stays
    await tester.pump(const Duration(milliseconds: 150));
    expect(_shown(tester, kRequestLiveTitle), isTrue);
    expect(tester.hasRunningAnimations, isFalse);
    expect(h.haptics, hasLength(1));

    await tester.pump(const Duration(milliseconds: 2100));
    expect(h.closes, 1);
    await _finish(tester);
  });

  testWidgets('taken away early, nothing fires afterwards', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump(const Duration(milliseconds: 500));
    h.host.report(posted: _request());
    await _finish(tester);
    await tester.pump(const Duration(seconds: 8));
    expect(h.closes, 0);
  });
}
