import 'dart:async';
import 'package:flutter/material.dart';
import '../services/mpesa_service.dart';
import '../theme/app_theme.dart';

enum _PaymentState { idle, processing, waiting, success, failed }

class PaymentScreen extends StatefulWidget {
  /// The post/service ID being paid for.
  final String postId;

  /// Display name of the post/service.
  final String postTitle;

  /// Amount in KES.
  final double amount;

  /// The authenticated buyer's user ID.
  final String buyerUserId;

  const PaymentScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.amount,
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
  static const int _maxPolls = 20; // 20 × 5s = ~100s timeout

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
        // Network glitch — keep polling, don't abort
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
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: _state == _PaymentState.waiting || _state == _PaymentState.processing
            ? const SizedBox.shrink()
            : IconButton(
                icon: Icon(Icons.arrow_back, color: textPrimary),
                onPressed: () => Navigator.of(context).pop(),
              ),
        title: Text(
          'Secure & Pay',
          style: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: _buildBody(cardBg, textPrimary, textSecondary),
      ),
    );
  }

  Widget _buildBody(Color cardBg, Color textPrimary, Color textSecondary) {
    switch (_state) {
      case _PaymentState.idle:
        return _buildIdle(cardBg, textPrimary, textSecondary);
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

  Widget _buildIdle(Color cardBg, Color textPrimary, Color textSecondary) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.receipt_long,
                      color: AppTheme.primaryAccent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.postTitle,
                          style: TextStyle(
                              color: textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text('KES ${widget.amount.toStringAsFixed(0)}',
                          style: const TextStyle(
                              color: AppTheme.primaryAccent,
                              fontWeight: FontWeight.w700,
                              fontSize: 18)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Phone info banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.phone_android,
                    color: AppTheme.primaryAccent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Payment will be sent to your registered M-Pesa number.',
                    style: TextStyle(
                        color: textSecondary, fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Pay Securely',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),

          const SizedBox(height: 12),
          Center(
            child: Text(
              'You will receive a PIN prompt on your phone',
              style: TextStyle(color: textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessing(Color textPrimary, Color textSecondary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppTheme.primaryAccent),
          const SizedBox(height: 24),
          Text('Sending payment request…',
              style: TextStyle(
                  color: textPrimary, fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 8),
          Text('Please wait', style: TextStyle(color: textSecondary, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildWaiting(Color textPrimary, Color textSecondary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.phone_android,
                color: AppTheme.primaryAccent, size: 48),
          ),
          const SizedBox(height: 28),
          Text('Check Your Phone',
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            'An M-Pesa PIN prompt has been sent to your phone.\nEnter your PIN to complete the payment.',
            textAlign: TextAlign.center,
            style: TextStyle(color: textSecondary, fontSize: 14, height: 1.5),
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
                style: TextStyle(color: AppTheme.errorRed, fontSize: 14)),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess(Color textPrimary, Color textSecondary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle,
                color: AppTheme.successGreen, size: 56),
          ),
          const SizedBox(height: 28),
          Text('Payment Successful',
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22)),
          const SizedBox(height: 12),
          Text('Your payment has been received and is held in escrow.',
              textAlign: TextAlign.center,
              style: TextStyle(color: textSecondary, fontSize: 14, height: 1.5)),
          if (_mpesaReceipt != null) ...[
            const SizedBox(height: 20),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Receipt: $_mpesaReceipt',
                  style: const TextStyle(
                      color: AppTheme.successGreen,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailed(Color textPrimary, Color textSecondary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.errorRed.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.error_outline,
                color: AppTheme.errorRed, size: 56),
          ),
          const SizedBox(height: 28),
          Text('Payment Failed',
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _errorMessage ?? 'Something went wrong. Please try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: textSecondary, fontSize: 14, height: 1.5),
            ),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Try Again',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
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
