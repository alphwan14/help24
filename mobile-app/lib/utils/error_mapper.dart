import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, PostgrestException, StorageException;

/// A human-first description of a failure, following the product rule that a
/// user should always understand: what happened ([title]), and what to do next
/// ([message]). Never contains exception class names, backend URLs, HTTP status
/// codes, socket/DNS wording or any other implementation detail.
@immutable
class AppFailure {
  /// Short headline — "You're offline", "We couldn't load this".
  final String title;

  /// One reassuring, actionable sentence — the "why + what next".
  final String message;

  /// True when the failure is a connectivity problem (offline / unreachable /
  /// timeout). Screens can use this to show the offline treatment and to know
  /// that automatic recovery on reconnect is worthwhile.
  final bool isOffline;

  const AppFailure({
    required this.title,
    required this.message,
    this.isOffline = false,
  });
}

/// Where the failure happened, so the mapper can pick the most reassuring
/// "what to do next" wording. Only affects the *generic* fallback copy —
/// connectivity, auth and known domain errors are mapped the same everywhere.
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
}

/// The single production-grade translation layer between raw failures and the
/// UI. Every `catch` that reaches the screen should route through here instead
/// of interpolating `$e`, calling `e.toString()`, or forwarding a backend body.
///
/// Design rules:
///   1. Never leak. If a message cannot be positively recognised as safe, the
///      generic fallback is returned — raw text is never passed through.
///   2. Classify by type first (platform + Supabase exceptions), then by known
///      domain phrases, then fall back.
///   3. Log the real error separately via [debugPrint] so engineers keep the
///      detail the user must never see.
class ErrorMapper {
  ErrorMapper._();

  // ─── Public API ────────────────────────────────────────────────────────────

  /// The friendly one-line message for [error]. Drop-in replacement for every
  /// `'Failed to …: $e'` string. Pass [context] to tailor the generic fallback.
  static String toMessage(Object? error, {ErrorContext context = ErrorContext.generic}) =>
      toFailure(error, context: context).message;

  /// The structured [AppFailure] (title + message) for [error].
  static AppFailure toFailure(Object? error,
      {ErrorContext context = ErrorContext.generic}) {
    // Always log the true cause; the user only ever sees the mapped result.
    if (error != null) {
      debugPrint('[ErrorMapper][${context.name}] ${error.runtimeType}: $error');
    }

    // 1) Connectivity — the most common real-world failure. Every transport
    //    problem (no interface, DNS, socket, timeout, connection refused/reset,
    //    handshake) is the same thing to the user: the internet round-trip
    //    didn't complete. One calm, human message covers them all.
    if (_isOffline(error) || _isTimeout(error) || _isUnreachable(error)) {
      return const AppFailure(
        title: 'Internet unavailable',
        message: "We couldn't reach the internet. Please try again.",
        isOffline: true,
      );
    }

    // 2) Auth / session.
    if (error is AuthException || _looksLikeExpiredSession(error)) {
      return const AppFailure(
        title: 'Please sign in again',
        message: 'Your session expired. Please sign in again to continue.',
      );
    }

    // 3) Storage (image / evidence uploads).
    if (error is StorageException) {
      return _forContext(ErrorContext.upload);
    }

    // 4) Postgrest / database.
    if (error is PostgrestException) {
      if (_isUniqueViolation(error.code, error.message)) {
        return const AppFailure(
          title: 'Already done',
          message: "You've already completed this action.",
        );
      }
      if (_mentionsPermission(error.message)) {
        return const AppFailure(
          title: 'Not allowed',
          message: "You don't have permission to do that.",
        );
      }
      return _forContext(context);
    }

    // 5) Known, safe domain phrases carried on custom exception messages.
    //    These are matched on the *content* so they work regardless of which
    //    XxxException class wrapped them.
    final raw = _rawMessageOf(error);
    final domain = _matchDomainPhrase(raw);
    if (domain != null) return domain;

    // 6) HTTP status code, if the exception exposes one (e.g. JobsException).
    final status = _statusCodeOf(error);
    if (status != null) {
      final mapped = _forStatus(status, context);
      if (mapped != null) return mapped;
    }

    // 7) A short, already-human backend/domain message with no technical
    //    markers may pass through verbatim. Anything else → generic fallback.
    if (_isCleanHumanMessage(raw)) {
      return AppFailure(title: _titleFor(context), message: raw!);
    }

    return _forContext(context);
  }

  /// Whether [error] is purely a connectivity problem (offline / unreachable /
  /// timeout). Useful for deciding on offline UI and auto-retry-on-reconnect.
  static bool isConnectivityError(Object? error) =>
      _isOffline(error) || _isTimeout(error) || _isUnreachable(error);

  // ─── Connectivity classification ────────────────────────────────────────────

  static bool _isOffline(Object? error) {
    if (error is SocketException) {
      // A DNS failure ("Failed host lookup") almost always means no network.
      return true;
    }
    final s = _lower(error);
    return s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('no address associated with hostname') ||
        s.contains('nodename nor servname');
  }

  static bool _isTimeout(Object? error) {
    if (error is TimeoutException) return true;
    return _lower(error).contains('timeout') || _lower(error).contains('timed out');
  }

  static bool _isUnreachable(Object? error) {
    if (error is ClientException) return true;
    if (error is HandshakeException) return true;
    final s = _lower(error);
    return s.contains('clientexception') ||
        s.contains('connection closed') ||
        s.contains('connection refused') ||
        s.contains('connection reset') ||
        s.contains('handshakeexception') ||
        s.contains('httpexception');
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  static bool _looksLikeExpiredSession(Object? error) {
    final s = _lower(error);
    return s.contains('jwt expired') ||
        s.contains('pgrst303') ||
        s.contains('token is expired') ||
        s.contains('invalid claim');
  }

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

  /// Recognised, product-approved domain messages. Matching on content keeps a
  /// single source of truth for this wording and neutralises the raw backend
  /// strings (e.g. "post status is 'assigned'") that used to reach users.
  static AppFailure? _matchDomainPhrase(String? raw) {
    if (raw == null) return null;
    final s = raw.toLowerCase();

    if (s.contains('already applied')) {
      return const AppFailure(
        title: 'Already applied',
        message: "You've already applied for this job.",
      );
    }
    if ((s.contains('provider') &&
            (s.contains('already') || s.contains('assigned') || s.contains('selected'))) ||
        s.contains('post status is') ||
        s.contains('status is assigned')) {
      return const AppFailure(
        title: 'Provider already chosen',
        message: 'This job already has a chosen provider.',
      );
    }
    if (s.contains('not open') || s.contains('no longer available') || s.contains('post is closed')) {
      return const AppFailure(
        title: 'No longer available',
        message: 'This post is no longer accepting responses.',
      );
    }
    if (s.contains('already been made') || s.contains('already in progress')) {
      return const AppFailure(
        title: 'Already done',
        message: 'This has already been paid for.',
      );
    }
    if (s.contains('sign in') || s.contains('log in') || s.contains('not signed in')) {
      return const AppFailure(
        title: 'Sign in to continue',
        message: 'Please sign in to continue.',
      );
    }
    if (s.contains('escrow') || s.contains('funds are held') || s.contains('active dispute')) {
      return const AppFailure(
        title: "Can't do that yet",
        message: "This can't be changed while the job is active.",
      );
    }
    return null;
  }

  static AppFailure? _forStatus(int status, ErrorContext context) {
    if (status == 401 || status == 403) {
      return const AppFailure(
        title: 'Not allowed',
        message: "You don't have permission to do that.",
      );
    }
    if (status == 404) {
      return const AppFailure(
        title: 'Not found',
        message: "We couldn't find this. It may have been removed.",
      );
    }
    if (status == 409) {
      return const AppFailure(
        title: 'Already done',
        message: "You've already completed this action.",
      );
    }
    if (status == 429) {
      return const AppFailure(
        title: 'Slow down',
        message: 'Too many attempts. Please wait a moment and try again.',
      );
    }
    if (status >= 500) {
      return const AppFailure(
        title: 'Server temporarily unavailable',
        message: 'Help24 is temporarily unavailable. Please try again shortly.',
      );
    }
    return null; // Other 4xx → let context fallback decide.
  }

  /// True only for a short message with no technical markers — safe to show.
  static bool _isCleanHumanMessage(String? raw) {
    if (raw == null) return false;
    final s = raw.trim();
    if (s.isEmpty || s.length > 120) return false;
    final lower = s.toLowerCase();
    const banned = [
      'exception',
      'error:',
      '{',
      '}',
      'null',
      'http',
      'render',
      'onrender',
      'supabase',
      'postgres',
      'socket',
      'stack',
      'statuscode',
      'status code',
      '#0',
      'dart:',
      'flutter',
      'backend',
      'bucket',
      'rls',
      'jwt',
    ];
    for (final marker in banned) {
      if (lower.contains(marker)) return false;
    }
    return true;
  }

  static AppFailure _forContext(ErrorContext context) {
    switch (context) {
      case ErrorContext.loadFeed:
        return const AppFailure(
          title: "We couldn't load this",
          message: "We couldn't load this right now. Pull down to try again.",
        );
      case ErrorContext.loadContent:
        return const AppFailure(
          title: "We couldn't load this",
          message: "We couldn't load this right now. Please try again.",
        );
      case ErrorContext.save:
        return const AppFailure(
          title: "We couldn't save that",
          message: "We couldn't save your changes. Please try again.",
        );
      case ErrorContext.apply:
        return const AppFailure(
          title: "We couldn't send that",
          message: "We couldn't send your response. Please try again.",
        );
      case ErrorContext.selectProvider:
        return const AppFailure(
          title: "We couldn't do that",
          message: "We couldn't update this job. Please try again.",
        );
      case ErrorContext.upload:
        return const AppFailure(
          title: "We couldn't upload that",
          message: "We couldn't upload your image. Please try again.",
        );
      case ErrorContext.payment:
        return const AppFailure(
          title: 'Payment could not start',
          message: 'Payment could not be started. Please try again.',
        );
      case ErrorContext.auth:
        return const AppFailure(
          title: "That didn't work",
          message: "We couldn't verify it's you. Please try again.",
        );
      case ErrorContext.sendMessage:
        return const AppFailure(
          title: "Message didn't send",
          message: "Your message didn't send. Tap to try again.",
        );
      case ErrorContext.location:
        return const AppFailure(
          title: "We couldn't get your location",
          message: "We couldn't get your location. Please try again.",
        );
      case ErrorContext.generic:
        return const AppFailure(
          title: 'Something went wrong',
          message: 'Something went wrong. Please try again.',
        );
    }
  }

  static String _titleFor(ErrorContext context) => _forContext(context).title;

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

  /// Best-effort HTTP status code, if the exception exposes `.statusCode`.
  static int? _statusCodeOf(Object? error) {
    if (error == null) return null;
    try {
      final dynamic e = error;
      final code = e.statusCode;
      if (code is int) return code;
      if (code is String) return int.tryParse(code);
    } catch (_) {
      // No `.statusCode` getter.
    }
    return null;
  }
}
