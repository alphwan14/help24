import 'package:flutter/material.dart';
import '../services/jobs_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

enum _DecisionState { idle, approving, disputing, approved, disputed, error }

/// Client screen: review a completion request — approve (releases funds) or dispute (freezes escrow).
class ApproveOrDisputeScreen extends StatefulWidget {
  final String postId;
  final String postTitle;
  final String clientUserId;
  final String? providerNote;
  final double amount;

  const ApproveOrDisputeScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.clientUserId,
    this.providerNote,
    required this.amount,
  });

  @override
  State<ApproveOrDisputeScreen> createState() => _ApproveOrDisputeScreenState();
}

class _ApproveOrDisputeScreenState extends State<ApproveOrDisputeScreen> {
  _DecisionState _state = _DecisionState.idle;
  String? _errorMessage;
  final _disputeReasonController = TextEditingController();

  @override
  void dispose() {
    _disputeReasonController.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    setState(() {
      _state = _DecisionState.approving;
      _errorMessage = null;
    });
    try {
      await JobsService.approve(
        postId: widget.postId,
        clientUserId: widget.clientUserId,
      );
      if (mounted) setState(() => _state = _DecisionState.approved);
    } on JobsException catch (e) {
      if (mounted) setState(() {
        _state = _DecisionState.error;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (mounted) setState(() {
        _state = _DecisionState.error;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _dispute() async {
    final reason = _disputeReasonController.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please describe the reason for your dispute.'),
          backgroundColor: AppTheme.warningOrange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _state = _DecisionState.disputing;
      _errorMessage = null;
    });

    try {
      await JobsService.dispute(
        postId: widget.postId,
        clientUserId: widget.clientUserId,
        reason: reason,
      );
      if (mounted) setState(() => _state = _DecisionState.disputed);
    } on JobsException catch (e) {
      if (mounted) setState(() {
        _state = _DecisionState.error;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (mounted) setState(() {
        _state = _DecisionState.error;
        _errorMessage = 'Failed to open dispute. Please try again.';
      });
    }
  }

  void _showDisputeSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? AppTheme.darkCard : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white54 : Colors.black54;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: textSecondary.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.flag_rounded, color: Colors.red, size: 20),
                ),
                const SizedBox(width: 12),
                Text('Open a Dispute',
                    style: TextStyle(
                        color: textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 18)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Describe why you\'re disputing this completion. Funds will be frozen pending admin review.',
              style: TextStyle(color: textSecondary, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _disputeReasonController,
              maxLines: 4,
              maxLength: 1000,
              autofocus: true,
              style: TextStyle(color: textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText:
                    'e.g. The provider did not deliver what was agreed upon. Specifically…',
                hintStyle: TextStyle(color: textSecondary, fontSize: 13),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withOpacity(0.06)
                    : Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
                counterStyle: TextStyle(color: textSecondary, fontSize: 11),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _dispute();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.flag_rounded, size: 18),
                label: const Text('Submit Dispute',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final card = isDark ? AppTheme.darkCard : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white54 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Review Completion',
            style: TextStyle(
                color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _buildBody(
          isDark: isDark,
          bg: bg,
          card: card,
          textPrimary: textPrimary,
          textSecondary: textSecondary),
    );
  }

  Widget _buildBody({
    required bool isDark,
    required Color bg,
    required Color card,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    if (_state == _DecisionState.approved) {
      return _OutcomeView(
        icon: Icons.check_circle_rounded,
        iconColor: AppTheme.successGreen,
        title: 'Payment Released!',
        subtitle:
            'You approved the job. The provider\'s M-Pesa payout has been initiated.',
        buttonLabel: 'Done',
        textPrimary: textPrimary,
        onPressed: () => Navigator.pop(context, 'approved'),
      );
    }

    if (_state == _DecisionState.disputed) {
      return _OutcomeView(
        icon: Icons.shield_rounded,
        iconColor: AppTheme.warningOrange,
        title: 'Dispute Submitted',
        subtitle:
            'Your dispute is under review. Funds are frozen. Admin will respond within 24-48 hours.',
        buttonLabel: 'Done',
        textPrimary: textPrimary,
        onPressed: () => Navigator.pop(context, 'disputed'),
      );
    }

    final isInFlight = _state == _DecisionState.approving ||
        _state == _DecisionState.disputing;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Job info card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: card, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryAccent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.work_outline_rounded,
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
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            '${formatPriceDisplay(widget.amount)} in escrow',
                            style: TextStyle(
                                color: AppTheme.primaryAccent,
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.providerNote != null &&
                    widget.providerNote!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 14),
                  Text('Provider Note',
                      style: TextStyle(
                          color: textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(widget.providerNote!,
                      style: TextStyle(
                          color: textPrimary, fontSize: 14, height: 1.4)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Escrow info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded,
                    color: AppTheme.primaryAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Funds are held in escrow. Approving releases them to the provider. Disputing freezes them for admin review.',
                    style: TextStyle(
                        color: textSecondary, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (_state == _DecisionState.error && _errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded,
                    color: Colors.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_errorMessage!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 13))),
              ]),
            ),
          ],

          const SizedBox(height: 28),

          // Approve button
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: isInFlight ? null : _approve,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.successGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: _state == _DecisionState.approving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 22),
              label: Text(
                _state == _DecisionState.approving
                    ? 'Releasing Payment…'
                    : 'Approve & Release Payment',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Dispute button
          SizedBox(
            width: double.infinity,
            height: 54,
            child: OutlinedButton.icon(
              onPressed: isInFlight ? null : _showDisputeSheet,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.red.withOpacity(0.6)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: _state == _DecisionState.disputing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.red))
                  : const Icon(Icons.flag_outlined, size: 20, color: Colors.red),
              label: Text(
                _state == _DecisionState.disputing
                    ? 'Submitting Dispute…'
                    : 'Open Dispute',
                style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                    fontSize: 15),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _OutcomeView extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final Color textPrimary;
  final VoidCallback onPressed;

  const _OutcomeView({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.textPrimary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 56),
            ),
            const SizedBox(height: 24),
            Text(title,
                style: TextStyle(
                    color: textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 22)),
            const SizedBox(height: 12),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: textPrimary.withOpacity(0.6),
                    fontSize: 14,
                    height: 1.5)),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: iconColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(buttonLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
