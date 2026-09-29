import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// RAW ERROR TEXT MUST NEVER REACH A HELP24 SCREEN.
///
/// WHAT WENT WRONG
/// ---------------
/// An audit already existed. It routed every `catch` that reached the UI
/// through ErrorMapper, and it searched `catch` blocks for `$e` to prove it.
/// Promote Business still showed users, offline:
///
///   ClientException with SocketException: Failed host lookup:
///   'api.help24.co.ke' (OS Error: No address associated with hostname …)
///
/// because the failure never passed through a `catch` in app code. A
/// FutureBuilder caught it, and the screen rendered `'${snap.error}'`. The
/// mapper recognised that exact exception as "offline"; nothing asked it. A
/// second audit then found the same class of mistake in six more places — a
/// provider forwarding `JobsException.message` (the backend's raw 500 text)
/// into a snackbar, two payment screens passing Daraja's text through, a
/// payout field showing the server's `message` as its error.
///
/// The rule is about the VALUE, wherever it is caught. This file makes the
/// patterns that bypass the mapper fail the build, in the layers where text
/// becomes UI. Services are deliberately not scanned: they embed the original
/// failure in their exception text on purpose, so the mapper can still tell
/// "offline" from "refused".
void main() {
  const uiLayers = ['lib/screens', 'lib/widgets', 'lib/providers', 'lib/utils'];

  /// The translation layer itself reads raw text by design.
  const translators = {
    'lib/utils/error_mapper.dart',
    'lib/utils/auth_error_mapper.dart',
    'lib/utils/mpesa_failure_copy.dart',
  };

  /// Code lines of every UI-layer file, with comments removed and lines that
  /// belong to a log call (debugPrint/print, including their continuation
  /// lines) dropped — a log is exactly where raw text belongs.
  List<({String path, int line, String code})> codeLines() {
    final out = <({String path, int line, String code})>[];
    for (final dir in uiLayers) {
      for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || translators.contains(path)) continue;
        final lines = file.readAsStringSync().replaceAll('\r\n', '\n').split('\n');
        var logDepth = 0;
        for (var i = 0; i < lines.length; i++) {
          // Strip a trailing comment, but not the `//` inside a URL.
          final code = lines[i].replaceFirst(RegExp(r'(?<!:)//.*$'), '');
          if (code.trim().isEmpty) continue;
          if (logDepth > 0 || RegExp(r'\b(debugPrint|print)\(').hasMatch(code)) {
            logDepth += '('.allMatches(code).length - ')'.allMatches(code).length;
            if (logDepth < 0) logDepth = 0;
            continue;
          }
          out.add((path: path, line: i + 1, code: code.trim()));
        }
      }
    }
    return out;
  }

  final lines = codeLines();
  String where(({String path, int line, String code}) l) => '${l.path}:${l.line}: ${l.code}';

  test('no FutureBuilder or StreamBuilder error is rendered as text', () {
    final offenders = lines
        .where((l) => RegExp(
                r'\$\{?(snap|snapshot)\.error|(snap|snapshot)\.error\??\.toString|Text\(\s*(snap|snapshot)\.error')
            .hasMatch(l.code))
        .map(where)
        .toList();
    expect(offenders, isEmpty,
        reason: 'hand the raw error to ErrorRetryView.fromError(snap.error, …) or '
            'ErrorMapper — this is the exact pattern that put "ClientException with '
            "SocketException: Failed host lookup: 'api.help24.co.ke'\" on screen");
  });

  test('no caught error is interpolated into a string outside a log call', () {
    final offenders = lines
        .where((l) => RegExp(r'\$(e|err|error|ex|exception|e2)\b|\$\{(e|err|error|ex|exception|e2)[.}]')
            .hasMatch(l.code))
        .map(where)
        .toList();
    expect(offenders, isEmpty,
        reason: 'log the raw error with debugPrint; show ErrorMapper.toMessage(e, context: …)');
  });

  test('no caught error is turned into text with toString() outside a log call', () {
    final offenders = lines
        .where((l) =>
            RegExp(r'\b(e|err|error|ex|exception|e2)\.toString\(\)').hasMatch(l.code) &&
            // `(e) => e.toString()` maps a list of values, not an error.
            !RegExp(r'\(\s*e\s*\)\s*=>').hasMatch(l.code))
        .map(where)
        .toList();
    expect(offenders, isEmpty,
        reason: 'an exception\'s toString() is its class name, message and, for '
            'package:http, the request URL with the user\'s id in it');
  });

  test('an exception\'s .message reaches the UI only where that text is authored', () {
    // Each entry is a place where the exception's message is written by
    // Help24 for the user, and is allowed through as written. Anything else
    // must go through ErrorMapper, which decides whether server text may be
    // shown. Adding to this list needs the same proof these have.
    const authored = <String, int>{
      // PayoutException keyed on its machine code (OTP_INVALID,
      // OTP_COOLDOWN): the backend's copy for those codes is authored —
      // "Incorrect code. 2 attempts left." — see payout-onboarding.service.ts.
      'lib/screens/provider/payout_otp_screen.dart': 2,
      // ReportException is only ever constructed from authored literals in
      // report_service.dart; its refusal mapping never reads the body.
      'lib/widgets/report_sheet.dart': 1,
    };
    // Any use, not only an assignment: the delete-post leak was
    // `_errors.set(AppFeature.posting, e.message)`, and the payment one
    // `_friendlyError(e.message)` — both invisible to a narrower pattern.
    final found = <String, List<String>>{};
    for (final l in lines) {
      if (RegExp(r'\b(e|err|error|ex|exception)\.message\b').hasMatch(l.code)) {
        found.putIfAbsent(l.path, () => []).add(where(l));
      }
    }
    final offenders = <String>[
      for (final entry in found.entries)
        if ((authored[entry.key] ?? 0) < entry.value.length) ...entry.value,
    ];
    expect(offenders, isEmpty,
        reason: 'JobsException, PromotionException, MpesaException and friends carry '
            'the server\'s `message`, which for an unhandled 500 is Node\'s own '
            'error text — map it with ErrorMapper.toMessage(e, context: …)');
  });

  test('Promote Business builds every failure view from the raw error', () {
    for (final path in [
      'lib/screens/promotion/promote_business_screen.dart',
      'lib/screens/promotion/campaign_detail_screen.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('ErrorRetryView.fromError('), isTrue, reason: path);
      expect(src.contains('ReconnectListener('), isTrue,
          reason: '$path: a failed load should refill itself when the connection returns');
    }
  });

  test('payment flows never show Daraja or server text', () {
    for (final path in [
      'lib/screens/payment_screen.dart',
      'lib/screens/promotion/promote_listing_flow_screen.dart',
      'lib/screens/promotion/promote_business_screen.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('MpesaFailureCopy.'), isTrue, reason: path);
      // The old pass-throughs: "if it is short, show it".
      expect(src.contains('raw.length < 120'), isFalse, reason: path);
      expect(RegExp(r"_payMessage\s*=\s*status\['failure_reason'\]").hasMatch(src), isFalse,
          reason: path);
    }
  });

  test('the scan is not vacuously green', () {
    expect(lines.length, greaterThan(20000),
        reason: 'the UI layers hold tens of thousands of lines; a small number means '
            'the directory walk broke and every guard above proves nothing');
    expect(lines.where((l) => l.code.contains('catch (')).length, greaterThan(100));
    expect(lines.any((l) => l.path.endsWith('promote_business_screen.dart')), isTrue);
    // The guard must see the calls it is protecting, or it is not looking.
    expect(lines.where((l) => l.code.contains('ErrorMapper.toMessage(')).length,
        greaterThan(20));
  });
}
