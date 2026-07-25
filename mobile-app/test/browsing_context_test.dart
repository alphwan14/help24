import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/widgets/post_flows.dart';
import 'package:provider/provider.dart';

/// Regression suite for browsing interruptions.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Tapping a completed or already-taken listing in Discover pushed the entire
/// post detail screen, whose only new information was one sentence in the
/// action bar ("This job is completed"). The user paid a screen transition,
/// lost their place in the feed, read a line, and pressed Back.
///
/// The rule now: an informational state answers IN PLACE. The feed keeps its
/// scroll position, filters and search. The detail screen stays reachable on
/// purpose, and anyone with real business on the post still gets it directly.

class _FakeAuth extends AuthProvider {
  _FakeAuth(this._uid);
  final String _uid;

  @override
  String? get currentUserId => _uid;
}

/// Counts pushes. The question these tests ask is "did we take the user off
/// the feed?", which is about NAVIGATION — rendering the real detail screen
/// would only drag its provider and network dependencies into the assertion.
class _PushSpy extends NavigatorObserver {
  int pushes = 0;
  Route<dynamic>? last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    // The initial route counts as a push; only journeys away from it matter.
    if (previous != null) {
      pushes++;
      last = route;
    }
    super.didPush(route, previous);
  }
}

PostModel makePost({
  String status = 'open',
  String authorUserId = 'author-1',
  String? selectedProviderUserId,
  bool payoutInProgress = false,
}) =>
    PostModel(
      id: 'p1',
      title: 'Fix my sink',
      description: 'desc',
      category: Category.fromName('Other'),
      location: 'Nairobi',
      price: 1500,
      urgency: Urgency.flexible,
      type: PostType.request,
      status: status,
      authorUserId: authorUserId,
      selectedProviderUserId: selectedProviderUserId,
      // Enriched after load by PostService, not a constructor argument.
    )..payoutInProgress = payoutInProgress;

void main() {
  group('closedListingReason states the status once, for everyone', () {
    test('an open listing has no reason and never blocks', () {
      expect(closedListingReason(makePost()), isNull);
    });

    test('completed', () {
      expect(closedListingReason(makePost(status: 'completed')),
          'This job is completed.');
    });

    test('completed with a payout still settling', () {
      expect(
        closedListingReason(
            makePost(status: 'completed', payoutInProgress: true)),
        'This job is completed — payment is being finalised.',
      );
    });

    test('disputed', () {
      expect(closedListingReason(makePost(status: 'disputed')),
          'This job is in dispute.');
    });

    test('cancelled', () {
      expect(closedListingReason(makePost(status: 'cancelled')),
          'This listing was closed.');
    });

    test('assigned reads as "already has a provider"', () {
      expect(closedListingReason(makePost(status: 'assigned')),
          'This request already has a provider.');
    });
  });

  Future<_PushSpy> tapCard(
    WidgetTester tester,
    PostModel post, {
    String uid = 'viewer-1',
  }) async {
    final spy = _PushSpy();
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: _FakeAuth(uid),
        child: MaterialApp(
          navigatorObservers: [spy],
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: [
                  const SizedBox(height: 40, child: Text('FEED')),
                  ElevatedButton(
                    onPressed: () => openPostFromFeed(context, post),
                    child: const Text('card'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('card'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    return spy;
  }

  group('The feed is never replaced by an informational state', () {
    testWidgets('a completed listing answers in place, feed still visible',
        (tester) async {
      final spy = await tapCard(tester, makePost(status: 'completed'));

      expect(spy.pushes, 0,
          reason: 'browsing context must survive an informational state');
      expect(find.text('FEED'), findsOneWidget);
      expect(find.text('This job is completed.'), findsOneWidget);
    });

    testWidgets('a taken request answers in place', (tester) async {
      final spy = await tapCard(tester, makePost(status: 'assigned'));

      expect(spy.pushes, 0);
      expect(find.text('This request already has a provider.'), findsOneWidget);
    });

    testWidgets('the notification disappears on its own', (tester) async {
      await tapCard(tester, makePost(status: 'completed'));
      expect(find.byType(SnackBar), findsOneWidget);

      // Long enough to clear the 4s display window plus the exit animation.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing,
          reason: 'a notification must never need dismissing');
      expect(find.text('card'), findsOneWidget);
    });

    testWidgets('offering an action does not make it permanent',
        (tester) async {
      await tapCard(tester, makePost(status: 'completed'));
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));

      // Flutter defaults `persist` to `action != null`, so adding the "View"
      // shortcut silently opts the bar into staying on screen forever. This is
      // the exact defect that shipped; assert the property, not just the timing.
      expect(bar.persist, isFalse);
      expect(bar.behavior, SnackBarBehavior.floating,
          reason: 'floats over the feed rather than displacing it');
    });

    testWidgets('nothing becomes unreachable — a way in is always offered',
        (tester) async {
      await tapCard(tester, makePost(status: 'completed'));

      // "Don't interrupt browsing" must not become "you may never look at
      // this". The route the action takes is covered by inPlaceAnswerFor below.
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget);
    });
  });

  group('Who gets the full screen anyway', () {
    test('an OPEN listing always opens normally', () {
      expect(inPlaceAnswerFor(makePost(), 'viewer-1'), isNull);
    });

    test('the author of a completed post opens it directly', () {
      expect(
        inPlaceAnswerFor(
            makePost(status: 'completed', authorUserId: 'me'), 'me'),
        isNull,
      );
    });

    test('the selected provider opens it directly', () {
      expect(
        inPlaceAnswerFor(
          makePost(status: 'assigned', selectedProviderUserId: 'me'),
          'me',
        ),
        isNull,
      );
    });

    test('an uninvolved viewer is answered in place', () {
      expect(
        inPlaceAnswerFor(
            makePost(status: 'completed', authorUserId: 'someone-else'),
            'viewer-1'),
        'This job is completed.',
      );
    });

    test('a signed-out browser is not treated as the author', () {
      // authorUserId is '' on some legacy rows; an empty uid must never match
      // it and hand a stranger the owner's screen.
      expect(
        inPlaceAnswerFor(makePost(status: 'completed', authorUserId: ''), ''),
        'This job is completed.',
      );
    });

    test('a signed-out browser is not treated as the selected provider', () {
      expect(
        inPlaceAnswerFor(
          makePost(status: 'assigned', selectedProviderUserId: null),
          '',
        ),
        'This request already has a provider.',
      );
    });
  });
}
