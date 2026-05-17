import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/mpesa_service.dart';
import '../theme/app_theme.dart';

// ─── State machine ────────────────────────────────────────────────────────────

enum PaymentState {
  idle,        // User has not clicked Pay
  initiating,  // API call in flight
  stkSent,     // 201 received — prompt on the way (2 s, then auto → awaitingPin)
  awaitingPin, // User must enter M-Pesa PIN (polling running)
  processing,  // PIN entered, waiting for Daraja callback (poll ≥ 4)
  success,     // status = 'paid'
  failed,      // Rejected, cancelled, or API error
  expired,     // 2-minute timeout with no confirmation
}

extension _PaymentStateX on PaymentState {
  /// Terminal: polling must stop and no further transitions are allowed.
  bool get isTerminal =>
      this == PaymentState.success ||
      this == PaymentState.failed ||
      this == PaymentState.expired;

  /// Back-navigation is blocked while a payment is in-flight.
  bool get blocksNav =>
      this == PaymentState.initiating ||
      this == PaymentState.stkSent ||
      this == PaymentState.awaitingPin ||
      this == PaymentState.processing;
}

// ─── Fee calculation (mirrors backend fee table) ─────────────────────────────

double calculatePlatformFee(double amount) {
  if (amount <= 0) return 0;
  if (amount <= 100) return 5;
  if (amount <= 500) return 15;
  if (amount <= 1000) return 25;
  if (amount <= 2500) return 45;
  if (amount <= 5000) return 70;
  if (amount <= 10000) return 120;
  return (amount * 0.012).roundToDouble();
}

// ─── PaymentScreen ────────────────────────────────────────────────────────────

class PaymentScreen extends StatefulWidget {
  final String postId;
  final String postTitle;
  final double amount;
  final double platformFee;
  final String buyerUserId;

  /// Normalized 254XXXXXXXXX — validated before navigation.
  final String buyerPhone;

  const PaymentScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.amount,
    required this.platformFee,
    required this.buyerUserId,
    required this.buyerPhone,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  // ── State machine ─────────────────────────────────────────────────────────
  PaymentState _state = PaymentState.idle;
  String? _errorMessage;
  String? _mpesaReceipt;

  // ── Polling ───────────────────────────────────────────────────────────────
  Timer? _pollTimer;
  Timer? _autoAdvanceTimer;
  int _pollCount = 0;
  static const int _maxPolls = 24;         // 24 × 5 s ≈ 2 min
  static const int _processingThreshold = 4; // After 4 polls (~20 s) → PROCESSING

  // ── Debug panel ───────────────────────────────────────────────────────────
  Map<String, dynamic>? _testStkResult;
  bool _testStkLoading = false;
  final _testPhoneController = TextEditingController(text: '254708374149');

  // ── Animation ─────────────────────────────────────────────────────────────
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  double get _total => widget.amount + widget.platformFee;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    _pulseController.dispose();
    _testPhoneController.dispose();
    super.dispose();
  }

  // ─── Transitions ──────────────────────────────────────────────────────────

  void _transition(PaymentState next, {String? error, String? receipt}) {
    if (!mounted) return;
    debugPrint('[PaymentSM] ${_state.name} → ${next.name}${error != null ? ' ($error)' : ''}');
    setState(() {
      _state = next;
      if (error != null) _errorMessage = error;
      if (receipt != null) _mpesaReceipt = receipt;
    });
  }

  // ─── Main flow ─────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    _transition(PaymentState.initiating);

    try {
      await MpesaService.initiatePayment(
        postId: widget.postId,
        buyerUserId: widget.buyerUserId,
        buyerPhone: widget.buyerPhone,
      );
      // 201 received — STK is on the way.
      _transition(PaymentState.stkSent);
      // Auto-advance to AWAITING_PIN after 2 s so user reads the confirmation.
      _autoAdvanceTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted || _state != PaymentState.stkSent) return;
        _transition(PaymentState.awaitingPin);
      });
      _startPolling();
    } on MpesaException catch (e) {
      debugPrint('[PaymentSM] MpesaException: ${e.message}');
      _transition(PaymentState.failed, error: _friendlyError(e.message));
    } catch (e) {
      debugPrint('[PaymentSM] unexpected: $e');
      _transition(PaymentState.failed,
          error: 'Something went wrong. Please try again.');
    }
  }

  // ─── Polling ───────────────────────────────────────────────────────────────

  void _startPolling() {
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || _state.isTerminal) {
        _pollTimer?.cancel();
        return;
      }

      _pollCount++;

      // Advance from AWAITING_PIN → PROCESSING once enough time has passed.
      if (_pollCount >= _processingThreshold &&
          _state == PaymentState.awaitingPin) {
        _transition(PaymentState.processing);
      }

      // Hard timeout.
      if (_pollCount > _maxPolls) {
        _pollTimer?.cancel();
        _transition(PaymentState.expired);
        return;
      }

      try {
        final status = await MpesaService.pollPaymentStatus(widget.postId);
        if (!mounted || _state.isTerminal) return;

        if (status.isPaid) {
          _pollTimer?.cancel();
          _transition(PaymentState.success, receipt: status.mpesaReceipt);
        } else if (status.isFailed) {
          _pollTimer?.cancel();
          _transition(PaymentState.failed,
              error: 'Payment was declined or cancelled. Please try again.');
        }
        // isPending → keep polling
      } catch (_) {
        // Network glitch during poll — keep going silently.
      }
    });
  }

  // ─── Retry ────────────────────────────────────────────────────────────────

  void _retry() {
    _pollTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    setState(() {
      _state = PaymentState.idle;
      _errorMessage = null;
      _mpesaReceipt = null;
      _pollCount = 0;
      _testStkResult = null;
    });
  }

  // ─── Error sanitisation ───────────────────────────────────────────────────

  static String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('m-pesa number') || lower.contains('phone')) {
      return 'Add a valid M-Pesa number in Profile → Payment Settings.';
    }
    if (lower.contains('no provider')) {
      return 'No provider selected for this service yet.';
    }
    if (lower.contains('already been made') || lower.contains('already in progress')) {
      return 'Payment has already been made for this service.';
    }
    if (lower.contains('network')) {
      return 'Network error. Check your connection and try again.';
    }
    if (lower.contains('daraja') || lower.contains('[daraja]')) {
      return 'M-Pesa service error. Please try again shortly.';
    }
    if (lower.contains('below the minimum')) {
      return 'Service price is below the minimum M-Pesa amount (KES 100).';
    }
    // Pass through friendly backend messages verbatim.
    if (raw.length < 120 && !raw.contains('{') && !raw.contains('Exception')) {
      return raw;
    }
    return 'Payment could not be started. Please try again.';
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return PopScope(
      canPop: !_state.blocksNav,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          elevation: 0,
          automaticallyImplyLeading: false,
          leading: _state.blocksNav
              ? null
              : IconButton(
                  icon: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 20, color: textPrimary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
          title: Text(
            'Secure this service',
            style: TextStyle(
                color: textPrimary, fontWeight: FontWeight.w600, fontSize: 16),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _buildBody(isDark, textPrimary, textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textPrimary, Color textSecondary) {
    switch (_state) {
      case PaymentState.idle:
        return _IdleView(
          key: const ValueKey('idle'),
          title: widget.postTitle,
          amount: widget.amount,
          platformFee: widget.platformFee,
          total: _total,
          onPay: _submit,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
          isDark: isDark,
        );

      case PaymentState.initiating:
        return _StatusView(
          key: const ValueKey('initiating'),
          icon: Icons.lock_rounded,
          iconColor: AppTheme.primaryAccent,
          title: 'Initiating secure payment…',
          subtitle: 'Connecting to M-Pesa. Please wait.',
          showSpinner: true,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );

      case PaymentState.stkSent:
        return _StatusView(
          key: const ValueKey('stk_sent'),
          icon: Icons.send_to_mobile_rounded,
          iconColor: AppTheme.primaryAccent,
          title: 'STK sent to your phone',
          subtitle: 'A payment prompt is on the way to ${widget.buyerPhone}.',
          showSpinner: true,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );

      case PaymentState.awaitingPin:
        return _AwaitingPinView(
          key: const ValueKey('awaiting_pin'),
          phone: widget.buyerPhone,
          onCancel: _retry,
          pulseAnim: _pulseAnim,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );

      case PaymentState.processing:
        return _StatusView(
          key: const ValueKey('processing'),
          icon: Icons.hourglass_top_rounded,
          iconColor: AppTheme.warningOrange,
          title: 'Confirming payment…',
          subtitle: 'Waiting for M-Pesa confirmation. Do not close this screen.',
          showSpinner: true,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );

      case PaymentState.success:
        return _SuccessView(
          key: const ValueKey('success'),
          total: _total,
          receipt: _mpesaReceipt,
          onDone: () => Navigator.of(context).pop(true),
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );

      case PaymentState.failed:
        return _FailedView(
          key: const ValueKey('failed'),
          message: _errorMessage ?? 'Payment failed. Please try again.',
          onRetry: _retry,
          onCancel: () => Navigator.of(context).pop(false),
          testPhoneController: _testPhoneController,
          testStkLoading: _testStkLoading,
          testStkResult: _testStkResult,
          onRunTestStk: _runTestStk,
          textPrimary: textPrimary,
          textSecondary: textSecondary,
          isDark: isDark,
        );

      case PaymentState.expired:
        return _ExpiredView(
          key: const ValueKey('expired'),
          onRetry: _retry,
          onCancel: () => Navigator.of(context).pop(false),
          textPrimary: textPrimary,
          textSecondary: textSecondary,
        );
    }
  }

  // ─── Debug: sandbox test ──────────────────────────────────────────────────

  Future<void> _runTestStk() async {
    final phone = _testPhoneController.text.trim();
    if (phone.isEmpty) return;
    setState(() { _testStkLoading = true; _testStkResult = null; });
    final result = await MpesaService.testStk(phone);
    if (mounted) setState(() { _testStkLoading = false; _testStkResult = result; });
  }
}

// ─── Sub-views (each is its own StatelessWidget for clean keys) ───────────────

class _IdleView extends StatelessWidget {
  final String title;
  final double amount;
  final double platformFee;
  final double total;
  final VoidCallback onPay;
  final Color textPrimary;
  final Color textSecondary;
  final bool isDark;

  const _IdleView({
    super.key,
    required this.title,
    required this.amount,
    required this.platformFee,
    required this.total,
    required this.onPay,
    required this.textPrimary,
    required this.textSecondary,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Service card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.handshake_outlined,
                      color: AppTheme.primaryAccent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text('Service offering',
                          style: TextStyle(color: textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Cost breakdown
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              children: [
                _BreakdownRow(
                  label: 'Service cost',
                  value: 'KES ${amount.toStringAsFixed(0)}',
                  textPrimary: textPrimary,
                  textSecondary: textSecondary,
                ),
                const SizedBox(height: 10),
                Divider(color: borderColor, height: 1),
                const SizedBox(height: 10),
                _BreakdownRow(
                  label: 'Platform fee',
                  value: 'KES ${platformFee.toStringAsFixed(0)}',
                  textPrimary: textSecondary,
                  textSecondary: textSecondary,
                  isSmall: true,
                  tooltip: 'Covers secure escrow & support',
                ),
                const SizedBox(height: 10),
                Divider(color: borderColor, height: 1),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Total to secure',
                        style: TextStyle(
                            color: textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    Text(
                      'KES ${total.toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: AppTheme.successGreen,
                          fontSize: 20,
                          fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Info banners
          _InfoBanner(
            icon: Icons.phone_android_rounded,
            color: AppTheme.primaryAccent,
            text: 'An M-Pesa prompt will be sent to your registered number to authorise this payment.',
            textSecondary: textSecondary,
          ),
          const SizedBox(height: 10),
          _InfoBanner(
            icon: Icons.lock_outline_rounded,
            color: AppTheme.successGreen,
            text: 'Your payment is held securely and only released when the job is completed.',
            textSecondary: textSecondary,
          ),
          const SizedBox(height: 28),

          // Pay button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onPay,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Pay KES ${total.toStringAsFixed(0)} Securely',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('Secured by M-Pesa escrow',
                style: TextStyle(color: textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// Generic status view (initiating, stk_sent, processing)
class _StatusView extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool showSpinner;
  final Color textPrimary;
  final Color textSecondary;

  const _StatusView({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.showSpinner,
    required this.textPrimary,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 48),
            ),
            const SizedBox(height: 28),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 20),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: textSecondary, fontSize: 14, height: 1.5),
            ),
            if (showSpinner) ...[
              const SizedBox(height: 32),
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: iconColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Awaiting PIN — distinct because it has a pulsing phone + cancel button
class _AwaitingPinView extends StatelessWidget {
  final String phone;
  final VoidCallback onCancel;
  final Animation<double> pulseAnim;
  final Color textPrimary;
  final Color textSecondary;

  const _AwaitingPinView({
    super.key,
    required this.phone,
    required this.onCancel,
    required this.pulseAnim,
    required this.textPrimary,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ScaleTransition(
            scale: pulseAnim,
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.phone_android_rounded,
                  color: AppTheme.primaryAccent, size: 52),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Enter Your M-Pesa PIN',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            'An M-Pesa prompt was sent to $phone.\nEnter your PIN on your phone to complete the payment.',
            textAlign: TextAlign.center,
            style: TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 32),
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: AppTheme.primaryAccent),
          ),
          const SizedBox(height: 10),
          Text('Waiting for your PIN…',
              style: TextStyle(color: textSecondary, fontSize: 13)),
          const SizedBox(height: 48),
          TextButton(
            onPressed: onCancel,
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.errorRed, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

// Success view with escrow badge
class _SuccessView extends StatelessWidget {
  final double total;
  final String? receipt;
  final VoidCallback onDone;
  final Color textPrimary;
  final Color textSecondary;

  const _SuccessView({
    super.key,
    required this.total,
    required this.receipt,
    required this.onDone,
    required this.textPrimary,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_rounded,
                color: AppTheme.successGreen, size: 56),
          ),
          const SizedBox(height: 28),
          Text(
            'Payment Secured',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            'KES ${total.toStringAsFixed(0)} is held securely in escrow.\nFunds are released when the job is completed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),

          // Escrow badge
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.successGreen.withValues(alpha: 0.3)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded,
                    size: 15, color: AppTheme.successGreen),
                SizedBox(width: 8),
                Text(
                  'Escrow Active — Payment Secured',
                  style: TextStyle(
                      color: AppTheme.successGreen,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ],
            ),
          ),

          // Receipt
          if (receipt != null) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.successGreen.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.receipt_long_rounded,
                      size: 14, color: AppTheme.successGreen),
                  const SizedBox(width: 8),
                  Text(
                    'Receipt: $receipt',
                    style: const TextStyle(
                        color: AppTheme.successGreen,
                        fontWeight: FontWeight.w600,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 48),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onDone,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.successGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Done',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

// Failed view
class _FailedView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final TextEditingController testPhoneController;
  final bool testStkLoading;
  final Map<String, dynamic>? testStkResult;
  final VoidCallback onRunTestStk;
  final Color textPrimary;
  final Color textSecondary;
  final bool isDark;

  const _FailedView({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onCancel,
    required this.testPhoneController,
    required this.testStkLoading,
    required this.testStkResult,
    required this.onRunTestStk,
    required this.textPrimary,
    required this.textSecondary,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.errorRed.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.error_outline_rounded,
                color: AppTheme.errorRed, size: 56),
          ),
          const SizedBox(height: 24),
          Text('Payment Failed',
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: textSecondary, fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 36),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Try Again',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onCancel,
            child: Text('Cancel',
                style: TextStyle(color: textSecondary, fontSize: 14)),
          ),

          // Debug panel — sandbox only
          if (kDebugMode) ...[
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 8),
            Text('DEBUG — Sandbox STK test',
                style: TextStyle(
                    color: textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(
              controller: testPhoneController,
              keyboardType: TextInputType.phone,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Phone (254XXXXXXXXX)',
                labelStyle: TextStyle(fontSize: 12, color: textSecondary),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: testStkLoading ? null : onRunTestStk,
                icon: testStkLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.science_outlined, size: 16),
                label: const Text('Run /test-stk (amount = 1)',
                    style: TextStyle(fontSize: 11)),
              ),
            ),
            if (testStkResult != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  testStkResult.toString(),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11, height: 1.5),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// Expired view
class _ExpiredView extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final Color textPrimary;
  final Color textSecondary;

  const _ExpiredView({
    super.key,
    required this.onRetry,
    required this.onCancel,
    required this.textPrimary,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.warningOrange.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.timer_off_rounded,
                color: AppTheme.warningOrange, size: 56),
          ),
          const SizedBox(height: 28),
          Text('Payment Expired',
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            'The M-Pesa prompt timed out. If you were charged, check your M-Pesa messages and contact support.',
            textAlign: TextAlign.center,
            style: TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 48),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Try Again',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onCancel,
            child: Text('Cancel',
                style: TextStyle(color: textSecondary, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

// ─── Shared small widgets ──────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final Color textSecondary;

  const _InfoBanner({
    required this.icon,
    required this.color,
    required this.text,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style:
                    TextStyle(color: textSecondary, fontSize: 13, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final Color textPrimary;
  final Color textSecondary;
  final bool isSmall;
  final String? tooltip;

  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.textPrimary,
    required this.textSecondary,
    this.isSmall = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                  color: textPrimary, fontSize: isSmall ? 13 : 14),
            ),
            if (tooltip != null) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: tooltip!,
                child: Icon(Icons.info_outline_rounded,
                    size: 13, color: textSecondary),
              ),
            ],
          ],
        ),
        Text(
          value,
          style: TextStyle(
            color: textPrimary,
            fontSize: isSmall ? 13 : 14,
            fontWeight: isSmall ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
