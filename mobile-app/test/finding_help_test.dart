import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/screens/finding_help_screen.dart';
import 'package:help24/theme/app_theme.dart';

/// The moment after a request is posted.
///
/// What it must say is fixed: the real category and place, then that the
/// request is live and the poster will be told about offers. What it must
/// NEVER say is just as fixed: no counts and no invented activity, because
/// nothing is sent anywhere when a request is posted.
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

Future<void> _pump(
  WidgetTester tester, {
  PostModel? post,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: FindingHelpScreen(post: post ?? _request()),
        ),
      ),
    ),
  );
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

  testWidgets('finds, then settles into the calm state with a way to the post',
      (tester) async {
    await _pump(tester);
    expect(find.text('Finding Plumbing near Westlands, Nairobi…'), findsOneWidget);
    expect(find.text(kRequestLiveTitle), findsNothing);

    // The intro, then the crossbar breathing while it "finds".
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.hasRunningAnimations, isTrue);

    // ~2.6 s in: the calm state.
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(kRequestLiveTitle), findsOneWidget);
    expect(find.text(kRequestLiveBody), findsOneWidget);
    expect(find.text('View your post'), findsOneWidget);

    // Calm means still: the breathing eases out and stops.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('never shows a count or invented activity', (tester) async {
    await _pump(tester, post: _request(location: 'Kilimani, Nairobi'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final text = _allText(tester);
      expect(RegExp(r'\d').hasMatch(text), isFalse, reason: 'a number appeared: $text');
      expect(text.toLowerCase().contains('sent to'), isFalse);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion: the mark is still, and the words still change',
      (tester) async {
    await _pump(tester, reduceMotion: true);
    // Nothing moves: no ticker runs at any point.
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Finding Plumbing near Westlands, Nairobi…'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump();
    expect(find.text(kRequestLiveTitle), findsOneWidget);
    expect(find.text('View your post'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the button is not tappable before the calm state', (tester) async {
    await _pump(tester);
    final ignore = tester.widget<IgnorePointer>(
      find.ancestor(of: find.text('View your post'), matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isTrue);
    await tester.pump(const Duration(milliseconds: 2700));
    await tester.pumpAndSettle();
  });
}
