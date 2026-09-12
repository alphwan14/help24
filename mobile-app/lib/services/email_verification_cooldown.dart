import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often Help24 will ask the identity provider to send a confirmation
/// email for one account.
///
/// WHY THIS EXISTS — THE "TOO MANY ATTEMPTS" REPORT
/// -----------------------------------------------
/// A new account gets one confirmation email automatically, from `signUp`.
/// Nothing told the user that, so the first thing they did on reaching the
/// prompt was ask for another. The resend control then had two properties that
/// together guaranteed the outcome:
///
///   1. Its pause was armed ONLY after a send SUCCEEDED (`if (ok)
///      _startCooldown()`). A rejected send — including the provider's own
///      rate-limit rejection — left the button live and labelled "Try again",
///      which is precisely the state that must not invite another tap, because
///      each tap keeps the provider's block alive.
///   2. Its pause lived in widget state. It did not survive an app restart,
///      and a restart is exactly what happens between the sends that actually
///      consume the quota.
///
/// So the pause bounded nothing. This class moves it onto disk, keys it by
/// account, and — critically — makes it the SERVICE's rule rather than the
/// screen's, so no future surface can send without honouring it.
///
/// WHAT THE NUMBERS MEAN, AND WHAT THEY DO NOT
/// -------------------------------------------
/// [_ourBackoff] is Help24's own pacing. It is exact, it is ours, and the UI
/// may count it down to the second truthfully.
///
/// [providerBlock] is different and must not be presented as if it were the
/// same thing. When the provider answers `too-many-requests` it is applying
/// its own limit, whose length is adaptive and is not published. Five minutes
/// is a conservative floor that stops the app hammering the endpoint; it is
/// NOT a claim about when the provider will relent, and the copy that goes
/// with it says "a few minutes", never a promise. Counting down to zero and
/// failing again would be a worse lie than saying nothing.
class EmailVerificationCooldown {
  EmailVerificationCooldown._();

  /// Help24's own spacing between sends, growing with each one. A user whose
  /// first email genuinely went astray waits under a minute; a user tapping
  /// repeatedly is slowed down before the provider has to do it for us.
  static const List<Duration> _ourBackoff = [
    Duration(seconds: 45),
    Duration(seconds: 90),
    Duration(minutes: 3),
    Duration(minutes: 5),
  ];

  /// Applied when the provider itself refuses. See the class note: a floor,
  /// not a prediction.
  static const Duration providerBlock = Duration(minutes: 5);

  /// Scoped by uid. Two accounts on one device must not inherit each other's
  /// pause — the same rule every other user-scoped store in this app follows.
  static String _nextKey(String uid) => 'email_verify_next_at_$uid';
  static String _countKey(String uid) => 'email_verify_sends_$uid';

  /// How long before another send is allowed. [Duration.zero] means now.
  static Future<Duration> remaining(String uid) async {
    if (uid.isEmpty) return Duration.zero;
    try {
      final prefs = await SharedPreferences.getInstance();
      final nextAt = prefs.getInt(_nextKey(uid));
      if (nextAt == null) return Duration.zero;
      final left = nextAt - DateTime.now().millisecondsSinceEpoch;
      return left <= 0 ? Duration.zero : Duration(milliseconds: left);
    } catch (e) {
      // A pause we cannot read must never become a send we cannot make: a user
      // locked out of their own account is the worse failure of the two.
      debugPrint('[VERIFY] cooldown read unavailable: ${e.runtimeType}');
      return Duration.zero;
    }
  }

  /// A send left the device. Arms the next pause and advances the backoff.
  static Future<void> recordSend(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final sends = prefs.getInt(_countKey(uid)) ?? 0;
      final wait = _ourBackoff[sends.clamp(0, _ourBackoff.length - 1)];
      await prefs.setInt(_countKey(uid), sends + 1);
      await prefs.setInt(
        _nextKey(uid),
        DateTime.now().add(wait).millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[VERIFY] cooldown write failed: ${e.runtimeType}');
    }
  }

  /// The provider refused with its own rate limit. Holds off for the floor
  /// above, and does NOT advance our backoff — the send never happened, so
  /// counting it would punish the user twice for one refusal.
  static Future<void> recordProviderBlock(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = DateTime.now().add(providerBlock).millisecondsSinceEpoch;
      final existing = prefs.getInt(_nextKey(uid)) ?? 0;
      // Never shorten a pause that is already longer.
      if (until > existing) await prefs.setInt(_nextKey(uid), until);
    } catch (e) {
      debugPrint('[VERIFY] provider block write failed: ${e.runtimeType}');
    }
  }

  /// The address is confirmed, or the account is gone. Nothing left to pace.
  static Future<void> clear(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_nextKey(uid));
      await prefs.remove(_countKey(uid));
    } catch (e) {
      debugPrint('[VERIFY] cooldown clear failed: ${e.runtimeType}');
    }
  }

  /// "45s" / "2:30" — the shape a countdown is read in, not "150 seconds".
  static String format(Duration remaining) {
    final seconds = remaining.inSeconds;
    if (seconds <= 0) return '';
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }
}
