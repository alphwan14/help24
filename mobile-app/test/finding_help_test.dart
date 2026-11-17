import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/screens/finding_help_screen.dart';
import 'package:help24/theme/app_theme.dart';

/// The moment after a request is posted.
///
/// What it must say is fixed: the real category and place, then that the
/// request is live and the poster will be told about offers. Then it goes
/// away by itself. What it must NEVER say is just as fixed: no counts and no
/// invented activity, because nothing is sent anywhere when a request is
/// posted.
PostModel _request({String category = 'Plumbing', String location = 'Westlands, Nairobi'}) =>
    PostModel(
      id: 'p1',
      title: 'Kitchen sink leaking',
      description: '',
      category: Category.fromName(category),
      location: location,
      price: 0,
      urgency: Urgency.flexible,
      type: PostType.request,
    );

const _home = 'Discover underneath';

/// FindingHelpScreen pushed over a plain page, as the composer does over the
/// shell, so closing by itself has somewhere to go back to.
Future<void> _pump(
  WidgetTester tester, {
  PostModel? post,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => FindingHelpScreen(post: post ?? _request())),
              ),
              child: const Text(_home),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text(_home));
  // Two frames: a pushed route is built offstage first (for heroes), then on
  // stage. The route's own slide-in is not what these tests time.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

/// Tear the tree down so no screen timer outlives the test.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

/// Every Text on screen, joined, for the "no numbers" check.
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join(' | ');

void main() {
  group('the words', () {
    test('come from the post', () {
      expect(findingHelpLine(_request()), 'Finding Plumbing near Westlands, Nairobi…');
      expect(findingHelpLine(_request(category: 'TV Repair', location: 'Muhoroni')),
          'Finding TV Repair near Muhoroni…');
    });

    test('"Other" names nothing, so it reads "help"; no place reads "you"', () {
      expect(findingHelpLine(_request(category: 'Other', location: '')),
          'Finding help near you…');
    });
  });

  testWidgets('finds, settles, then closes by itself', (tester) async {
    await _pump(tester);
    expect(find.text('Finding Plumbing near Westlands, Nairobi…'), findsOneWidget);
    expect(find.text(kRequestLiveTitle), findsNothing);

    // The H forms slowly: half way through the intro it is still moving.
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.hasRunningAnimations, isTrue);

    // Still finding well after the H has formed, with the crossbar breathing.
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text(kRequestLiveTitle), findsNothing);
    expect(tester.hasRunningAnimations, isTrue);

    // About 3.8 s in: the calm state.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(kRequestLiveTitle), findsOneWidget);
    expect(find.text(kRequestLiveBody), findsOneWidget);
    expect(find.text('View your post'), findsOneWidget);

    // It stays long enough to read...
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text(kRequestLiveTitle), findsOneWidget);

    // ...then goes away on its own, back to what was underneath.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    expect(find.byType(FindingHelpScreen), findsNothing);
    expect(find.text(_home), findsOneWidget);
  });

  testWidgets('never shows a count or invented activity', (tester) async {
    await _pump(tester, post: _request(location: 'Kilimani, Nairobi'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final text = _allText(tester);
      expect(RegExp(r'\d').hasMatch(text), isFalse, reason: 'a number appeared: $text');
      expect(text.toLowerCase().contains('sent to'), isFalse);
    }
    await _finish(tester);
  });

  testWidgets('reduce motion: the mark is still, the pace is the same', (tester) async {
    await _pump(tester, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 1000));
    // No ticker of the screen's own: once the route is in, nothing moves.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Finding Plumbing near Westlands, Nairobi…'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3000));
    await tester.pump();
    expect(find.text(kRequestLiveTitle), findsOneWidget);
    expect(find.text('View your post'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pumpAndSettle();
    expect(find.byType(FindingHelpScreen), findsNothing);
  });

  testWidgets('the button is not tappable before the calm state', (tester) async {
    await _pump(tester);
    final ignore = tester.widget<IgnorePointer>(
      find.ancestor(of: find.text('View your post'), matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isTrue);
    await _finish(tester);
  });

  testWidgets('closing it early leaves nothing running', (tester) async {
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(FindingHelpScreen), findsNothing);
    // Past both timers: nothing fires on a disposed screen, the page stays.
    await tester.pump(const Duration(seconds: 8));
    expect(find.text(_home), findsOneWidget);
  });
}
