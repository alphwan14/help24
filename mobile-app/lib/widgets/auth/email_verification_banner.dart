import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/auth_error_mapper.dart';

/// Prompts a signed-in user to confirm their email address.
///
/// WHY THIS EXISTS
/// ---------------
/// Before this, Help24 never called `sendEmailVerification` at all. Anyone
/// could register with an address they did not control, which matters for a
/// marketplace holding escrow balances: the password-reset path for that
/// account points at a mailbox its owner never confirmed, and a name+email
/// shown next to a completed job carried no evidence behind it.
///
/// DESIGN: A NUDGE, NOT A WALL
/// Verification is requested, not enforced. Blocking an unverified user from
/// browsing would tank activation for the many Kenyan users who sign in by
/// phone, check email rarely, or are on a device without a mail client
/// configured. The right escalation point for hard enforcement is a
/// money-moving action, not app entry.
class EmailVerificationBanner extends StatefulWidget {
  const EmailVerificationBanner({super.key});

  @override
  State<EmailVerificationBanner> createState() =>
      _EmailVerificationBannerState();
}

class _EmailVerificationBannerState extends State<EmailVerificationBanner> {
  bool _sending = false;
  bool _sent = false;
  bool _dismissed = false;

  /// Why the last send did not go out. Null when nothing has failed.
  ///
  /// The banner previously stored only `_sent = ok`, so a false result was
  /// pixel-identical to never having tapped: the failure WAS captured in
  /// AuthProvider.failure, and nothing ever read it. That is the whole of
  /// "Send Link does not send any email and nothing happens".
  AuthFailure? _failure;

  /// Sends are provider-rate-limited. A visible retry button invites repeat
  /// taps, and enough of them earn a lockout that looks like a new bug — so
  /// the button states its own cooldown.
  static const Duration _cooldown = Duration(seconds: 30);
  Timer? _cooldownTimer;
  int _cooldownRemaining = 0;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownRemaining = _cooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldownRemaining--);
      if (_cooldownRemaining <= 0) timer.cancel();
    });
  }

  @override
  void initState() {
    super.initState();
    // The user may have tapped the link in another app while Help24 sat in the
    // background; the local session caches `emailVerified`, so ask the server
    // once on mount rather than showing a prompt for something already done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().refreshEmailVerified();
    });
  }

  Future<void> _resend() async {
    final auth = context.read<AuthProvider>();
    setState(() {
      _sending = true;
      _failure = null;
    });
    final ok = await auth.sendVerificationEmail();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = ok;
      // The provider already mapped the cause; the only bug was never reading
      // it. The fallback covers the (unexpected) case of a false result with no
      // recorded reason — silence is not an option here.
      _failure = ok
          ? null
          : (auth.failure ??
              const AuthFailure(
                title: "We couldn't send it",
                message: 'Something stopped the email going out. '
                    'Please try again in a moment.',
              ));
    });
    if (ok) _startCooldown();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (_dismissed || !auth.needsEmailVerification) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    // A failed send is a different state from an un-attempted one, and it must
    // look different. Orange "please confirm" turning red "that didn't send" is
    // the whole point.
    final failed = _failure != null;
    final accent = failed ? AppTheme.errorRed : AppTheme.warningOrange;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              failed ? Icons.error_outline_rounded : Iconsax.sms_notification,
              color: accent,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failed
                      ? _failure!.title
                      : _sent
                          ? 'Verification email sent'
                          : 'Confirm your email',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  failed
                      ? _failure!.message
                      : _sent
                          ? 'Open the link we sent to ${auth.currentUserEmail ?? "your inbox"}. '
                              'Check spam if it hasn’t arrived.'
                          : 'Confirming your email keeps your account recoverable if '
                              'you ever forget your password.',
                  style: TextStyle(
                      fontSize: 13.2, height: 1.4, color: textSecondary),
                ),
                // The action stays available after a failure — a dead end is
                // what this banner used to be.
                if (!_sent || failed) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed:
                        (_sending || _cooldownRemaining > 0) ? null : _resend,
                    style: TextButton.styleFrom(
                      foregroundColor: accent,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      _sending
                          ? 'Sending…'
                          : _cooldownRemaining > 0
                              ? 'Try again in ${_cooldownRemaining}s'
                              : failed
                                  ? 'Try again'
                                  : 'Send the link',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 17, color: textSecondary),
            onPressed: () => setState(() => _dismissed = true),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}
