import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, FunctionException, PostgrestException, StorageException;

import '../models/post_model.dart' show PostType;
import '../services/auth_service.dart' show ProfileUnavailableException;
import 'auth_error_mapper.dart';

/// What KIND of thing went wrong, independent of how it is worded.
///
/// The wording a user reads is chosen from the category AND the [ErrorContext]
/// (what they were doing), so the same offline failure reads "Your message
/// couldn't be sent" in a chat and "You're offline" on a list. The category is
/// what code branches on — whether to offer Retry, whether recovery on
/// reconnect is worth waiting for — and what tests assert, so a wording change
/// can never silently turn "the server refused" into "you are offline".
enum ErrorCategory {
  /// No usable connection: no network, a DNS failure, a connection dropped
  /// mid-request, a captive-portal TLS failure.
  networkOffline,

  /// The round trip started but did not finish in time.
  networkTimeout,

  /// Help24 is reachable in principle but is not serving: a 5xx, a refused
  /// connection, a database statement cancelled for running too long.
  serverUnavailable,

  /// The session is over — a 401, an expired or unreadable token.
  authentication,

  /// The caller is known and still not allowed — a 403, row-level security.
  authorization,

  /// A Trust & Safety restriction on the account (a specific kind of 403).
  accountRestricted,

  /// The server rejected what was sent — a 400/422, a check constraint, or a
  /// product rule such as "you can't apply to your own post".
  validation,

  /// A 404, or a single-row read that found nothing.
  notFound,

  /// The thing already happened or the state moved on — a 409, a unique
  /// violation, "a provider was already chosen".
  conflict,

  /// A 429 — slow down.
  rateLimited,

  /// A payment could not be started or was refused.
  payment,

  /// A Firebase service failed for a reason not covered above.
  firebase,

  /// Supabase (database, storage, functions) failed for a reason not covered
  /// above.
  database,

  /// Anything else — including programming errors, which are never shown.
  unknown,
}

/// A human-first description of a failure, following the product rule that a
/// user should always understand: what happened ([title]), and what to do next
/// ([message]). Never contains exception class names, backend URLs, HTTP status
/// codes, socket/DNS wording or any other implementation detail —
/// [ErrorMapper.toFailure] refuses to return one that does.
@immutable
class AppFailure {
  /// Short headline — "You're offline", "We couldn't load this".
  final String title;

  /// One reassuring, actionable sentence that stands on its own — this is the
  /// string a snackbar shows, with no title above it.
  final String message;

  /// What kind of failure this is. See [ErrorCategory].
  final ErrorCategory category;

  /// [message] without its headline, for surfaces that render [title] above it
  /// ([ErrorRetryView.fromError]). Null when [message] already reads well
  /// under the title. Exists so "You're offline" is not followed by
  /// "You're offline. Check your internet connection…".
  final String? detail;

  const AppFailure({
    required this.title,
    required this.message,
    this.category = ErrorCategory.unknown,
    this.detail,
  });

  /// True when the failure is a connectivity problem (offline / timeout).
  /// Screens use this to show the offline treatment, and to know that
  /// automatic recovery on reconnect is worth waiting for.
  bool get isOffline =>
      category == ErrorCategory.networkOffline ||
      category == ErrorCategory.networkTimeout;

  /// True when simply trying again, unchanged, can succeed — the cases where a
  /// Retry button is an honest offer rather than a way to fail twice.
  bool get isRetryable =>
      isOffline || category == ErrorCategory.serverUnavailable;

  /// The sentence to show beneath [title].
  String get body => detail ?? message;
}

/// Where the failure happened, so the mapper can pick the most reassuring
/// "what to do next" wording. Only affects context-dependent copy — auth,
/// restrictions and known domain errors are mapped the same everywhere.
enum ErrorContext {
  generic,
  loadFeed,
  loadContent,
  save,
  apply,
  selectProvider,
  upload,
  payment,
  auth,
  sendMessage,
  location,

  /// Removing something the user owns — a post, a listing.
  delete,

  /// Publishing a NEW listing, by type. Distinct from [save]: "We couldn't
  /// save your changes" is the sentence for an edit, and read wrong to
  /// someone who had just tapped "Post Now" on something that did not exist
  /// yet (seen on a device, offline). Choose with [ErrorContextForNewPost].
  createRequest,
  createOffer,
  createJob,
}

/// The [ErrorContext] for publishing a new listing of this type — one mapping,
/// shared by the post screen and AppProvider so their wording cannot drift.
extension ErrorContextForNewPost on PostType {
  ErrorContext get newPostErrorContext => switch (this) {
        PostType.request => ErrorContext.createRequest,
        PostType.offer => ErrorContext.createOffer,
        PostType.job => ErrorContext.createJob,
      };
}

/// The single production-grade translation layer between raw failures and the
/// UI. Every failure that reaches the screen — a `catch`, a FutureBuilder's
/// `snapshot.error`, a stream's `onError` — routes through here instead of
/// interpolating `$e`, calling `e.toString()`, or forwarding a backend body.
///
/// WHY THE RULE IS "EVERY FAILURE", NOT "EVERY CATCH"
/// --------------------------------------------------
/// The first audit enforced this on `catch` blocks, and Promote Business still
/// showed users
///
///   ClientException with SocketException: Failed host lookup:
///   'api.help24.co.ke' (OS Error: No address associated with hostname …)
///
/// because the failure never passed through a `catch` in app code at all: a
/// FutureBuilder caught it, and the screen rendered `'${snap.error}'`. This
/// mapper already knew that exact exception was "offline" — nothing asked it.
/// The rule is about the VALUE, wherever it is caught. `ErrorRetryView.fromError`
/// takes the raw error so a failure view cannot be built from raw text, and
/// test/error_exposure_test.dart fails the build on the patterns that bypass it.
///
/// Design rules:
///   1. Never leak. Output is checked against [isUserSafe] on the way out; a
///      message that fails is replaced by the context fallback, so no future
///      branch — however it is written — can put technical text on screen.
///   2. Classify transport failures only when no response arrived. A server
///      sentence that happens to say "timeout" is the server talking, not the
///      network failing; business errors must never read as "you're offline".
///   3. Classify by type (platform, Firebase, Supabase), then by Help24's own
///      markers and known rules, then by status. A short, sentence-shaped
///      server message with no technical vocabulary may be shown as written —
///      it is usually the most specific explanation available.
///   4. Log the real error via [debugPrint] with a layer tag ([NETWORK],
///      [SUPABASE], [FIREBASE], [API], [AUTH], [PAYMENT]) so engineers keep the
///      detail the user must never see.
class ErrorMapper {
  ErrorMapper._();

  /// Called when a failure turns out to be an account restriction — wired at
  /// startup to refresh AccountStatusStore, so the banner and the gates catch
  /// up with what the server just enforced. Kept as a hook so this file stays
  /// free of service imports.
  static void Function()? onAccountRestricted;

  // ─── Public API ────────────────────────────────────────────────────────────

  /// The friendly one-line message for [error]. Drop-in replacement for every
  /// `'Failed to …: $e'` string. Pass [context] to tailor the wording.
  static String toMessage(
    Object? error, {
    ErrorContext context = ErrorContext.generic,
    StackTrace? stackTrace,
  }) =>
      toFailure(error, context: context, stackTrace: stackTrace).message;

  /// The structured [AppFailure] (title + message + category) for [error].
  static AppFailure toFailure(
    Object? error, {
    ErrorContext context = ErrorContext.generic,
    StackTrace? stackTrace,
  }) {
    final failure = _map(error, context);
    // Always log the true cause; the user only ever sees the mapped result.
    _log(error, context, failure.category, stackTrace);

    if (failure.category == ErrorCategory.accountRestricted) {
      final hook = onAccountRestricted;
      if (hook != null) scheduleMicrotask(hook);
    }

    // The last line of defence. Every branch above is written to produce safe
    // copy; this makes it a property of the function rather than of each
    // branch, so a future edit cannot leak by mistake.
    final detail = failure.detail;
    if (!isUserSafe(failure.title) ||
        !isUserSafe(failure.message) ||
        (detail != null && !isUserSafe(detail))) {
      debugPrint('[ErrorMapper][BLOCKED] unsafe copy replaced: '
          '"${failure.title}" / "${failure.message}"');
      return _fallback(context, failure.category);
    }
    return failure;
  }

  /// The [ErrorCategory] of [error], without logging or side effects.
  static ErrorCategory classify(Object? error) =>
      _map(error, ErrorContext.generic).category;

  /// Whether [error] is purely a connectivity problem (offline / timeout).
  /// Useful for deciding on offline UI and auto-retry-on-reconnect.
  static bool isConnectivityError(Object? error) {
    final category = classify(error);
    return category == ErrorCategory.networkOffline ||
        category == ErrorCategory.networkTimeout;
  }

  /// False when [text] carries anything a Help24 user must never read:
  /// exception names, socket/DNS wording, backend hosts, vendor names, SQL or
  /// row-level-security vocabulary, Dart type errors. Applied to every mapped
  /// result, and usable by any surface that must decide whether a string it
  /// did not author may be displayed.
  ///
  /// Deliberately narrower than [_technical] (which guards server text passed
  /// through verbatim): this one must also accept Help24's own authored copy,
  /// such as the restriction notices and the auth mapper's support pointer.
  static bool isUserSafe(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    return !_neverShow.hasMatch(text);
  }

  // ─── Classification ─────────────────────────────────────────────────────────

  static AppFailure _map(Object? error, ErrorContext context) {
    if (error == null) return _fallback(context);

    final status = _statusCodeOf(error);

    // 1) Transport — the most common real-world failure. Only when no HTTP
    //    status arrived: a response, whatever its text, means the network
    //    worked, and a validation or payment refusal must never be reported
    //    as "you're offline".
    if (status == null) {
      final transport = _transportCategory(error);
      if (transport != null) return _connectivity(transport, context);
    } else if (status == 408) {
      return _connectivity(ErrorCategory.networkTimeout, context);
    }

    // 2) Programming errors and malformed data: a TypeError, a
    //    NoSuchMethodError, a FormatException from decoding an HTML error page.
    //    Their text is always implementation detail and never a reason the
    //    user can act on.
    if (error is Error || error is FormatException) {
      return _fallback(context);
    }

    // 3) Firebase and platform channels.
    if (error is FirebaseAuthException) return _fromFirebaseAuth(error, context);
    if (error is FirebaseException) return _fromFirebase(error, context);
    if (error is PlatformException) return _fromPlatform(error, context);

    // 4) The account has no Help24 profile row, so an owned write cannot go
    //    ahead. Raised BEFORE the write, by AuthService.ensureCurrentUserInSupabase,
    //    which is the last place the real reason is still known — after it, the
    //    same situation arrives as a foreign-key violation and reads as a
    //    saving problem rather than an account one. The message is authored at
    //    the raise site and shown as written.
    if (error is ProfileUnavailableException) {
      return AppFailure(
        title: "We couldn't set up your account",
        message: error.message,
        category: ErrorCategory.authentication,
      );
    }

    // 5) A Trust & Safety restriction, refused by the database (migration
    //    116, SQLSTATE 42501) or by the backend (ModerationGuard, 403). Before
    //    the permission branches below, which would otherwise read it as "you
    //    don't have permission" — true, and useless: the person needs to know
    //    their ACCOUNT is restricted, and where to see why.
    final restricted = _restrictionFailure(error);
    if (restricted != null) return restricted;

    // 6) Session.
    if (_looksLikeExpiredSession(error)) return _session;

    // 7) The server answered, and the answer was a failure of its own.
    if (status != null && status >= 500) return _serverUnavailable;

    // 8) Supabase SDK exceptions. Their messages are Postgres / PostgREST /
    //    storage prose and are never shown; only Help24's own markers inside
    //    them are read.
    if (error is AuthException) return _session;
    if (error is StorageException) return _fromStorage(status);
    if (error is PostgrestException) return _fromPostgrest(error, status, context);
    if (error is FunctionException) {
      return (status == null ? null : _fromStatus(status, context)) ??
          _fallback(context, ErrorCategory.database);
    }

    // 9) Help24's own exceptions (JobsException, PromotionException, …) and
    //    plain strings. These may carry the backend's `message`.
    final raw = _rawMessageOf(error);
    // Mapping is idempotent: a message this mapper already produced maps to
    // itself. Screens that re-throw a mapped message (post creation does,
    // through AppProvider's posting slot) must not have "You're offline…"
    // degraded to generic copy by being mapped a second time.
    final own = _authored[raw?.trim()];
    if (own != null) return own;
    final rule = _knownRule(raw);
    if (rule != null) return rule;
    if (status == 401) return _session;
    if (status == 429) return _rateLimited;
    if (_isPresentable(raw)) {
      // The backend writes most refusals as sentences for the user ("Only
      // open, visible listings can be promoted."), and that sentence is more
      // specific than anything the status code alone could say.
      return AppFailure(
        title: _titleForStatus(status) ?? _fallback(context).title,
        message: raw!.trim(),
        category: _categoryForStatus(status) ?? _contextCategory(context),
      );
    }
    final guess = _keywordGuess(raw);
    if (guess != null) return guess;
    if (status != null) return _fromStatus(status, context) ?? _fallback(context);
    return _fallback(context);
  }

  /// The transport category of [error], or null when it is not a transport
  /// failure. Recognises the exception types directly and, for Help24's own
  /// service exceptions that embed the original failure in their text (by
  /// design: `PostServiceException('Failed to create post: $e')` keeps `$e`
  /// precisely so this can still tell offline from refused), by the transport
  /// signature in that text.
  static ErrorCategory? _transportCategory(Object error) {
    if (error is TimeoutException) return ErrorCategory.networkTimeout;
    final text = error.toString().toLowerCase();
    // package:http's IOClient throws a ClientException that also IMPLEMENTS
    // SocketException — the exact object Promote Business rendered.
    if (error is SocketException ||
        error is ClientException ||
        error is HttpException ||
        error is TlsException ||
        error is WebSocketException) {
      return _signatureCategory(text) ?? ErrorCategory.networkOffline;
    }
    return _signatureCategory(text);
  }

  static ErrorCategory? _signatureCategory(String text) {
    // Order matters: "SocketException: Connection timed out" is a timeout and
    // "SocketException: Connection refused" is a server that is not listening,
    // though both also carry the generic socket signature.
    if (_timeoutSignatures.any(text.contains)) return ErrorCategory.networkTimeout;
    if (_refusedSignatures.any(text.contains)) return ErrorCategory.serverUnavailable;
    if (_offlineSignatures.any(text.contains)) return ErrorCategory.networkOffline;
    return null;
  }

  /// Transport signatures only — never bare words like "timeout" or
  /// "network", which a server or M-Pesa sentence can legitimately contain
  /// ("DS timeout user cannot be reached" is a payment failure, not the app
  /// being offline).
  // An errno is matched WITH the ")" that closes it in SocketException's text
  // ("(OS Error: …, errno = 110)"). As a bare prefix, "errno = 110" also
  // matched Windows' DNS failure "errno = 11001", and a failed host lookup
  // was reported as a timeout — found by making package:http fail for real
  // (test/error_mapper_transport_test.dart).
  static const _timeoutSignatures = <String>[
    'timeoutexception',
    'future not completed',
    'connection timed out',
    'errno = 110)',
  ];

  static const _refusedSignatures = <String>[
    'connection refused',
    'errno = 111)',
    'errno = 61)',
  ];

  static const _offlineSignatures = <String>[
    'failed host lookup',
    'no address associated with hostname',
    'nodename nor servname',
    'network is unreachable',
    'no route to host',
    'software caused connection abort',
    'connection reset',
    'connection closed',
    'connection aborted',
    'broken pipe',
    'socketexception',
    'clientexception',
    'handshakeexception',
    'httpexception',
    'service_not_available',
  ];

  static AppFailure _fromFirebaseAuth(FirebaseAuthException e, ErrorContext context) {
    final code = e.code;
    if (code == 'network-request-failed') {
      return _connectivity(ErrorCategory.networkOffline, context);
    }
    // The identity mapper owns this vocabulary and never returns provider
    // prose; this only carries its copy across with a category attached.
    final auth = AuthErrorMapper.toFailure(e);
    final category = switch (code) {
      'too-many-requests' || 'quota-exceeded' => ErrorCategory.rateLimited,
      'user-token-expired' ||
      'invalid-user-token' ||
      'requires-recent-login' ||
      'user-disabled' =>
        ErrorCategory.authentication,
      _ when code.startsWith('invalid-') ||
          code.startsWith('missing-') ||
          code == 'weak-password' =>
        ErrorCategory.validation,
      _ => ErrorCategory.firebase,
    };
    return AppFailure(title: auth.title, message: auth.message, category: category);
  }

  static AppFailure _fromFirebase(FirebaseException e, ErrorContext context) {
    switch (e.code) {
      case 'unavailable':
      case 'network-request-failed':
        return _connectivity(ErrorCategory.networkOffline, context);
      case 'deadline-exceeded':
        return _connectivity(ErrorCategory.networkTimeout, context);
      case 'permission-denied':
        return _forbidden;
      case 'unauthenticated':
        return _session;
      case 'not-found':
        return _notFound;
      case 'resource-exhausted':
      case 'too-many-requests':
      case 'quota-exceeded':
        return _rateLimited;
    }
    final text = '${e.code} ${e.message ?? ''}'.toLowerCase();
    final transport = _signatureCategory(text);
    if (transport != null) return _connectivity(transport, context);
    return _fallback(context, ErrorCategory.firebase);
  }

  static AppFailure _fromPlatform(PlatformException e, ErrorContext context) {
    final text = '${e.code} ${e.message ?? ''}'.toLowerCase();
    // google_sign_in reports a dead connection as code `network_error`, or as
    // `sign_in_failed` carrying "ApiException: 7" (NETWORK_ERROR).
    if (text.contains('network') || text.contains('apiexception: 7')) {
      return _connectivity(ErrorCategory.networkOffline, context);
    }
    final transport = _signatureCategory(text);
    if (transport != null) return _connectivity(transport, context);
    return _fallback(context);
  }

  static AppFailure _fromStorage(int? status) {
    if (status == 413) return _tooLarge;
    return _fallback(ErrorContext.upload, ErrorCategory.database);
  }

  static AppFailure _fromPostgrest(
    PostgrestException error,
    int? status,
    ErrorContext context,
  ) {
    // Checked before the generic branches: the self-application trigger
    // (migration 030) raises a check_violation whose message is the rule
    // itself, and the name-cooldown trigger (087) raises with its own marker.
    // Without this they fell through to the context fallback and read as a
    // network or saving failure for an action that is simply not allowed.
    final rule = _knownRule(error.message);
    if (rule != null) return rule;
    // PostgREST reports a non-JSON failure (a gateway's HTML page) with the
    // HTTP status as its code.
    if (status != null) {
      return _fromStatus(status, context) ??
          _fallback(context, ErrorCategory.database);
    }
    final code = error.code ?? '';
    if (_isUniqueViolation(code, error.message)) return _conflict;
    if (code == '42501' || _mentionsPermission(error.message)) return _forbidden;
    if (code == 'PGRST116') return _notFound;
    if (code == '57014') return _serverUnavailable; // statement timeout
    if (code == '23514') return _validationFor(context);
    return _fallback(context, ErrorCategory.database);
  }

  static AppFailure? _fromStatus(int status, ErrorContext context) {
    if (status >= 500) return _serverUnavailable;
    switch (status) {
      // 401 and 403 are DIFFERENT problems and were once answered with the
      // same sentence. Since the backend began enforcing authentication, 401
      // is reachable in normal use — a session that ended while the app was
      // backgrounded, an account signed out on another device — and telling
      // someone they "don't have permission" when the real answer is "sign in
      // again" sends them looking for a permissions problem that does not
      // exist. The client already retries once on TOKEN_EXPIRED (see
      // api_client.dart), so a 401 that reaches here has survived a token
      // refresh and genuinely means the session is over.
      case 401:
        return _session;
      // 403 is the real authorization answer: the caller is known and still
      // not allowed — including the identity-conflict case, where the request
      // named someone other than the signed-in user.
      case 403:
        return _forbidden;
      case 400:
      case 422:
        return _validationFor(context);
      case 402:
        return _fallback(ErrorContext.payment);
      case 404:
      case 410:
        return _notFound;
      case 408:
        return _connectivity(ErrorCategory.networkTimeout, context);
      case 409:
        return _conflict;
      case 413:
        return _tooLarge;
      case 429:
        return _rateLimited;
    }
    return null; // Other 4xx → the context fallback decides.
  }

  // ─── Help24's own markers and rules ─────────────────────────────────────────

  /// The four restriction refusals, recognised by their machine marker (the
  /// database's `HELP24_ACCOUNT_RESTRICTED: <denial>`) or by the backend's
  /// sentence — every one of which ends "Open Account status in the app…"
  /// (RESTRICTION_MESSAGES in backend/src/moderation/moderation.guard.ts).
  static AppFailure? _restrictionFailure(Object? error) {
    final raw = (_rawMessageOf(error) ?? '').toLowerCase();
    if (raw.isEmpty) return null;
    final String? denial;
    final marker = RegExp(r'help24_account_restricted:\s*([a-z_]+)').firstMatch(raw);
    if (marker != null) {
      denial = marker.group(1);
    } else if (raw.contains('open account status in the app')) {
      denial = raw.contains('banned')
          ? 'banned'
          : raw.contains('suspended')
              ? 'suspended'
              : raw.contains('send messages')
                  ? 'messaging_restricted'
                  : 'marketplace_restricted';
    } else {
      return null;
    }
    return switch (denial) {
      'banned' => _banned,
      'suspended' => _suspended,
      'messaging_restricted' => _messagingRestricted,
      _ => _marketplaceRestricted,
    };
  }

  static const AppFailure _banned = AppFailure(
    title: 'Account banned',
    message: 'Your Help24 account has been banned. Open Account status in your profile to see why and how to appeal.',
    category: ErrorCategory.accountRestricted,
  );

  static const AppFailure _suspended = AppFailure(
    title: 'Account suspended',
    message: 'Your account is suspended right now. Open Account status in your profile to see when it ends.',
    category: ErrorCategory.accountRestricted,
  );

  static const AppFailure _messagingRestricted = AppFailure(
    title: 'Messaging restricted',
    message: "Your account can't send messages right now. Open Account status in your profile for details.",
    category: ErrorCategory.accountRestricted,
  );

  static const AppFailure _marketplaceRestricted = AppFailure(
    title: 'Account restricted',
    message: "Your account can't do this right now. Open Account status in your profile for details.",
    category: ErrorCategory.accountRestricted,
  );

  static bool _looksLikeExpiredSession(Object? error) {
    final s = _lower(error);
    return s.contains('jwt expired') ||
        s.contains('pgrst301') ||
        s.contains('pgrst303') ||
        s.contains('token is expired') ||
        s.contains('invalid claim');
  }

  /// "You cannot apply to your own post." — the wording raised by
  /// `fn_block_self_application`, plus the local [SelfApplicationException]
  /// that now stops the request before it is sent.
  static bool _isSelfApplication(String? message) {
    final m = (message ?? '').toLowerCase();
    return m.contains('selfapplicationexception') ||
        (m.contains('own post') && m.contains('apply'));
  }

  static const AppFailure _selfApplicationFailure = AppFailure(
    title: 'This is your post',
    message: "You can't apply to your own post — open it to manage applicants.",
    category: ErrorCategory.validation,
  );

  static bool _isUniqueViolation(String? code, String? message) {
    if (code == '23505') return true;
    final m = (message ?? '').toLowerCase();
    return m.contains('duplicate key') || m.contains('already exists');
  }

  static bool _mentionsPermission(String? message) {
    final m = (message ?? '').toLowerCase();
    return m.contains('row-level security') ||
        m.contains('permission denied') ||
        m.contains('not authorized') ||
        m.contains('violates row');
  }

  /// Rules that REPLACE a known server string, checked before any server text
  /// is considered for display. Each one either carries a machine marker or
  /// exposes internal state ("post status is 'assigned'"), so the product's
  /// sentence is used instead.
  static AppFailure? _knownRule(String? raw) {
    if (raw == null) return null;
    final s = raw.toLowerCase();

    // Matched before 'already applied' etc. so the local pre-flight guard and
    // the database trigger produce the identical sentence.
    if (_isSelfApplication(raw)) return _selfApplicationFailure;
    // A listing Trust & Safety hid (JobsService.selectProvider).
    if (s.contains('hidden by help24')) return _hiddenListing;
    if (s.contains('already applied')) return _alreadyApplied;
    // "Cannot select a provider — post status is 'assigned'." (JobsService).
    // Deliberately NOT "provider" + "selected": "No provider has been selected
    // for this post." means the opposite, and "Only the selected provider can
    // mark this job as done." is a different rule — both used to be answered
    // with "This job already has a chosen provider."
    if (s.contains('post status is') ||
        s.contains('status is assigned') ||
        (s.contains('provider') && s.contains('already'))) {
      return _providerChosen;
    }
    // Name-change cooldown. The database trigger (migration 087) is the
    // authority — RLS lets a signed-in user write their own row, so the Dart
    // guard alone would be bypassable. The trigger raises with this marker so
    // the rejection reads as a rule, not as a failure.
    if (s.contains('help24_name_cooldown')) return _nameCooldown;
    // "Payment has already been made for this service." Not "already in
    // progress": that is a DIFFERENT state (an STK prompt is waiting on the
    // payer's phone) and the backend's own sentence for it is shown instead.
    if (s.contains('already been made') || s.contains('already been paid')) {
      return _alreadyPaid;
    }
    return null;
  }

  static const AppFailure _hiddenListing = AppFailure(
    title: 'No longer available',
    message: 'This listing was hidden by Help24 and can no longer be booked.',
    category: ErrorCategory.conflict,
  );

  static const AppFailure _alreadyApplied = AppFailure(
    title: 'Already applied',
    // Neutral wording: this same path covers offering on a request, where
    // "for this job" was simply the wrong noun.
    message: "You've already responded to this.",
    category: ErrorCategory.conflict,
  );

  static const AppFailure _providerChosen = AppFailure(
    title: 'Provider already chosen',
    message: 'This job already has a chosen provider.',
    category: ErrorCategory.conflict,
  );

  static const AppFailure _nameCooldown = AppFailure(
    title: 'Name recently changed',
    message: 'You can change your name again 30 days after your last change.',
    category: ErrorCategory.validation,
  );

  static const AppFailure _alreadyPaid = AppFailure(
    title: 'Already paid',
    message: 'This has already been paid for.',
    category: ErrorCategory.conflict,
  );

  /// Best guesses from keywords, used only when the server's text could not be
  /// shown as written — so a precise backend sentence always wins over these.
  static AppFailure? _keywordGuess(String? raw) {
    if (raw == null) return null;
    final s = raw.toLowerCase();
    // "is not open", not "not open": "Could not open the file picker." is
    // not about a listing.
    if (s.contains('is not open') ||
        s.contains('post is closed') ||
        s.contains('no longer accepting')) {
      return _notAccepting;
    }
    if (s.contains('escrow') ||
        (s.contains('funds are') && s.contains('held')) ||
        s.contains('active dispute')) {
      return _jobActive;
    }
    if (s.contains('not signed in') ||
        s.contains('sign in to') ||
        s.contains('log in to')) {
      return _signIn;
    }
    return null;
  }

  static const AppFailure _notAccepting = AppFailure(
    title: 'No longer available',
    message: 'This post is no longer accepting responses.',
    category: ErrorCategory.conflict,
  );

  static const AppFailure _jobActive = AppFailure(
    title: "Can't do that yet",
    message: "This can't be changed while the job is active.",
    category: ErrorCategory.conflict,
  );

  static const AppFailure _signIn = AppFailure(
    title: 'Sign in to continue',
    message: 'Please sign in to continue.',
    category: ErrorCategory.authentication,
  );

  /// Every sentence this mapper can produce, keyed by its message — what makes
  /// mapping idempotent (see step 9 of [_map]).
  static final Map<String, AppFailure> _authored = {
    for (final f in <AppFailure>[
      _serverUnavailable,
      _session,
      _forbidden,
      _validation,
      _notFound,
      _conflict,
      _rateLimited,
      _tooLarge,
      _selfApplicationFailure,
      _banned,
      _suspended,
      _messagingRestricted,
      _marketplaceRestricted,
      _hiddenListing,
      _alreadyApplied,
      _providerChosen,
      _nameCooldown,
      _alreadyPaid,
      _notAccepting,
      _jobActive,
      _signIn,
      _connectivity(ErrorCategory.networkTimeout, ErrorContext.generic),
      for (final context in ErrorContext.values) ...[
        _connectivity(ErrorCategory.networkOffline, context),
        _fallback(context),
      ],
    ])
      f.message: f,
  };

  // ─── What may be shown ──────────────────────────────────────────────────────

  /// True only for a server message that reads as a sentence written for a
  /// person: short, capitalised, and free of any technical vocabulary, field
  /// name, identifier or markup. Anything that fails is replaced by Help24's
  /// own copy — the cost of a false negative is a less specific message; the
  /// cost of a false positive is "post_id must be a UUID" on someone's phone.
  static bool _isPresentable(String? raw) {
    if (raw == null) return false;
    final s = raw.trim();
    if (s.length < 8 || s.length > 140) return false;
    if (!_startsLikeSentence.hasMatch(s) || !s.contains(' ')) return false;
    if (_camelCase.hasMatch(s)) return false; // postId, userId
    if (_technical.hasMatch(s)) return false;
    return isUserSafe(s);
  }

  static final RegExp _startsLikeSentence = RegExp(r'^[A-Z]');
  static final RegExp _camelCase = RegExp(r'[a-z][A-Z]');

  /// Vocabulary that marks server text as written for a developer. Broad on
  /// purpose — it only ever gates text Help24 did not author.
  static final RegExp _technical = RegExp(
    r'exception|error:|stack|trace|#\d|dart:|package:|flutter|'
    r'socket|\bhost\b|lookup|\bdns\b|errno|os error|handshake|certificate|\bssl\b|\btls\b|'
    // "Check your connection" is Help24's own advice and may pass; the
    // transport's descriptions of a connection may not.
    r'connection (?:terminated|refused|reset|closed|pool|error|failed|lost)|econn|'
    r'timeout|timed out|'
    r'https?|://|www\.|\.(?:com|net|org|io|app|dev|ke)\b|\bapi\b|\buri\b|\burl\b|endpoint|localhost|\bpath\b|'
    r'supabase|postgres|pgrst|firebase|firestore|\brender\b|onrender|vercel|cloudflare|google|daraja|'
    r'\bsql|constraint|violates|relation|\bcolumn\b|\btable\b|schema|row-level|\brls\b|\bpolicy\b|trigger|\bfunction\b|syntax|'
    r'duplicate key|foreign key|primary key|\buuid\b|\bids?\b|\brows?\b|\bnull\b|undefined|\bnan\b|\bjson\b|payload|\bbody\b|\bquery\b|'
    // Node's own TypeError prose, which the backend's catch-all filter puts
    // into a 500 body: "Cannot read properties of null (reading 'x')".
    r'propert(?:y|ies)|cannot read|is not defined|is not a function|'
    r'\bjwt\b|\btoken\b|bearer|unauthori[sz]ed|\bauthenticated\b|forbidden|bad request|internal server|gateway|status|'
    r'backend|\bserver\b|bucket|production|staging|sandbox|environment|'
    r"type '|subtype|instance of|nosuchmethod|closure|"
    r'[{}\[\]<>`"\\|=;:_]|\d{6,}|[0-9a-f]{8}-[0-9a-f]{4}',
    caseSensitive: false,
  );

  /// What no user-facing string may ever contain — the product requirement
  /// written as a pattern. Narrower than [_technical] so Help24's own authored
  /// copy passes; see [isUserSafe].
  static final RegExp _neverShow = RegExp(
    r'exception|socket|host lookup|os error|errno|'
    r'api\.help24|://|uri=|'
    r'supabase|firebase|firestore|postgres|pgrst|onrender|'
    r'\bdart\b|stack ?trace|#0\b|'
    r'\bnull\b|\bjwt\b|\brls\b|row-level|\bsql\b|status ?code|\bhttps?\b|'
    r"type '|subtype|nosuchmethod|instance of",
    caseSensitive: false,
  );

  // ─── Copy ───────────────────────────────────────────────────────────────────

  static const String _checkConnection =
      'Check your internet connection and try again.';

  static AppFailure _connectivity(ErrorCategory category, ErrorContext context) {
    switch (category) {
      case ErrorCategory.networkTimeout:
        return const AppFailure(
          title: 'This is taking too long',
          message: 'This is taking too long. $_checkConnection',
          detail: _checkConnection,
          category: ErrorCategory.networkTimeout,
        );
      case ErrorCategory.serverUnavailable:
        return _serverUnavailable;
      default:
        return AppFailure(
          title: "You're offline",
          message: _offlineSentence(context),
          detail: _checkConnection,
          category: ErrorCategory.networkOffline,
        );
    }
  }

  /// Offline wording names what did not happen when the user was DOING
  /// something — "Your message couldn't be sent" tells them the message is not
  /// with the other person — and simply says "You're offline" when they were
  /// only looking at something.
  static String _offlineSentence(ErrorContext context) => switch (context) {
        ErrorContext.save => "We couldn't save your changes. $_checkConnection",
        ErrorContext.apply => "We couldn't send your response. $_checkConnection",
        ErrorContext.selectProvider => "We couldn't update this job. $_checkConnection",
        ErrorContext.upload => "We couldn't upload your image. $_checkConnection",
        ErrorContext.payment => "Payment could not be started. $_checkConnection",
        ErrorContext.sendMessage => "Your message couldn't be sent. $_checkConnection",
        ErrorContext.location => "We couldn't find your location. $_checkConnection",
        ErrorContext.delete => "We couldn't remove this. $_checkConnection",
        ErrorContext.createRequest => "We couldn't post your request. $_checkConnection",
        ErrorContext.createOffer => "We couldn't post your offer. $_checkConnection",
        ErrorContext.createJob => "We couldn't post your job. $_checkConnection",
        _ => "You're offline. $_checkConnection",
      };

  static const AppFailure _serverUnavailable = AppFailure(
    title: 'Help24 is temporarily unavailable',
    message: 'Help24 is temporarily unavailable. Please try again in a moment.',
    detail: 'Please try again in a moment.',
    category: ErrorCategory.serverUnavailable,
  );

  static const AppFailure _session = AppFailure(
    title: 'Please sign in again',
    message: 'Your session has expired. Please sign in again.',
    category: ErrorCategory.authentication,
  );

  static const AppFailure _forbidden = AppFailure(
    title: 'Not allowed',
    message: "You don't have permission to do that.",
    category: ErrorCategory.authorization,
  );

  static const AppFailure _validation = AppFailure(
    title: 'Check the details',
    message: 'Please check the details and try again.',
    category: ErrorCategory.validation,
  );

  /// A 400/422 or a check violation. "Check the details" is only honest where
  /// the user has just submitted something they typed; after a tap on
  /// "Delete" or "Accept" there are no details to check, and the action's own
  /// sentence says more.
  static AppFailure _validationFor(ErrorContext context) => switch (context) {
        ErrorContext.generic ||
        ErrorContext.save ||
        ErrorContext.apply ||
        ErrorContext.payment ||
        ErrorContext.auth ||
        ErrorContext.sendMessage ||
        ErrorContext.createRequest ||
        ErrorContext.createOffer ||
        ErrorContext.createJob =>
          _validation,
        _ => _fallback(context, ErrorCategory.validation),
      };

  static const AppFailure _notFound = AppFailure(
    title: 'Not found',
    message: "We couldn't find this. It may have been removed.",
    category: ErrorCategory.notFound,
  );

  static const AppFailure _conflict = AppFailure(
    title: 'Already done',
    message: "You've already completed this action.",
    category: ErrorCategory.conflict,
  );

  static const AppFailure _rateLimited = AppFailure(
    title: 'Too many attempts',
    message: "You're doing that a little too quickly. Please wait a moment and try again.",
    category: ErrorCategory.rateLimited,
  );

  static const AppFailure _tooLarge = AppFailure(
    title: 'File too large',
    message: 'That file is too large. Please choose a smaller one.',
    category: ErrorCategory.validation,
  );

  static String? _titleForStatus(int? status) => switch (status) {
        400 || 422 => 'Check the details',
        403 => 'Not allowed',
        404 || 410 => 'Not found',
        409 => "Can't do that right now",
        _ => null,
      };

  static ErrorCategory? _categoryForStatus(int? status) => switch (status) {
        400 || 422 => ErrorCategory.validation,
        402 => ErrorCategory.payment,
        403 => ErrorCategory.authorization,
        404 || 410 => ErrorCategory.notFound,
        409 => ErrorCategory.conflict,
        _ => null,
      };

  static ErrorCategory _contextCategory(ErrorContext context) =>
      context == ErrorContext.payment ? ErrorCategory.payment : ErrorCategory.unknown;

  /// The context's own wording, used whenever nothing more specific is known.
  static AppFailure _fallback(ErrorContext context, [ErrorCategory? category]) {
    final c = category ?? _contextCategory(context);
    switch (context) {
      case ErrorContext.loadFeed:
        return AppFailure(
          title: "We couldn't load this",
          message: "We couldn't load this right now. Pull down to try again.",
          detail: 'Pull down to try again.',
          category: c,
        );
      case ErrorContext.loadContent:
        return AppFailure(
          title: "We couldn't load this",
          message: "We couldn't load this right now. Please try again.",
          detail: 'Please try again.',
          category: c,
        );
      case ErrorContext.save:
        return AppFailure(
          title: "We couldn't save that",
          message: "We couldn't save your changes. Please try again.",
          category: c,
        );
      case ErrorContext.apply:
        return AppFailure(
          title: "We couldn't send that",
          message: "We couldn't send your response. Please try again.",
          category: c,
        );
      case ErrorContext.selectProvider:
        return AppFailure(
          title: "We couldn't do that",
          message: "We couldn't update this job. Please try again.",
          category: c,
        );
      case ErrorContext.upload:
        return AppFailure(
          title: "We couldn't upload that",
          message: "We couldn't upload your image. Please try again.",
          category: c,
        );
      case ErrorContext.payment:
        return AppFailure(
          title: 'Payment could not start',
          message: 'Payment could not be started. Please try again.',
          category: category ?? ErrorCategory.payment,
        );
      case ErrorContext.auth:
        return AppFailure(
          title: "That didn't work",
          message: "We couldn't verify it's you. Please try again.",
          category: c,
        );
      case ErrorContext.sendMessage:
        return AppFailure(
          title: "Message didn't send",
          message: "Your message didn't send. Tap to try again.",
          category: c,
        );
      case ErrorContext.location:
        return AppFailure(
          title: "We couldn't get your location",
          message: "We couldn't get your location. Please try again.",
          category: c,
        );
      case ErrorContext.delete:
        return AppFailure(
          title: "We couldn't remove that",
          message: "We couldn't remove this. Please try again.",
          category: c,
        );
      case ErrorContext.createRequest:
        return AppFailure(
          title: "We couldn't post that",
          message: "We couldn't post your request. Please try again.",
          category: c,
        );
      case ErrorContext.createOffer:
        return AppFailure(
          title: "We couldn't post that",
          message: "We couldn't post your offer. Please try again.",
          category: c,
        );
      case ErrorContext.createJob:
        return AppFailure(
          title: "We couldn't post that",
          message: "We couldn't post your job. Please try again.",
          category: c,
        );
      case ErrorContext.generic:
        return AppFailure(
          title: 'Something went wrong',
          message: 'Something went wrong. Please try again.',
          category: c,
        );
    }
  }

  // ─── Low-level extraction ────────────────────────────────────────────────────

  static String _lower(Object? error) => (error?.toString() ?? '').toLowerCase();

  /// Best-effort human-readable message carried by [error], preferring a
  /// `.message` field (custom exceptions, Postgrest) over `toString()`.
  static String? _rawMessageOf(Object? error) {
    if (error == null) return null;
    if (error is String) return error;
    try {
      final dynamic e = error;
      final msg = e.message;
      if (msg is String && msg.isNotEmpty) return msg;
      if (msg is List) return msg.join('; ');
    } catch (_) {
      // No `.message` getter — fall through to toString().
    }
    return error.toString();
  }

  /// Best-effort HTTP status, if [error] carries one: `.statusCode` (int or
  /// String), a PostgREST code that is an HTTP status, or a function status.
  /// A SQLSTATE such as 23505 is not a status and is ignored.
  static int? _statusCodeOf(Object? error) {
    if (error == null) return null;
    if (error is PostgrestException) return _httpStatus(error.code);
    if (error is FunctionException) return error.status;
    try {
      final dynamic e = error;
      final code = e.statusCode;
      if (code is int) return code;
      if (code is String) return _httpStatus(code);
    } catch (_) {
      // No `.statusCode` getter.
    }
    return null;
  }

  static int? _httpStatus(String? raw) {
    final n = int.tryParse((raw ?? '').trim());
    return (n != null && n >= 100 && n <= 599) ? n : null;
  }

  static void _log(
    Object? error,
    ErrorContext context,
    ErrorCategory category,
    StackTrace? stackTrace,
  ) {
    if (error == null) return;
    debugPrint('[ErrorMapper][${_layerTag(error, category, context)}]'
        '[${context.name}→${category.name}] ${error.runtimeType}: $error');
    // Stack traces are for a developer at a debugger, not for release logcat.
    if (kDebugMode && stackTrace != null) debugPrint('$stackTrace');
  }

  /// The layer a failure came from, for filtering logs: `[NETWORK]`,
  /// `[PAYMENT]`, `[AUTH]`, `[FIREBASE]`, `[SUPABASE]`, `[API]` or `[APP]`.
  static String _layerTag(Object error, ErrorCategory category, ErrorContext context) {
    if (category == ErrorCategory.networkOffline ||
        category == ErrorCategory.networkTimeout) {
      return 'NETWORK';
    }
    if (context == ErrorContext.payment || category == ErrorCategory.payment) {
      return 'PAYMENT';
    }
    if (error is FirebaseAuthException || category == ErrorCategory.authentication) {
      return 'AUTH';
    }
    if (error is FirebaseException) return 'FIREBASE';
    if (error is PostgrestException ||
        error is StorageException ||
        error is AuthException ||
        error is FunctionException) {
      return 'SUPABASE';
    }
    if (_statusCodeOf(error) != null) return 'API';
    return 'APP';
  }
}
