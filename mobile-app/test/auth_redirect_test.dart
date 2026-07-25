import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/utils/precise_route.dart';
import 'package:help24/widgets/auth_guard.dart';
import 'package:provider/provider.dart';

/// Regression suite for the auth redirect defect.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Signing in from a protected action left the user staring at the auth screen.
/// They had to press Back manually, and the action they originally asked for
/// was silently dropped. Two causes, both structural:
///
///   1. `Navigator.pop(context)` removes the navigator's TOPMOST route, not the
///      route that owns the context. HomeScreen opens a location-permission
///      sheet on the same uid change that completes sign-in, so the auth screen
///      could pop that sheet instead of itself and strand.
///   2. The guard then decided whether to run the user's action from the pop's
///      RESULT VALUE. Any dismissal that was not literally `pop(true)` — a
///      drag, a back press, a value-less pop — discarded the intent even though
///      the user was signed in by that point.
///
/// The tests below assert the two invariants that replaced them: a route
/// dismisses ITSELF, and the action is decided from AUTH STATE.

/// Signed-in state we can drive directly, with no identity backend.
class _FakeAuth extends AuthProvider {
  _FakeAuth({this.signedIn = false, this.available = true});

  bool signedIn;
  final bool available;

  @override
  bool get isLoggedIn => signedIn;

  @override
  bool get isAuthAvailable => available;
}

void main() {
  tearDown(() => AuthGuard.debugPresentOverride = null);

  group('A presented route dismisses itself, not whatever is on top', () {
    testWidgets('dismisses normally when it is the topmost route',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => presentDismissibleRoute(
              context: context,
              builder: (_, dismiss) => TextButton(
                onPressed: dismiss,
                child: const Text('AUTH'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('AUTH'), findsOneWidget);

      await tester.tap(find.text('AUTH'));
      await tester.pumpAndSettle();
      expect(find.text('AUTH'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('dismisses itself even when another route sits ON TOP',
        (tester) async {
      // This is the reported scenario: a competing sheet (the location
      // permission ask) arrives in the same instant sign-in completes.
      late VoidCallback dismissAuth;
      late NavigatorState nav;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              nav = Navigator.of(context);
              presentDismissibleRoute(
                context: context,
                builder: (_, dismiss) {
                  dismissAuth = dismiss;
                  return const Text('AUTH');
                },
              );
            },
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A second modal lands above the auth screen.
      unawaited(showModalBottomSheet<void>(
        context: nav.context,
        builder: (_) => const Text('LOCATION'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('LOCATION'), findsOneWidget);

      // Sign-in completes and the auth screen dismisses itself.
      dismissAuth();
      await tester.pumpAndSettle();

      // The old code popped the topmost route, so this used to be inverted:
      // LOCATION gone, AUTH stranded on screen.
      expect(find.text('AUTH'), findsNothing);
      expect(find.text('LOCATION'), findsOneWidget);
    });

    testWidgets('a second dismissal is harmless', (tester) async {
      late VoidCallback dismissAuth;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => presentDismissibleRoute(
              context: context,
              builder: (_, dismiss) {
                dismissAuth = dismiss;
                return const Text('AUTH');
              },
            ),
            child: const Text('open'),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      dismissAuth();
      await tester.pumpAndSettle();
      dismissAuth(); // must not throw or pop the underlying screen
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('The action is decided by auth state, not by a pop result', () {
    Future<bool> runGuard(
      WidgetTester tester, {
      required _FakeAuth auth,
      required VoidCallback onAuthenticated,
    }) async {
      late Future<bool> result;
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => result = AuthGuard.requireAuth(
                    context,
                    action: 'do the thing',
                    onAuthenticated: onAuthenticated,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('runs when the screen closes with NO result but signed in',
        (tester) async {
      // Exactly the dropped-intent case: dismissed by drag or Back, so the
      // route returns null — but the user did sign in.
      final auth = _FakeAuth(signedIn: false);
      AuthGuard.debugPresentOverride = (_, __, ___) async {
        auth.signedIn = true; // sign-in happened while the screen was up
      };

      var ran = false;
      final ok = await runGuard(tester,
          auth: auth, onAuthenticated: () => ran = true);

      expect(ran, isTrue, reason: 'the user signed in — honour their action');
      expect(ok, isTrue);
    });

    testWidgets('does NOT run when the user cancels without signing in',
        (tester) async {
      final auth = _FakeAuth(signedIn: false);
      AuthGuard.debugPresentOverride = (_, __, ___) async {};

      var ran = false;
      final ok = await runGuard(tester,
          auth: auth, onAuthenticated: () => ran = true);

      expect(ran, isFalse);
      expect(ok, isFalse);
    });

    testWidgets('runs immediately when already signed in, showing no UI',
        (tester) async {
      final auth = _FakeAuth(signedIn: true);
      var presented = false;
      AuthGuard.debugPresentOverride = (_, __, ___) async => presented = true;

      var ran = false;
      final ok = await runGuard(tester,
          auth: auth, onAuthenticated: () => ran = true);

      expect(ran, isTrue);
      expect(ok, isTrue);
      expect(presented, isFalse);
    });

    testWidgets('blocks with a message when auth is unavailable',
        (tester) async {
      final auth = _FakeAuth(signedIn: false, available: false);
      var ran = false;
      final ok = await runGuard(tester,
          auth: auth, onAuthenticated: () => ran = true);

      expect(ran, isFalse);
      expect(ok, isFalse);
      expect(find.textContaining("isn't available"), findsOneWidget);
    });
  });

  group('Competing modals are serialised', () {
    testWidgets('settled completes only after the auth screen closes',
        (tester) async {
      expect(AuthGuard.isPresenting, isFalse);

      final auth = _FakeAuth(signedIn: false);
      final gate = Completer<void>();
      AuthGuard.debugPresentOverride = (_, __, ___) => gate.future;

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => AuthGuard.requireAuth(
                  context,
                  action: 'x',
                  onAuthenticated: () {},
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(AuthGuard.isPresenting, isTrue);
      var settled = false;
      unawaited(AuthGuard.settled.then((_) => settled = true));
      await tester.pump();
      expect(settled, isFalse, reason: 'auth is still on screen');

      gate.complete();
      await tester.pumpAndSettle();
      expect(settled, isTrue);
      expect(AuthGuard.isPresenting, isFalse);
    });

    testWidgets('settled resolves instantly when nothing is presenting',
        (tester) async {
      var settled = false;
      await AuthGuard.settled.then((_) => settled = true);
      expect(settled, isTrue);
    });
  });
}
