import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/utils/auth_error_mapper.dart';
import 'package:help24/widgets/auth/email_verification_banner.dart';
import 'package:provider/provider.dart';

/// Regression suite for the email-verification banner.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// "Confirm your email → Send Link does not send any email. Nothing in Inbox.
/// Nothing in Spam." Two failures stacked:
///
///   1. The send WAS being rejected — `ActionCodeSettings.url` points at
///      help24.co.ke, a domain not yet in the identity console's authorized
///      list, so the provider refused it before it left. AuthService now falls
///      back to an unbranded link rather than failing.
///   2. The banner stored only `_sent = ok`. A false result reverted it to its
///      exact previous appearance — pixel-identical to never having tapped —
///      even though AuthProvider.failure held the reason the whole time.
///
/// These tests cover (2), the part that made the failure invisible.

class _FakeAuth extends AuthProvider {
  _FakeAuth({required this.sendSucceeds, this.recordedFailure});

  bool sendSucceeds;
  AuthFailure? recordedFailure;
  int sendCalls = 0;

  @override
  bool get needsEmailVerification => true;

  @override
  String? get currentUserEmail => 'someone@example.com';

  @override
  AuthFailure? get failure => recordedFailure;

  @override
  Future<bool> sendVerificationEmail() async {
    sendCalls++;
    return sendSucceeds;
  }

  // The banner polls this on mount; there is no identity backend under test.
  @override
  Future<bool> refreshEmailVerified() async => false;
}

void main() {
  Future<void> pumpBanner(WidgetTester tester, _FakeAuth auth) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: const MaterialApp(
          home: Scaffold(body: EmailVerificationBanner()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('A failed send is visible', () {
    testWidgets('states the reason instead of silently reverting',
        (tester) async {
      final auth = _FakeAuth(
        sendSucceeds: false,
        recordedFailure: const AuthFailure(
          title: "We couldn't send it",
          message: 'Please try again in a moment.',
        ),
      );
      await pumpBanner(tester, auth);

      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();

      expect(auth.sendCalls, 1);
      expect(find.text("We couldn't send it"), findsOneWidget);
      expect(find.text('Please try again in a moment.'), findsOneWidget);
      // Must NOT claim success.
      expect(find.text('Verification email sent'), findsNothing);
    });

    testWidgets('still says something when no reason was recorded',
        (tester) async {
      // Defensive: a false result with a null failure must not reproduce the
      // original silence.
      final auth = _FakeAuth(sendSucceeds: false);
      await pumpBanner(tester, auth);

      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();

      expect(find.textContaining("couldn't send"), findsOneWidget);
    });

    testWidgets('offers a way to retry — a failure is not a dead end',
        (tester) async {
      final auth = _FakeAuth(sendSucceeds: false);
      await pumpBanner(tester, auth);

      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);

      auth.sendSucceeds = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(auth.sendCalls, 2);
      expect(find.text('Verification email sent'), findsOneWidget);
    });
  });

  group('A successful send is confirmed and rate-limited', () {
    testWidgets('confirms and names the inbox', (tester) async {
      final auth = _FakeAuth(sendSucceeds: true);
      await pumpBanner(tester, auth);

      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();

      expect(find.text('Verification email sent'), findsOneWidget);
      expect(find.textContaining('someone@example.com'), findsOneWidget);
    });

    testWidgets('cannot be spammed into a provider lockout', (tester) async {
      final auth = _FakeAuth(sendSucceeds: true);
      await pumpBanner(tester, auth);

      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();

      // Success hides the action entirely; the cooldown backs the retry path.
      expect(find.text('Send the link'), findsNothing);
      expect(auth.sendCalls, 1);
    });

    testWidgets('a retry after failure enters a visible cooldown',
        (tester) async {
      final auth = _FakeAuth(sendSucceeds: false);
      await pumpBanner(tester, auth);
      await tester.tap(find.text('Send the link'));
      await tester.pumpAndSettle();

      auth.sendSucceeds = true;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Confirmed, and the action is gone rather than inviting a second send.
      expect(find.text('Verification email sent'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('The banner stays out of the way when it should', () {
    testWidgets('renders nothing once the address is confirmed',
        (tester) async {
      final auth = _NoPromptAuth();
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: const MaterialApp(
            home: Scaffold(body: EmailVerificationBanner()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Confirm your email'), findsNothing);
    });

    testWidgets('can be dismissed', (tester) async {
      final auth = _FakeAuth(sendSucceeds: true);
      await pumpBanner(tester, auth);
      expect(find.text('Confirm your email'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm your email'), findsNothing);
    });
  });
}

class _NoPromptAuth extends AuthProvider {
  @override
  bool get needsEmailVerification => false;

  @override
  Future<bool> refreshEmailVerified() async => true;
}
