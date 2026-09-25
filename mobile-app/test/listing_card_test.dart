import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/services/reputation_service.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/widgets/listing_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite for the unified [ListingCard].
///
/// WHY THESE EXIST
/// ---------------
/// `PostCard` and `JobCard` were folded into one widget. That is a
/// presentation change, but it moved a lot of CONDITIONAL rendering — eight
/// possible chips, three CTA states, an owner branch, a sponsored branch — from
/// two files into one, and most of those branches are unreachable on the test
/// device: production currently has no urgent request inside its window, no
/// sponsored campaign, no disputed job and no listing the signed-in user has
/// already applied to. Screenshots verified the common path. These verify the
/// rest, and keep verifying it.
///
/// They assert BEHAVIOUR, not pixels: which facts reach the screen, and which
/// verb the card offers. A layout change should not break them; losing a field
/// should.

/// Auth we can drive directly, with no identity backend.
class _FakeAuth extends AuthProvider {
  _FakeAuth({this.uid = 'viewer-1'});

  final String uid;

  @override
  bool get isLoggedIn => true;

  @override
  String? get currentUserId => uid;

  @override
  String get currentUserName => 'Viewer';
}

/// `hasAppliedTo` is the only thing the card asks AppProvider for.
class _FakeApp extends AppProvider {
  _FakeApp({this.applied = const {}});

  final Set<String> applied;

  @override
  bool hasAppliedTo(String postId) => applied.contains(postId);
}

Application _application(String id) => Application(
      id: id,
      applicantName: 'Applicant',
      message: '',
      proposedPrice: 0,
      timestamp: DateTime(2026, 1, 1),
    );

PostModel _post({
  String id = 'p1',
  String title = 'Fix the kitchen tap',
  String description = '',
  PostType type = PostType.request,
  Urgency urgency = Urgency.flexible,
  String status = 'open',
  double price = 0,
  String location = 'Annex, Eldoret',
  String authorUserId = 'author-1',
  List<String> images = const [],
  List<Application> applications = const [],
  bool authorHasPhone = false,
  EmploymentType? employmentType,
}) {
  return PostModel(
    id: id,
    title: title,
    description: description,
    category: Category.fromName('Plumbing'),
    location: location,
    price: price,
    urgency: urgency,
    type: type,
    status: status,
    authorName: 'Karen Brina',
    authorUserId: authorUserId,
    images: images,
    applications: applications,
    authorHasPhone: authorHasPhone,
    employmentType: employmentType,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget card, {
  AuthProvider? auth,
  AppProvider? app,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth ?? _FakeAuth()),
        ChangeNotifierProvider<AppProvider>.value(value: app ?? _FakeApp()),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme,
        home: Scaffold(
          body: SingleChildScrollView(child: card),
        ),
      ),
    ),
  );
  // Let the reputation cache's 600 ms persist debounce fire. A timer still
  // pending when the tree is disposed fails the widget-test invariant check,
  // and seeding the cache is what schedules it.
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 15));
}

void main() {
  // ReputationCompact asks ReputationService for every author it renders. Left
  // alone that is a live HTTP call with a timeout timer, and a pending timer
  // fails the widget-test invariant check — so the cache is SEEDED instead and
  // the future resolves from memory. This also makes the trust line
  // deterministic rather than dependent on whether the backend is reachable.
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ReputationService.resetForTest();
    ReputationService.seedAll([
      for (final id in ['author-1', 'viewer-1'])
        <String, dynamic>{
          'provider_id': id,
          'average_rating': 0,
          'total_reviews': 0,
          'completed_jobs': 0,
          'tier': 'new_provider',
        },
    ]);
  });

  tearDown(ReputationService.resetForTest);

  group('the verb the card offers', () {
    testWidgets('a request asks a provider to offer service', (tester) async {
      await _pump(tester, ListingCard(post: _post()));
      expect(find.text('Offer Service'), findsOneWidget);
    });

    testWidgets('an offer asks the buyer to enquire', (tester) async {
      await _pump(tester, ListingCard(post: _post(type: PostType.offer)));
      expect(find.text('Enquire'), findsOneWidget);
    });

    testWidgets('a job says Apply — the same verb the Jobs tab uses',
        (tester) async {
      await _pump(tester, ListingCard(post: _post(type: PostType.job)));
      expect(find.text('Apply'), findsOneWidget);
    });

    testWidgets('the AUTHOR is never invited to act on their own listing',
        (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post(authorUserId: 'viewer-1')),
        auth: _FakeAuth(uid: 'viewer-1'),
      );
      expect(find.text('Offer Service'), findsNothing);
      expect(find.text('Manage'), findsOneWidget);
    });

    testWidgets('the author sees a live applicant count', (tester) async {
      await _pump(
        tester,
        ListingCard(
          post: _post(
            authorUserId: 'viewer-1',
            applications: [_application('a'), _application('b')],
          ),
        ),
        auth: _FakeAuth(uid: 'viewer-1'),
      );
      expect(find.text('Applications (2)'), findsOneWidget);
    });

    testWidgets('having already responded blocks a duplicate', (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post()),
        app: _FakeApp(applied: {'p1'}),
      );
      expect(find.text('Offer Service'), findsNothing);
      expect(find.text('Offer sent'), findsOneWidget);
    });

    testWidgets('a taken request never re-offers itself', (tester) async {
      await _pump(tester, ListingCard(post: _post(status: 'assigned')));
      expect(find.text('Offer Service'), findsNothing);
      expect(find.text('In progress'), findsOneWidget);
    });
  });

  group('facts that must reach the screen', () {
    testWidgets('title, location and category', (tester) async {
      await _pump(tester, ListingCard(post: _post()));
      expect(find.text('Fix the kitchen tap'), findsOneWidget);
      expect(find.textContaining('Annex, Eldoret'), findsOneWidget);
      expect(find.textContaining('Plumbing'), findsOneWidget);
    });

    testWidgets('no budget reads as an absence, not as a price',
        (tester) async {
      await _pump(tester, ListingCard(post: _post(price: 0)));
      expect(find.text('Open to offers'), findsOneWidget);
    });

    testWidgets('a price is rendered', (tester) async {
      await _pump(tester, ListingCard(post: _post(price: 2500)));
      expect(find.textContaining('2,500'), findsOneWidget);
    });

    testWidgets("a job's employment type survives the card merge",
        (tester) async {
      // JobCard used to show this as its own chip. Folding the two cards
      // together must not drop a field the Jobs tab filters on.
      await _pump(
        tester,
        ListingCard(
          post: _post(
            type: PostType.job,
            employmentType: EmploymentType.partTime,
          ),
        ),
      );
      expect(find.textContaining('Part-time'), findsOneWidget);
    });

    testWidgets('M-Pesa readiness is shown on an offer', (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post(type: PostType.offer, authorHasPhone: true)),
      );
      expect(find.textContaining('M-Pesa'), findsOneWidget);
    });

    testWidgets('distance is shown when a proximity surface supplies it',
        (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post(), distanceLabel: '400 m away'),
      );
      expect(find.textContaining('400 m away'), findsOneWidget);
    });
  });

  group('chips are rationed', () {
    testWidgets('a live countdown beats a static Urgent label',
        (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post(urgency: Urgency.urgent), urgentCountdown: '12 min left'),
      );
      expect(find.text('12 min left'), findsOneWidget);
      // Both would be the same fact said twice.
      expect(find.text('Urgent'), findsNothing);
    });

    testWidgets('urgency shows without a countdown', (tester) async {
      await _pump(tester, ListingCard(post: _post(urgency: Urgency.urgent)));
      expect(find.text('Urgent'), findsOneWidget);
    });

    testWidgets('a paid placement is always disclosed', (tester) async {
      await _pump(tester, ListingCard(post: _post(), sponsored: true));
      expect(find.text('Sponsored'), findsOneWidget);
    });

    testWidgets('never more than two chips, however many could apply',
        (tester) async {
      // Sponsored, urgent and an applicant count all qualify at once.
      await _pump(
        tester,
        ListingCard(
          post: _post(
            urgency: Urgency.urgent,
            applications: [_application('a')],
          ),
          sponsored: true,
        ),
      );
      // The two highest-priority signals win...
      expect(find.text('Sponsored'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      // ...and the third is dropped rather than stacked.
      expect(find.text('1 applied'), findsNothing);
    });

    testWidgets('urgency is suppressed once a listing is no longer open',
        (tester) async {
      // "Urgent" on a job somebody is already doing is noise: the window it
      // refers to closed when the request was taken.
      await _pump(
        tester,
        ListingCard(post: _post(urgency: Urgency.urgent, status: 'assigned')),
      );
      expect(find.text('Urgent'), findsNothing);
      expect(find.text('In progress'), findsOneWidget);
    });

    testWidgets('lifecycle state is reported ONCE, in the action slot',
        (tester) async {
      // The old card drew a status chip and then the action slot drew the same
      // fact again. Exactly one 'Completed' may reach the screen.
      await _pump(tester, ListingCard(post: _post(status: 'completed')));
      expect(find.text('Completed'), findsOneWidget);
    });
  });

  group('photo or description, never both', () {
    testWidgets('a description shows when there is no photo', (tester) async {
      await _pump(
        tester,
        ListingCard(post: _post(description: 'Tap drips overnight.')),
      );
      expect(find.text('Tap drips overnight.'), findsOneWidget);
    });

    testWidgets('a description that only repeats the meta line is dropped',
        (tester) async {
      // Production has a job whose entire description is its start signal, so
      // the card printed the same words twice.
      await _pump(
        tester,
        ListingCard(post: _post(description: 'Annex, Eldoret')),
      );
      expect(find.textContaining('Annex, Eldoret'), findsOneWidget);
    });
  });

  group('both themes render the same card', () {
    for (final brightness in Brightness.values) {
      testWidgets('no overflow in ${brightness.name}', (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.8125;
        addTearDown(tester.view.reset);

        await _pump(
          tester,
          ListingCard(
            post: _post(
              title: 'Looking for a security guard to operate in my beauty '
                  'parlour on a long term basis starting next week',
              price: 12500,
              applications: [_application('a')],
            ),
          ),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
