import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../../models/payout_models.dart';
import '../../services/payout_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/action_feedback.dart';
import '../../utils/error_mapper.dart';
import '../../utils/phone_utils.dart';
import '../../widgets/auth/otp_input.dart';

/// Enter the 6-digit code that proves a payout number.
///
/// Two independent clocks drive this screen:
///  • the SERVER expiry (5-minute TTL on the challenge) → the "expired" state,
///  • the local resend backoff (30/60/120s, floored by the server's 60s
///    cooldown) → when "Send a new code" becomes tappable.
///
/// Failure states branch on `PayoutException.code`, never on message text.
/// Pops with the verified [PayoutDestination] on success.
class PayoutOtpScreen extends StatefulWidget {
  final String uid;
  final PayoutDestination destination;

  const PayoutOtpScreen({super.key, required this.uid, required this.destination});

  @override
  State<PayoutOtpScreen> createState() => _PayoutOtpScreenState();
}

enum _OtpPhase { entering, verifying, expired, locked, success }

class _PayoutOtpScreenState extends State<PayoutOtpScreen> {
  static const List<int> _backoffSeconds = [30, 60, 120];

  final _otpKey = GlobalKey<OtpInputState>();

  _OtpPhase _phase = _OtpPhase.entering;
  bool _hasError = false;
  String? _inlineError;
  int? _attemptsRemaining;

  DateTime? _expiresAt;
  Duration _ttlLeft = Duration.zero;
  Timer? _ttlTimer;

  int _resendCount = 0;
  int _resendRemaining = 0;
  Timer? _resendTimer;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    final challenge = widget.destination.verification;
    _expiresAt = challenge?.expiresAt;
    _startTtlClock();
    _startResendCountdown(_initialResendSeconds(challenge));
  }

  @override
  void dispose() {
    _ttlTimer?.cancel();
    _resendTimer?.cancel();
    super.dispose();
  }

  int _initialResendSeconds(PayoutChallenge? challenge) {
    final serverGate = challenge?.resendAvailableAt;
    final serverSeconds = serverGate == null
        ? 0
        : serverGate.difference(DateTime.now()).inSeconds;
    final backoff = _backoffSeconds[0];
    return serverSeconds > backoff ? serverSeconds : backoff;
  }

  void _startTtlClock() {
    _ttlTimer?.cancel();
    final expires = _expiresAt;
    if (expires == null) return;
    _ttlLeft = expires.difference(DateTime.now());
    if (_ttlLeft.isNegative) {
      setState(() => _phase = _OtpPhase.expired);
      return;
    }
    _ttlTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = expires.difference(DateTime.now());
      if (!mounted) return;
      if (left.isNegative || left == Duration.zero) {
        timer.cancel();
        setState(() {
          _ttlLeft = Duration.zero;
          if (_phase == _OtpPhase.entering) _phase = _OtpPhase.expired;
        });
      } else {
        setState(() => _ttlLeft = left);
      }
    });
  }

  void _startResendCountdown(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendRemaining = seconds);
    if (seconds <= 0) return;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_resendRemaining <= 1) {
        timer.cancel();
        setState(() => _resendRemaining = 0);
      } else {
        setState(() => _resendRemaining -= 1);
      }
    });
  }

  Future<void> _verify(String code) async {
    if (_phase == _OtpPhase.verifying || _phase == _OtpPhase.success) return;
    setState(() {
      _phase = _OtpPhase.verifying;
      _hasError = false;
      _inlineError = null;
    });
    try {
      final verified = await PayoutService.verify(
        widget.uid,
        widget.destination.id,
        code,
      );
      if (!mounted) return;
      setState(() => _phase = _OtpPhase.success);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      Navigator.pop(context, verified);
    } on PayoutException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'OTP_INVALID':
          setState(() {
            _phase = _OtpPhase.entering;
            _hasError = true;
            _attemptsRemaining = e.attemptsRemaining;
            _inlineError = e.message;
          });
          _otpKey.currentState?.clear();
          break;
        case 'OTP_EXPIRED':
          setState(() => _phase = _OtpPhase.expired);
          break;
        case 'OTP_LOCKED':
          setState(() => _phase = _OtpPhase.locked);
          break;
        case 'OTP_NOT_FOUND':
          setState(() => _phase = _OtpPhase.expired);
          break;
        default:
          setState(() => _phase = _OtpPhase.entering);
          if (mounted) {
            ActionFeedback.failure(context, e, context_: ErrorContext.auth);
          }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _OtpPhase.entering);
      ActionFeedback.failure(context, e, context_: ErrorContext.auth);
    }
  }

  Future<void> _resend() async {
    if (_resendRemaining > 0 || _resending) return;
    setState(() => _resending = true);
    try {
      final challenge =
          await PayoutService.requestChallenge(widget.uid, widget.destination.id);
      if (!mounted) return;
      _resendCount += 1;
      _expiresAt = challenge.expiresAt;
      setState(() {
        _phase = _OtpPhase.entering;
        _hasError = false;
        _inlineError = null;
        _attemptsRemaining = null;
      });
      _otpKey.currentState?.clear();
      _startTtlClock();
      final backoff = _backoffSeconds[
          _resendCount < _backoffSeconds.length ? _resendCount : _backoffSeconds.length - 1];
      _startResendCountdown(backoff);
      ActionFeedback.success(context, 'A new code is on its way.');
    } on PayoutException catch (e) {
      if (!mounted) return;
      if (e.code == 'OTP_COOLDOWN' && e.retryAfterSeconds != null) {
        _startResendCountdown(e.retryAfterSeconds!);
        ActionFeedback.info(context, e.message);
      } else {
        ActionFeedback.failure(context, e, context_: ErrorContext.auth);
      }
    } catch (e) {
      if (!mounted) return;
      ActionFeedback.failure(context, e, context_: ErrorContext.auth);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  String get _ttlLabel {
    final m = _ttlLeft.inMinutes;
    final s = _ttlLeft.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final masked = maskPhone(widget.destination.destination);

    return Scaffold(
      appBar: AppBar(title: const Text('Verify payout number')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                _phase == _OtpPhase.success ? Iconsax.tick_circle : Iconsax.mobile,
                size: 48,
                color: _phase == _OtpPhase.success
                    ? AppTheme.successGreen
                    : AppTheme.primaryAccent,
              ),
              const SizedBox(height: 16),
              Text(
                _phase == _OtpPhase.success
                    ? 'Number verified'
                    : 'Enter the 6-digit code',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                _phase == _OtpPhase.success
                    ? 'M-Pesa payouts will be sent to $masked.'
                    : 'We sent a verification code to $masked. It confirms this is your number before any money is sent to it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 32),
              ..._buildBody(isDark),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBody(bool isDark) {
    switch (_phase) {
      case _OtpPhase.expired:
        return _terminalState(
          isDark,
          icon: Iconsax.timer_1,
          color: AppTheme.warningOrange,
          title: 'This code has expired',
          detail: 'Codes are valid for 5 minutes. Ask for a new one to continue.',
        );
      case _OtpPhase.locked:
        return _terminalState(
          isDark,
          icon: Iconsax.lock,
          color: AppTheme.errorRed,
          title: 'Too many incorrect attempts',
          detail:
              'That code is no longer usable. Ask for a new one and type it carefully.',
        );
      case _OtpPhase.success:
        return const [SizedBox.shrink()];
      case _OtpPhase.entering:
      case _OtpPhase.verifying:
        return [
          OtpInput(
            key: _otpKey,
            onCompleted: _verify,
            enabled: _phase != _OtpPhase.verifying,
            hasError: _hasError,
          ),
          const SizedBox(height: 12),
          if (_inlineError != null)
            Text(
              _inlineError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.errorRed, fontSize: 13),
            )
          else if (_attemptsRemaining != null)
            Text(
              '$_attemptsRemaining attempts left',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.warningOrange, fontSize: 13),
            ),
          const SizedBox(height: 16),
          if (_phase == _OtpPhase.verifying)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_expiresAt != null)
            Text(
              'Code expires in $_ttlLabel',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _ttlLeft.inSeconds < 60
                    ? AppTheme.warningOrange
                    : (isDark
                        ? AppTheme.darkTextTertiary
                        : AppTheme.lightTextTertiary),
              ),
            ),
          const SizedBox(height: 24),
          _resendRow(isDark),
        ];
    }
  }

  List<Widget> _terminalState(
    bool isDark, {
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
  }) {
    return [
      Icon(icon, size: 40, color: color),
      const SizedBox(height: 12),
      Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        detail,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
        ),
      ),
      const SizedBox(height: 24),
      _resendRow(isDark),
    ];
  }

  Widget _resendRow(bool isDark) {
    if (_resendRemaining > 0) {
      final label = _resendRemaining >= 60
          ? '${(_resendRemaining / 60).ceil()} min'
          : '${_resendRemaining}s';
      return Text(
        "Didn't get it? You can ask for a new code in $label",
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
        ),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: _resending ? null : _resend,
        icon: _resending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Iconsax.refresh, size: 18),
        label: const Text('Send a new code'),
      ),
    );
  }
}
