import 'dart:async';
import 'package:flutter/material.dart';
import '../services/mpesa_service.dart';
import '../theme/app_theme.dart';

enum _PaymentState { idle, processing, waiting, success, failed }

/// Mirror of backend fee-tier table — keeps frontend display in sync.
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

class PaymentScreen extends StatefulWidget {
  /// The post/service ID being paid for.
  final String postId;

  /// Display name of the post/service.
  final String postTitle;

  /// Service cost in KES (before platform fee).
  final double amount;

  /// Pre-calculated platform fee — pass [calculatePlatformFee(amount)] at call site.
  final double platformFee;

  /// The authenticated buyer's user ID.
  final String buyerUserId;

  const PaymentScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.amount,
    required this.platformFee,
    required this.buyerUserId,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  _PaymentState _state = _PaymentState.idle;
  String? _errorMessage;
  String? _mpesaReceipt;

  Timer? _pollTimer;
  int _pollCount = 0;
  static const int _maxPolls = 24; // 24 × 5s ≈ 2 min timeout

  double get _total => widget.amount + widget.platformFee;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _state = _PaymentState.processing;
      _errorMessage = null;
    });

    try {
      await MpesaService.initiatePayment(
        postId: widget.postId,
        buyerUserId: widget.buyerUserId,
      );
      setState(() => _state = _PaymentState.waiting);
      _startPolling();
    } on MpesaException catch (e) {
      setState(() {
        _state = _PaymentState.failed;
        _errorMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _state = _PaymentState.failed;
        _errorMessage = 'Unexpected error. Please try again.';
      });
    }
  }

  void _startPolling() {
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      _pollCount++;
      if (_pollCount > _maxPolls) {
        _pollTimer?.cancel();
        if (mounted) {
          setState(() {
            _state = _PaymentState.failed;
            _errorMessage =
                'Payment confirmation timed out. Check M-Pesa messages and contact support if charged.';
          });
        }
        return;
      }

      try {
        final status = await MpesaService.pollPaymentStatus(widget.postId);
        if (!mounted) return;

        if (status.isPaid) {
          _pollTimer?.cancel();
          setState(() {
            _state = _PaymentState.success;
            _mpesaReceipt = status.mpesaReceipt;
          });
        } else if (status.isFailed) {
          _pollTimer?.cancel();
          setState(() {
            _state = _PaymentState.failed;
            _errorMessage =
                status.failureReason ?? 'Payment was declined. Please try again.';
          });
        }
        // isPending → keep polling
      } catch (_) {
        // Network glitch during poll — keep going
      }
    });
  }

  void _retry() {
    _pollTimer?.cancel();
    setState(() {
      _state = _PaymentState.idle;
      _errorMessage = null;
      _mpesaReceipt = null;
      _pollCount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: (_state == _PaymentState.waiting ||
                _state == _PaymentState.processing)
            ? const SizedBox.shrink()
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
        child: _buildBody(isDark, textPrimary, textSecondary),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textPrimary, Color textSecondary) {
    switch (_state) {
      case _PaymentState.idle:
        return _buildIdle(isDark, textPrimary, textSecondary);
      case _PaymentState.processing:
        return _buildProcessing(textPrimary, textSecondary);
      case _PaymentState.waiting:
        return _buildWaiting(textPrimary, textSecondary);
      case _PaymentState.success:
        return _buildSuccess(textPrimary, textSecondary);
      case _PaymentState.failed:
        return _buildFailed(textPrimary, textSecondary);
    }
  }

  // ── Idle ──────────────────────────────────────────────────────────────────

  Widget _buildIdle(bool isDark, Color textPrimary, Color textSecondary) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final dividerColor = borderColor;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Service summary card ───────────────────────────────────────────
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
                        widget.postTitle,
                        style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Service offering',
                        style:
                            TextStyle(color: textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── Cost breakdown ─────────────────────────────────────────────────
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
                  value: 'KES ${widget.amount.toStringAsFixed(0)}',
                  textPrimary: textPrimary,
                  textSecondary: textSecondary,
                ),
                const SizedBox(height: 10),
                Divider(color: dividerColor, height: 1),
                const SizedBox(height: 10),
                _BreakdownRow(
                  label: 'Platform fee',
                  value: 'KES ${widget.platformFee.toStringAsFixed(0)}',
                  textPrimary: textSecondary,
                  textSecondary: textSecondary,
                  isSmall: true,
                  tooltip: 'Covers secure escrow & support',
                ),
                const SizedBox(height: 10),
                Divider(color: dividerColor, height: 1),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total to secure',
                      style: TextStyle(
                          color: textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'KES ${_total.toStringAsFixed(0)}',
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

          // ── STK prompt notice ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.22)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.phone_android_rounded,
                      color: AppTheme.primaryAccent, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'You will receive an M-Pesa prompt to securely authorize this payment.',
                    style: TextStyle(
                        color: textSecondary, fontSize: 13, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // ── Escrow trust statement ─────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.successGreen.withValues(alpha: 0.22)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.lock_outline_rounded,
                      color: AppTheme.successGreen, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your payment is held securely and only released when the job is completed.',
                    style: TextStyle(
                        color: textSecondary, fontSize: 13, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Pay button ─────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _submit,
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
                    'Pay KES ${_total.toStringAsFixed(0)} Securely',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'Secured by M-Pesa escrow',
              style: TextStyle(color: textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Processing ────────────────────────────────────────────────────────────

  Widget _buildProcessing(Color textPrimary, Color textSecondary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
              color: AppTheme.primaryAccent, strokeWidth: 2.5),
          const SizedBox(height: 24),
          Text(
            'Sending payment request…',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text('Please wait',
              style: TextStyle(color: textSecondary, fontSize: 14)),
        ],
      ),
    );
  }

  // ── Waiting for PIN ───────────────────────────────────────────────────────

  Widget _buildWaiting(Color textPrimary, Color textSecondary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.phone_android_rounded,
                color: AppTheme.primaryAccent, size: 52),
          ),
          const SizedBox(height: 28),
          Text(
            'Check Your Phone',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22),
          ),
          const SizedBox(height: 14),
          Text(
            'An M-Pesa PIN prompt has been sent to your phone.\nEnter your PIN to complete the payment.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 32),
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: AppTheme.primaryAccent),
          ),
          const SizedBox(height: 12),
          Text('Waiting for confirmation…',
              style: TextStyle(color: textSecondary, fontSize: 13)),
          const SizedBox(height: 48),
          TextButton(
            onPressed: _retry,
            child: const Text('Cancel',
                style:
                    TextStyle(color: AppTheme.errorRed, fontSize: 14)),
          ),
        ],
      ),
    );
  }

  // ── Success ───────────────────────────────────────────────────────────────

  Widget _buildSuccess(Color textPrimary, Color textSecondary) {
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
            'Payment Successful',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            'KES ${_total.toStringAsFixed(0)} secured.\nFunds are held in escrow until the job is completed.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),
          if (_mpesaReceipt != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.successGreen.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.receipt_long_rounded,
                      size: 16, color: AppTheme.successGreen),
                  const SizedBox(width: 8),
                  Text(
                    'Receipt: $_mpesaReceipt',
                    style: const TextStyle(
                        color: AppTheme.successGreen,
                        fontWeight: FontWeight.w600,
                        fontSize: 13),
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
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.successGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Done',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Failed ────────────────────────────────────────────────────────────────

  Widget _buildFailed(Color textPrimary, Color textSecondary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
          const SizedBox(height: 28),
          Text(
            'Payment Failed',
            style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            _errorMessage ?? 'Something went wrong. Please try again.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: textSecondary, fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 48),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _retry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Try Again',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: textSecondary, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

// ── Breakdown row ─────────────────────────────────────────────────────────────

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
                color: textPrimary,
                fontSize: isSmall ? 13 : 14,
              ),
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
