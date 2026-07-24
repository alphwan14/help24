import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../theme/app_theme.dart';

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
    setState(() => _sending = true);
    final ok = await context.read<AuthProvider>().sendVerificationEmail();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = ok;
    });
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

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Iconsax.sms_notification,
                color: AppTheme.warningOrange, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _sent ? 'Verification email sent' : 'Confirm your email',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _sent
                      ? 'Open the link we sent to ${auth.currentUserEmail ?? "your inbox"}. '
                          'Check spam if it hasn’t arrived.'
                      : 'Confirming your email keeps your account recoverable if '
                          'you ever forget your password.',
                  style: TextStyle(
                      fontSize: 13.2, height: 1.4, color: textSecondary),
                ),
                if (!_sent) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _sending ? null : _resend,
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.warningOrange,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      _sending ? 'Sending…' : 'Send the link',
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
