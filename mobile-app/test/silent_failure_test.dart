import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/application_service.dart';
import 'package:help24/utils/action_feedback.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/widgets/application_modal.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Regression suite for silent failures.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// "Sending an Offer does absolutely nothing. No error. No loading. No success.
/// Nothing." ApplicationModal caught every exception with `catch (_)` on the
/// stated assumption that "the caller already showed a message" — but the
/// caller handled exactly one exception type. A rejected write reset the
/// spinner and said nothing, and the modal sat there looking untouched.
///
/// The rule now: the modal owns the outcome. onSubmit does the work and throws;
/// success confirms and closes, failure is stated IN PLACE with the typed
/// message preserved.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> openModal(
    WidgetTester tester, {
    required Future<void> Function(String) onSubmit,
    String type = 'request',
  }) async {
    await tester.pumpWidget(host(
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            // Both real call sites (post_flows, jobs_screen) set this. Without
            // it the sheet is capped at 9/16 of the screen and the submit
            // button falls outside the visible area once the error card is
            // added — which is a property of the harness, not of the widget.
            isScrollControlled: true,
            builder: (_) => ApplicationModal(
              title: 'Fix my sink',
              type: type,
              onSubmit: onSubmit,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('A failed submission is always visible', () {
    testWidgets('a rejected write is stated, not swallowed', (tester) async {
      await openModal(
        tester,
        onSubmit: (_) async => throw PostgrestException(
          message: 'new row violates row-level security policy',
        ),
      );

      await tester.enterText(find.byType(TextField), 'I can help today');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();

      // The old behaviour: spinner off, sheet open, nothing said.
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.textContaining("don't have permission"), findsOneWidget);
    });

    testWidgets('the sheet stays open and keeps what the user typed',
        (tester) async {
      await openModal(
        tester,
        onSubmit: (_) async => throw Exception('network down'),
      );

      await tester.enterText(find.byType(TextField), 'I can help today');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();

      expect(find.byType(ApplicationModal), findsOneWidget);
      expect(find.text('I can help today'), findsOneWidget,
          reason: 'retrying must not cost the user their message');
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the spinner always resets so the user is never stuck',
        (tester) async {
      await openModal(tester, onSubmit: (_) async => throw Exception('nope'));

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a duplicate application reads as a rule, not an error code',
        (tester) async {
      await openModal(
        tester,
        onSubmit: (_) async => throw DuplicateApplicationException(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();

      expect(find.text('Already applied'), findsOneWidget);
      expect(find.textContaining('already responded'), findsOneWidget);
    });

    testWidgets('retrying after a failure can succeed', (tester) async {
      var attempts = 0;
      await openModal(tester, onSubmit: (_) async {
        attempts++;
        if (attempts == 1) throw Exception('transient');
      });

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Try again'));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byType(ApplicationModal), findsNothing);
      expect(find.text('Offer sent'), findsOneWidget);
    });
  });

  group('A successful submission is always confirmed', () {
    testWidgets('closes the sheet and says so', (tester) async {
      await openModal(tester, onSubmit: (_) async {});

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Offer'));
      await tester.pumpAndSettle();

      expect(find.byType(ApplicationModal), findsNothing);
      expect(find.text('Offer sent'), findsOneWidget);
    });

    testWidgets('confirms in the words of the action taken', (tester) async {
      await openModal(tester, onSubmit: (_) async {}, type: 'job');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Application sent'), findsOneWidget);
    });
  });

  group('ActionFeedback.run cannot end in silence', () {
    testWidgets('reports a throw from a fire-and-forget action',
        (tester) async {
      await tester.pumpWidget(host(
        Builder(
          builder: (context) => ElevatedButton(
            // The hazard this guards: a Future-returning function invoked as a
            // VoidCallback, whose exception would otherwise vanish into an
            // unhandled async error.
            onPressed: () => ActionFeedback.run(
              context,
              () async => throw Exception('boom'),
              context_: ErrorContext.apply,
            ),
            child: const Text('go'),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an error with a Retry shortcut still clears itself',
        (tester) async {
      // Flutter defaults SnackBar.persist to `action != null`, so any bar
      // carrying Retry stays on screen until tapped. Feedback must never
      // become permanent furniture.
      await tester.pumpWidget(host(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => ActionFeedback.failure(
              context,
              Exception('nope'),
              onRetry: () {},
            ),
            child: const Text('go'),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('confirms success when asked to', (tester) async {
      await tester.pumpWidget(host(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => ActionFeedback.run(
              context,
              () async {},
              successMessage: 'Done',
            ),
            child: const Text('go'),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('Errors never leak implementation detail', () {
    test('a raw database rejection never reaches the user verbatim', () {
      final message = ErrorMapper.toMessage(
        PostgrestException(
          message: 'new row violates row-level security policy for table '
              '"applications"',
          code: '42501',
        ),
        context: ErrorContext.apply,
      );

      expect(message, "You don't have permission to do that.");
      for (final leak in ['row-level', 'applications', '42501', 'postgrest']) {
        expect(message.toLowerCase(), isNot(contains(leak)));
      }
    });
  });
}
