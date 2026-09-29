import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart' show PostType;
import 'package:help24/models/promotion_models.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/screens/promotion/promote_business_screen.dart';
import 'package:help24/services/promotion_service.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/utils/mpesa_failure_copy.dart';
import 'package:help24/widgets/loading_empty_offline.dart';
import 'package:http/http.dart' show ClientException;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, AuthRetryableFetchException, PostgrestException, StorageException;

/// THE REPORTED BUG, VERBATIM.
///
/// Promote Business, opened with no connection, rendered this on screen
/// because its FutureBuilder showed `'${snap.error}'`. package:http's IOClient
/// wraps the SocketException in a ClientException; the uri carries the user's
/// id. Every assertion about "the production error" below uses this object.
ClientException _productionError() => ClientException(
      "SocketException: Failed host lookup: 'api.help24.co.ke' "
      '(OS Error: No address associated with hostname, errno = 7)',
      Uri.parse('https://api.help24.co.ke/promotions/campaigns?user_id=uid_123'),
    );

/// A Help24 service exception as the backend produces them: the server's
/// `message` plus the HTTP status (JobsException, PromotionException, …).
class _ApiError implements Exception {
  _ApiError(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => 'ApiError($statusCode): $message';
}

/// A Help24 service exception that wraps the original failure in its text —
/// the `'Failed to create post: $e'` pattern, which carries no status.
class _WrappingError implements Exception {
  _WrappingError(this.message);
  final String message;
  @override
  String toString() => message;
}

Object _typeError() {
  try {
    const dynamic value = null;
    // ignore: unnecessary_cast
    return value as String;
  } catch (e) {
    return e;
  }
}

/// What no user-facing string may contain. The product requirement, as data.
final List<RegExp> _forbidden = [
  RegExp('clientexception', caseSensitive: false),
  RegExp('socketexception', caseSensitive: false),
  RegExp('exception', caseSensitive: false),
  RegExp('failed host lookup', caseSensitive: false),
  RegExp('host lookup', caseSensitive: false),
  RegExp('os error', caseSensitive: false),
  RegExp('errno', caseSensitive: false),
  RegExp(r'api\.help24', caseSensitive: false),
  RegExp('help24.co.ke/promotions', caseSensitive: false),
  RegExp('uri=', caseSensitive: false),
  RegExp('supabase', caseSensitive: false),
  RegExp('firebase', caseSensitive: false),
  RegExp('postgres', caseSensitive: false),
  RegExp('pgrst', caseSensitive: false),
  RegExp(r'\bdart\b', caseSensitive: false),
  RegExp(r'https?:', caseSensitive: false),
  RegExp('row-level', caseSensitive: false),
  RegExp('constraint', caseSensitive: false),
  RegExp('stack trace', caseSensitive: false),
  RegExp("type '", caseSensitive: false),
  RegExp('subtype', caseSensitive: false),
  RegExp(r'\bnull\b', caseSensitive: false),
  RegExp('daraja', caseSensitive: false),
  RegExp('mpesa_', caseSensitive: false),
  RegExp('properties of', caseSensitive: false),
  RegExp('unexpected character', caseSensitive: false),
  RegExp(r'[{}]'),
  RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-'), // a UUID
  RegExp(r'\b[a-z]+_[a-z_]+\b'), // a field name: post_id, user_id
];

void _expectClean(String text, {required String because}) {
  for (final pattern in _forbidden) {
    expect(pattern.hasMatch(text), isFalse,
        reason: 'leaked ${pattern.pattern} ($because): "$text"');
  }
  expect(text.trim(), isNotEmpty, reason: because);
}

void _expectFailureClean(AppFailure f, {required String because}) {
  _expectClean(f.title, because: '$because / title');
  _expectClean(f.message, because: '$because / message');
  if (f.detail != null) _expectClean(f.detail!, because: '$because / detail');
}

void main() {
  group('the Promote Business regression', () {
    test('the exact production exception reads as offline, in plain words', () {
      final failure =
          ErrorMapper.toFailure(_productionError(), context: ErrorContext.loadContent);
      expect(failure.category, ErrorCategory.networkOffline);
      expect(failure.title, "You're offline");
      expect(failure.message,
          "You're offline. Check your internet connection and try again.");
      expect(failure.isOffline, isTrue);
      expect(failure.isRetryable, isTrue);
      _expectFailureClean(failure, because: 'production ClientException');
    });

    test('the underlying SocketException is offline too', () {
      final failure = ErrorMapper.toFailure(
        const SocketException(
          "Failed host lookup: 'api.help24.co.ke'",
          osError: OSError('No address associated with hostname', 7),
        ),
      );
      expect(failure.category, ErrorCategory.networkOffline);
      _expectFailureClean(failure, because: 'SocketException');
    });

    testWidgets('the failure view shows the plain sentence, never the exception',
        (tester) async {
      var retried = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ErrorRetryView.fromError(_productionError(), onRetry: () => retried++),
        ),
      ));

      expect(find.text("You're offline"), findsOneWidget);
      expect(find.text('Check your internet connection and try again.'), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.textContaining('api.help24.co.ke'), findsNothing);
      expect(find.textContaining('host lookup'), findsNothing);

      await tester.tap(find.text('Retry'));
      expect(retried, 1);
    });

    testWidgets('a raw string handed to the plain view is still refused', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ErrorRetryView(message: '${_productionError()}')),
      ));
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    });
  });

  group('Promote Business, on the real screen', () {
    Future<void> pumpHub(
      WidgetTester tester, {
      required Future<List<PromotionCampaign>> Function(String) campaigns,
      required Future<List<PromotionPaymentRecord>> Function(String) payments,
    }) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ConnectivityProvider>(
          create: (_) =>
              ConnectivityProvider(probeUrl: 'http://127.0.0.1:9/health', autoStart: false),
          child: MaterialApp(
            home: PromoteBusinessScreen(
              uid: 'uid_123',
              loadCampaigns: campaigns,
              loadPayments: payments,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Every string on screen, so a leak anywhere fails the test — not only in
    /// the widget the test happens to look for.
    List<String> allText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .toList();

    testWidgets('internet OFF: both tabs say "You\'re offline", nothing raw',
        (tester) async {
      await pumpHub(
        tester,
        campaigns: (_) => Future.error(_productionError()),
        payments: (_) => Future.error(_productionError()),
      );

      expect(find.text("You're offline"), findsOneWidget);
      for (final t in allText(tester)) {
        _expectClean(t, because: 'Campaigns tab, offline');
      }

      await tester.tap(find.text('Payments'));
      await tester.pumpAndSettle();
      expect(find.text("You're offline"), findsOneWidget);
      for (final t in allText(tester)) {
        _expectClean(t, because: 'Payments tab, offline');
      }
    });

    testWidgets('request timeout: "taking too long", nothing raw', (tester) async {
      await pumpHub(
        tester,
        campaigns: (_) => Future.error(TimeoutException('after 0:00:30', const Duration(seconds: 30))),
        payments: (_) async => const [],
      );
      expect(find.text('This is taking too long'), findsOneWidget);
      for (final t in allText(tester)) {
        _expectClean(t, because: 'timeout');
      }
    });

    testWidgets('server unavailable: says Help24 is unavailable, not offline',
        (tester) async {
      await pumpHub(
        tester,
        campaigns: (_) => Future.error(PromotionException(
            "We're having trouble on our end. Please try again shortly.",
            statusCode: 503)),
        payments: (_) async => const [],
      );
      expect(find.text('Help24 is temporarily unavailable'), findsOneWidget);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('internet ON: the empty state, and Retry reloads', (tester) async {
      var calls = 0;
      await pumpHub(
        tester,
        campaigns: (_) async {
          calls++;
          if (calls == 1) throw _productionError();
          return const <PromotionCampaign>[];
        },
        payments: (_) async => const [],
      );
      expect(find.text("You're offline"), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Get discovered'), findsOneWidget);
      expect(calls, 2);
    });
  });

  group('each failure is classified for what it is', () {
    test('timeouts', () {
      final f = ErrorMapper.toFailure(TimeoutException('x'));
      expect(f.category, ErrorCategory.networkTimeout);
      expect(f.message, contains('too long'));
      expect(
        ErrorMapper.classify(const SocketException('Connection timed out',
            osError: OSError('Connection timed out', 110))),
        ErrorCategory.networkTimeout,
      );
    });

    test('a refused connection is the server, not the phone', () {
      expect(
        ErrorMapper.classify(const SocketException('Connection refused',
            osError: OSError('Connection refused', 111))),
        ErrorCategory.serverUnavailable,
      );
    });

    test('a TLS handshake failure (captive Wi-Fi) is a connection problem', () {
      expect(ErrorMapper.classify(const HandshakeException('Handshake error in client')),
          ErrorCategory.networkOffline);
    });

    test('5xx is "Help24 is temporarily unavailable"', () {
      for (final status in [500, 502, 503, 504]) {
        final f = ErrorMapper.toFailure(_ApiError('Internal server error', status));
        expect(f.category, ErrorCategory.serverUnavailable, reason: '$status');
        expect(f.message, 'Help24 is temporarily unavailable. Please try again in a moment.');
      }
    });

    test('401 is the session, 403 is permission — different problems', () {
      final signIn = ErrorMapper.toFailure(_ApiError('Your session could not be verified.', 401));
      expect(signIn.category, ErrorCategory.authentication);
      expect(signIn.message, 'Your session has expired. Please sign in again.');

      final forbidden = ErrorMapper.toFailure(_ApiError('Requires role super_admin', 403));
      expect(forbidden.category, ErrorCategory.authorization);
      expect(forbidden.message, "You don't have permission to do that.");
    });

    test('404 with an id in the text still reads as not found', () {
      final f = ErrorMapper.toFailure(
          _ApiError('Campaign 3f2a1b4c-1234-4abc-9def-001122334455 not found.', 404));
      expect(f.category, ErrorCategory.notFound);
      expect(f.message, "We couldn't find this. It may have been removed.");
    });

    test('429 asks the user to slow down', () {
      final f = ErrorMapper.toFailure(_ApiError('ThrottlerException: Too Many Requests', 429));
      expect(f.category, ErrorCategory.rateLimited);
      expect(f.message, contains('a little too quickly'));
    });

    test('validation: a sentence for the user is kept, a field name is not', () {
      final kept = ErrorMapper.toFailure(
          _ApiError('Only open, visible listings can be promoted.', 400),
          context: ErrorContext.payment);
      expect(kept.message, 'Only open, visible listings can be promoted.');
      expect(kept.category, ErrorCategory.validation);

      final replaced = ErrorMapper.toFailure(_ApiError('post_id must be a UUID', 400),
          context: ErrorContext.save);
      expect(replaced.message, 'Please check the details and try again.');
      expect(replaced.category, ErrorCategory.validation);

      // After a tap with nothing typed, "check the details" would be advice
      // about details that do not exist — the action's sentence is used.
      final onDelete = ErrorMapper.toFailure(_ApiError('user_id is required.', 400),
          context: ErrorContext.delete);
      expect(onDelete.message, "We couldn't remove this. Please try again.");
    });

    test('unknown and programming errors get the safe generic sentence', () {
      for (final e in [
        Exception('boom'),
        StateError('No element'),
        _typeError(),
        const FormatException('Unexpected character (at character 1)', '<!DOCTYPE html>'),
        Object(),
      ]) {
        final f = ErrorMapper.toFailure(e);
        expect(f.message, 'Something went wrong. Please try again.', reason: '$e');
      }
    });

    test('Supabase: RLS, gateway pages, duplicates and the name cooldown', () {
      expect(
        ErrorMapper.toFailure(const PostgrestException(
                message: 'new row violates row-level security policy for table "posts"',
                code: '42501'))
            .category,
        ErrorCategory.authorization,
      );
      expect(
        ErrorMapper.toFailure(const PostgrestException(
                message: '<html><body>502 Bad Gateway</body></html>', code: '502'))
            .category,
        ErrorCategory.serverUnavailable,
      );
      expect(
        ErrorMapper.toFailure(const PostgrestException(
                message: 'duplicate key value violates unique constraint "x"', code: '23505'))
            .category,
        ErrorCategory.conflict,
      );
      // Raised by the migration-087 trigger as a check_violation. It used to
      // fall through to "We couldn't save your changes".
      final cooldown = ErrorMapper.toFailure(
        // The exact shape migration 087 raises.
        const PostgrestException(
            message: 'HELP24_NAME_COOLDOWN: name can change again after 2026-10-20 10:00:00+00',
            code: '23514'),
        context: ErrorContext.save,
      );
      expect(cooldown.title, 'Name recently changed');
    });

    test('Supabase storage and auth', () {
      expect(ErrorMapper.toFailure(const StorageException('Payload too large', statusCode: '413')).title,
          'File too large');
      expect(
        ErrorMapper.toFailure(const StorageException(
                'new row violates row-level security policy', statusCode: '403'))
            .message,
        "We couldn't upload your image. Please try again.",
      );
      // gotrue wraps a dead connection during token refresh in its own class.
      expect(
        ErrorMapper.classify(AuthRetryableFetchException(
            message: "ClientException with SocketException: Failed host lookup: 'x.supabase.co'")),
        ErrorCategory.networkOffline,
      );
      expect(ErrorMapper.classify(const AuthException('JWT expired', statusCode: '401')),
          ErrorCategory.authentication);
    });

    test('Firebase: the identity mapper\'s words, never the provider\'s', () {
      final offline = ErrorMapper.toFailure(
          FirebaseAuthException(code: 'network-request-failed', message: 'A network error…'));
      expect(offline.category, ErrorCategory.networkOffline);

      final disabled = ErrorMapper.toFailure(FirebaseAuthException(
          code: 'user-disabled',
          message: 'The user account has been disabled by an administrator.'));
      expect(disabled.message, isNot(contains('administrator')));
      expect(disabled.category, ErrorCategory.authentication);

      final push = ErrorMapper.toFailure(FirebaseException(
          plugin: 'firebase_messaging',
          code: 'unknown',
          message: 'java.io.IOException: SERVICE_NOT_AVAILABLE'));
      expect(push.category, ErrorCategory.networkOffline);
    });

    test('platform plugins: offline when it is, never their prose', () {
      expect(ErrorMapper.classify(PlatformException(code: 'network_error')),
          ErrorCategory.networkOffline);
      final picker = ErrorMapper.toFailure(
          PlatformException(code: 'already_active', message: 'Image picker is already active'),
          context: ErrorContext.upload);
      expect(picker.message, "We couldn't upload your image. Please try again.");
    });

    test('the offline photo-upload sentence reaches the user as written', () {
      // StorageService turns a transport failure into this authored sentence
      // (found on a device: the old one dropped the cause and only said
      // "please try again"). It must survive the mapper unchanged.
      const sentence =
          "We couldn't upload your photo. Check your internet connection and try again.";
      expect(ErrorMapper.toMessage(_WrappingError(sentence), context: ErrorContext.upload),
          sentence);
    });

    test('a wrapped transport failure is still recognised', () {
      final f = ErrorMapper.toFailure(
        _WrappingError('Failed to create post: ${_productionError()}'),
        context: ErrorContext.save,
      );
      expect(f.category, ErrorCategory.networkOffline);
      expect(f.message, "We couldn't save your changes. Check your internet connection and try again.");
    });
  });

  group('publishing a new listing names what was being posted', () {
    test('offline: request, offer and job each say which one', () {
      expect(
        ErrorMapper.toMessage(_productionError(),
            context: PostType.request.newPostErrorContext),
        "We couldn't post your request. Check your internet connection and try again.",
      );
      expect(
        ErrorMapper.toMessage(_productionError(), context: PostType.offer.newPostErrorContext),
        "We couldn't post your offer. Check your internet connection and try again.",
      );
      expect(
        ErrorMapper.toMessage(_productionError(), context: PostType.job.newPostErrorContext),
        "We couldn't post your job. Check your internet connection and try again.",
      );
    });

    test('never "save your changes" for something that did not exist yet', () {
      for (final type in PostType.values) {
        for (final error in [_productionError(), Object(), _ApiError('x', 503)]) {
          final message =
              ErrorMapper.toMessage(error, context: type.newPostErrorContext);
          expect(message.toLowerCase(), isNot(contains('save your changes')),
              reason: '$type / $error');
        }
      }
      expect(ErrorMapper.toMessage(Object(), context: ErrorContext.createOffer),
          "We couldn't post your offer. Please try again.");
    });

    test('an edit still says "save your changes"', () {
      expect(ErrorMapper.toMessage(_productionError(), context: ErrorContext.save),
          "We couldn't save your changes. Check your internet connection and try again.");
    });

    test('the posting slot round-trips: AppProvider maps, PostScreen re-maps', () {
      // AppProvider stores the mapped sentence; PostScreen re-throws it as
      // Exception(message) and maps again — the wording must survive.
      final stored =
          ErrorMapper.toMessage(_productionError(), context: ErrorContext.createOffer);
      expect(
          ErrorMapper.toMessage(Exception(stored), context: ErrorContext.createOffer), stored);
    });

    test('the post screen and AppProvider both use the type\'s context', () {
      final screen = File('lib/screens/post_screen.dart').readAsStringSync();
      final provider = File('lib/providers/app_provider.dart').readAsStringSync();
      expect(screen.contains('.newPostErrorContext'), isTrue);
      expect(provider.contains('post.type.newPostErrorContext'), isTrue);
      expect(provider.contains('context: ErrorContext.createJob'), isTrue);
    });
  });

  group('business errors are never reported as "you\'re offline"', () {
    test('a server sentence that mentions a timeout is the server talking', () {
      final f = ErrorMapper.toFailure(
          _ApiError('The M-Pesa request timed out before the PIN was entered.', 400),
          context: ErrorContext.payment);
      expect(f.isOffline, isFalse);
    });

    test('M-Pesa\'s own "DS timeout" is a payment failure', () {
      expect(ErrorMapper.isConnectivityError(Exception('DS timeout user cannot be reached')),
          isFalse);
    });

    test('validation, permission, payment and auth refusals keep their category', () {
      expect(ErrorMapper.classify(_ApiError('Invalid OTP code.', 400)), ErrorCategory.validation);
      expect(ErrorMapper.classify(_ApiError('You can only promote your own listings.', 403)),
          ErrorCategory.authorization);
      expect(ErrorMapper.classify(_ApiError('Payment required', 402)), ErrorCategory.payment);
      expect(ErrorMapper.classify(_ApiError('Your session could not be verified.', 401)),
          ErrorCategory.authentication);
    });

    test('"No provider has been selected" is not "a provider was already chosen"', () {
      final f = ErrorMapper.toFailure(
          _ApiError('No provider has been selected for this post.', 400));
      expect(f.message, isNot('This job already has a chosen provider.'));
      expect(f.message, 'No provider has been selected for this post.');

      final g = ErrorMapper.toFailure(
          _ApiError('Only the selected provider can mark this job as done.', 403));
      expect(g.message, isNot('This job already has a chosen provider.'));
    });

    test('"already in progress" is not "already paid"', () {
      final f = ErrorMapper.toFailure(
          _ApiError('A payment is already in progress for this service.', 409));
      expect(f.message, isNot('This has already been paid for.'));
    });

    test('the backend\'s truthful settlement sentence is kept', () {
      const sentence = 'Funds are currently held. Resolve or complete the job before removing it.';
      final f = ErrorMapper.toFailure(_ApiError(sentence, 409), context: ErrorContext.delete);
      expect(f.message, sentence);
    });
  });

  group('mapping is idempotent', () {
    test('every sentence the mapper can produce maps to itself', () {
      final produced = <String>{
        for (final context in ErrorContext.values) ...[
          ErrorMapper.toMessage(_productionError(), context: context),
          ErrorMapper.toMessage(TimeoutException('x'), context: context),
          ErrorMapper.toMessage(_ApiError('x', 503), context: context),
          ErrorMapper.toMessage(Object(), context: context),
        ],
        ErrorMapper.toMessage(_ApiError('x', 401)),
        ErrorMapper.toMessage(_ApiError('x', 403)),
        ErrorMapper.toMessage(_ApiError('HELP24_ACCOUNT_RESTRICTED: suspended', 403)),
      };
      for (final message in produced) {
        // AppProvider re-throws its posting slot as Exception(message), and
        // PostScreen maps it again.
        expect(ErrorMapper.toMessage(Exception(message), context: ErrorContext.save), message,
            reason: 'mapping "$message" twice changed it');
      }
    });
  });

  group('no mapped message ever leaks — every error × every context', () {
    final corpus = <Object?>[
      _productionError(),
      const SocketException("Failed host lookup: 'api.help24.co.ke'",
          osError: OSError('No address associated with hostname', 7)),
      TimeoutException('after 0:00:30.000000: Future not completed'),
      const HandshakeException('Handshake error in client'),
      const PostgrestException(
          message: 'new row violates row-level security policy for table "posts"', code: '42501'),
      const PostgrestException(message: '<html>502 Bad Gateway</html>', code: '502'),
      const PostgrestException(message: 'JWT expired', code: 'PGRST303'),
      const FormatException('Unexpected character (at character 1)', '<!DOCTYPE html>'),
      _typeError(),
      StateError('No element'),
      _ApiError("Cannot read properties of null (reading 'author_user_id')", 500),
      _ApiError('post_id must be a UUID', 400),
      _ApiError('Campaign 3f2a1b4c-1234-4abc-9def-001122334455 not found.', 404),
      _ApiError('duplicate key value violates unique constraint "promotion_campaigns_pkey"', 400),
      _ApiError('Configuration key "MPESA_PASSKEY" does not exist', 400),
      _ApiError('[Daraja] STK push failed — HTTP 500: {"errorCode":"500.001.1001"}', 400),
      _ApiError('STK push rejected by Daraja: Invalid Access Token', 400),
      _ApiError('Force-success is not available in production.', 400),
      _ApiError('The identity in this request does not match the authenticated user.', 403),
      _ApiError('Failed to create transaction: TypeError: fetch failed', 500),
      _ApiError('raised_by_role does not match your relationship to this job.', 400),
      _ApiError('Could not create an upload URL.', 400),
      _WrappingError('Failed to create post: PostgrestException(message: x, code: 23502)'),
      _WrappingError("Failed to get post: type 'int' is not a subtype of type 'String'"),
      _WrappingError('A users row needs an id.'),
      _WrappingError('Cannot create chat with empty participant id'),
      FirebaseAuthException(code: 'internal-error', message: 'An internal error has occurred. [ x ]'),
      FirebaseAuthException(
          code: 'missing-client-identifier',
          message: 'This request is missing a valid app identifier, meaning that Play Integrity '
              'checks and reCAPTCHA checks were unsuccessful.'),
      FirebaseException(plugin: 'cloud_firestore', code: 'unavailable', message: 'The service is unavailable'),
      PlatformException(code: 'NotEnrolled', message: 'No Biometrics enrolled on this device.'),
      PlatformException(code: 'NO_ACTIVITY', message: 'Launching a URL requires a foreground activity.'),
      Exception('Unable to open https://help24.co.ke/help'),
      'new row violates row-level security policy for table "posts"',
      const StorageException('The resource was not found', statusCode: '404'),
      null,
    ];

    for (final error in corpus) {
      test('$error', () {
        for (final context in ErrorContext.values) {
          final f = ErrorMapper.toFailure(error, context: context);
          _expectFailureClean(f, because: '${context.name}: $error');
          expect(ErrorMapper.isUserSafe(f.message), isTrue);
        }
      });
    }
  });

  group('M-Pesa failures, in words for the person paying', () {
    test('Daraja result text is recognised, never shown', () {
      const cases = {
        'Request cancelled by user': 'You cancelled',
        'The initiator information is invalid.': 'PIN entered was incorrect',
        'The balance is insufficient for the transaction.': 'balance',
        'Unable to lock subscriber, a transaction is already in process for the current subscriber':
            'Another M-Pesa payment',
        'DS timeout user cannot be reached': "couldn't reach your phone",
      };
      cases.forEach((raw, expected) {
        final copy = MpesaFailureCopy.forResult(raw);
        expect(copy, contains(expected), reason: raw);
        expect(copy, isNot(contains(raw)), reason: raw);
        _expectClean(copy, because: raw);
      });
    });

    test('server faults stored as the failure reason are not shown', () {
      for (final raw in [
        '[Daraja] STK push failed — HTTP 500: {"requestId":"x","errorCode":"500.001.1001"}',
        'Configuration key "MPESA_PASSKEY" does not exist',
        null,
        '',
      ]) {
        expect(MpesaFailureCopy.forResult(raw), MpesaFailureCopy.notCompleted);
        _expectClean(MpesaFailureCopy.summary(raw), because: '$raw');
      }
    });

    test('starting a payment: the right party, the right state', () {
      expect(
        MpesaFailureCopy.forInitiation(_ApiError(
            "The selected provider hasn't added their M-Pesa number yet. Ask them to update their profile.",
            400)),
        contains('The provider'),
      );
      expect(
        MpesaFailureCopy.forInitiation(
            _ApiError('Please add your M-Pesa number to your profile to make payments.', 400)),
        contains('Profile → Payment Number'),
      );
      expect(
        MpesaFailureCopy.forInitiation(_ApiError(
            'A payment is already in progress — check your phone for the M-Pesa prompt.', 409)),
        contains('already in progress'),
      );
      expect(
        MpesaFailureCopy.forInitiation(_productionError()),
        'Payment could not be started. Check your internet connection and try again.',
      );
      expect(
        MpesaFailureCopy.forInitiation(TimeoutException('x')),
        contains('If an M-Pesa prompt appears'),
      );
      final notFound = MpesaFailureCopy.forInitiation(
          _ApiError('Post 3f2a1b4c-1234-4abc-9def-001122334455 not found.', 404));
      _expectClean(notFound, because: 'start payment 404');
    });
  });
}
