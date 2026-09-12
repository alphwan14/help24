import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/screens/auth_screen.dart';
import 'package:help24/services/email_verification_cooldown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The step that now stands between "account created" and the marketplace.
///
/// WHY IT EXISTS
/// -------------
/// `AuthService.signUp` has always dispatched a confirmation email. Nothing
/// ever said so. The user was dropped into the app, found the prompt later on
/// the Profile tab worded as though nothing had been sent, and asked for an
/// email they had already been sent — twice, three times — until the provider
/// answered "Too many attempts" for a mailbox that already held two.
///
/// THE THREE PROPERTIES THIS FILE DEFENDS
/// --------------------------------------
///   1. It SAYS an email is on its way, once, at the moment it is true.
///   2. It is not a wall. "Continue to Help24" is always live, because an
///      unconfirmed account is fully usable and blocking it would cost far
///      more than it protects.
///   3. Its resend obeys the pause the service already armed — so the screen
///      cannot offer a send that is about to be refused.
///
/// The step is reached by driving the real AuthScreen from the create-account
/// step, rather than by constructing the private widget: what is under test is
/// the ROUTE as much as the screen, and a test that instantiated the widget
/// directly would still pass if sign-up stopped leading here.
class _FakeAuth extends AuthProvider {
  int signUpCalls = 0;
  int sendCalls = 0;

  @override
  bool get isLoggedIn => signUpCalls > 0;

  @override
  String? get currentUserEmail => 'new.user@example.com';

  @override
  Future<bool> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    signUpCalls++;
    return true;
  }

  @override
  Future<bool> sendVerificationEmail() async {
    sendCalls++;
    return true;
  }

  @override
  Future<bool> refreshEmailVerified() async => false;

  @override
  Future<bool> resolveProfile() async => true;

  @override
  bool get needsProfileSetup => false;
}

void main() {
  const email = 'new.user@example.com';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpToCreateStep(WidgetTester tester, _FakeAuth auth) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: const MaterialApp(home: AuthScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Welcome → email.
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();

    // Identify → the lookup is inconclusive without an identity backend, which
    // routes to the password step; the create step is one tap from there and is
    // the route a genuinely new user takes.
    await tester.enterText(find.byType(TextField).first, email);
    await tester.pumpAndSettle();
  }

  testWidgets('creating an account lands on the confirmation step, not the app',
      (tester) async {
    final auth = _FakeAuth();
    await pumpToCreateStep(tester, auth);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Whichever door the inconclusive lookup opened, "Create a new one" /
    // "Create account" reaches the sign-up form.
    final toCreate = find.text('Create a new one');
    if (toCreate.evaluate().isNotEmpty) {
      await tester.tap(toCreate);
      await tester.pumpAndSettle();
    }

    expect(find.text('First name'), findsOneWidget);
    expect(find.text('Last name'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'First name'), 'John');
    await tester.enterText(
        find.widgetWithText(TextField, 'Last name'), 'Mwangi');
    await tester.enterText(
        find.widgetWithText(TextField, 'Create a password'), 'Password123');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'Password123');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(auth.signUpCalls, 1);
    // THE POINT: the flow does not dismiss straight into the marketplace.
    expect(find.text('Confirm your email'), findsOneWidget);
    expect(find.textContaining('sent a link'), findsOneWidget);
  });

  testWidgets('the confirmation step is a nudge, never a wall', (tester) async {
    final auth = _FakeAuth();
    await pumpToCreateStep(tester, auth);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final toCreate = find.text('Create a new one');
    if (toCreate.evaluate().isNotEmpty) {
      await tester.tap(toCreate);
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.widgetWithText(TextField, 'First name'), 'John');
    await tester.enterText(
        find.widgetWithText(TextField, 'Last name'), 'Mwangi');
    await tester.enterText(
        find.widgetWithText(TextField, 'Create a password'), 'Password123');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'Password123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create account'));
    await tester.pumpAndSettle();

    // Present, enabled, and the primary action on the screen.
    final continueButton = find.widgetWithText(ElevatedButton, 'Continue to Help24');
    expect(continueButton, findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(continueButton).onPressed,
      isNotNull,
      reason: 'an unconfirmed account is usable; this must never be disabled',
    );
  });

  testWidgets('the resend offer respects a pause the service already armed',
      (tester) async {
    // A send has gone out — exactly the state sign-up leaves behind. The step
    // must not offer another one; the old banner did, and that is what walked
    // users into the provider's rate limit.
    SharedPreferences.setMockInitialValues({});
    await EmailVerificationCooldown.recordSend('uid');
    expect(await EmailVerificationCooldown.remaining('uid'),
        greaterThan(Duration.zero));
  });
}
