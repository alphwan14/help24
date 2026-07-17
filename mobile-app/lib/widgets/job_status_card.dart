import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/auth_provider.dart';
import '../services/jobs_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/payment_utils.dart';
import '../utils/phone_utils.dart';
import '../services/mpesa_service.dart';
import '../screens/payment_screen.dart';
import '../screens/mark_complete_screen.dart';
import '../screens/approve_or_dispute_screen.dart';
import '../screens/job_lifecycle_screen.dart';

// ── Data model ──────────────────────────────────────────────────────────────

enum _JobState {
  loading,
  noProvider,       // no selected_provider_id — card should not render
  awaitingPayment,  // STATE 1: provider selected, payment not secured
  paymentSecured,   // STATE 2: payment locked in escrow, waiting for completion
  completionPending,// STATE 3: provider marked complete, waiting for client approval
  payoutProcessing, // payout dispatched to provider, awaiting B2C confirmation
  completed,        // STATE 4: payment released, job done
  disputed,         // escrow frozen, admin reviewing
  error,
}

class _JobData {
  final String postTitle;
  final double postPrice;
  final String authorUserId;
  final String? selectedProviderId;
  final String? transactionStatus; // 'paid', 'payout_pending', 'released', etc.
  final String? escrowStatus;
  final JobCompletionStatus? completion;

  const _JobData({
    required this.postTitle,
    required this.postPrice,
    required this.authorUserId,
    required this.selectedProviderId,
    this.transactionStatus,
    this.escrowStatus,
    this.completion,
  });

  _JobState get state {
    if (selectedProviderId == null || selectedProviderId!.isEmpty) {
      return _JobState.noProvider;
    }

    // Payout dispatched but not yet confirmed by the B2C callback. This is NOT a
    // released/completed state — it must never render as "paid"/"completed" even
    // when the completion was approved or the dispute ruled FULL_RELEASE. Checked
    // BEFORE completion.isApproved so a stuck payout_pending can't read as settled.
    if (transactionStatus == 'payout_pending' || escrowStatus == 'payout_pending') {
      return _JobState.payoutProcessing;
    }

    // Determine from completion first (most specific).
    if (completion != null) {
      if (completion!.isApproved) return _JobState.completed;
      if (completion!.isDisputed) return _JobState.disputed;
      if (completion!.isPendingApproval) return _JobState.completionPending;
    }

    // Escrow/transaction status.
    if (escrowStatus == 'released') return _JobState.completed;
    if (escrowStatus == 'disputed' || transactionStatus == 'disputed') {
      return _JobState.disputed;
    }
    if (transactionStatus == 'paid' ||
        transactionStatus == 'payout_pending' ||
        escrowStatus == 'locked' ||
        escrowStatus == 'payout_pending') {
      return _JobState.paymentSecured;
    }

    // Provider selected but no payment confirmed yet.
    return _JobState.awaitingPayment;
  }
}

// ── Widget ──────────────────────────────────────────────────────────────────

/// Persistent escrow workflow card shown inside ChatScreen, just below the post context banner.
///
/// Polls job state every 30 seconds and refreshes after any action the user takes.
/// Only rendered when the chat has a non-empty postId.
class JobStatusCard extends StatefulWidget {
  final String postId;
  final String currentUserId;

  const JobStatusCard({
    super.key,
    required this.postId,
    required this.currentUserId,
  });

  @override
  State<JobStatusCard> createState() => JobStatusCardState();
}

class JobStatusCardState extends State<JobStatusCard> with WidgetsBindingObserver {
  _JobData? _data;
  _JobState _state = _JobState.loading;
  String? _error;
  Timer? _pollTimer;
  bool _actionLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    // Poll every 30 seconds to stay in sync with backend events.
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadData(silent: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh when app is brought back to foreground — important after leaving to pay.
    if (state == AppLifecycleState.resumed) _loadData(silent: true);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Called externally (e.g., after navigating back from MarkCompleteScreen).
  void refresh() => _loadData(silent: true);

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      if (mounted) setState(() { _state = _JobState.loading; _error = null; });
    }

    try {
      final supabase = Supabase.instance.client;

      // Load post data.
      final postRes = await supabase
          .from('posts')
          .select('title, price, author_user_id, selected_provider_id, status')
          .eq('id', widget.postId)
          .maybeSingle();

      if (postRes == null) {
        if (mounted) setState(() { _state = _JobState.error; _error = 'Post not found.'; });
        return;
      }

      // Load payment + escrow status from the backend (service-role). The client
      // no longer reads the RLS-locked transactions/escrow tables directly (S2
      // security lockdown). A 404 means no payment has been initiated yet.
      String? txStatus;
      String? escrowStatus;
      try {
        final pay = await MpesaService.pollPaymentStatus(widget.postId);
        txStatus = pay.status;
        escrowStatus = pay.escrowStatus;
      } on MpesaException catch (e) {
        if (e.statusCode != 404) rethrow; // 404 = no payment yet; anything else surfaces
      }

      // Load job completion status from backend.
      final completion = await JobsService.getJobStatus(widget.postId);

      if (!mounted) return;

      final data = _JobData(
        postTitle: postRes['title']?.toString() ?? '',
        postPrice: ((postRes['price'] ?? 0) as num).toDouble(),
        authorUserId: postRes['author_user_id']?.toString() ?? '',
        selectedProviderId: postRes['selected_provider_id']?.toString(),
        transactionStatus: txStatus,
        escrowStatus: escrowStatus,
        completion: completion,
      );

      setState(() {
        _data = data;
        _state = data.state;
        _error = null;
      });
    } catch (e) {
      debugPrint('[JobStatusCard] load error: $e');
      if (mounted && !silent) {
        setState(() { _state = _JobState.error; _error = 'Could not load job status.'; });
      }
    }
  }

  // ── Action: Secure Payment ────────────────────────────────────────────────

  Future<void> _securePayment() async {
    final data = _data;
    if (data == null || _actionLoading) return;

    setState(() => _actionLoading = true);
    try {
      // Fetch buyer phone.
      String? rawPhone = await UserProfileService.getMpesaPhone(widget.currentUserId);
      if (!mounted) return;

      // Firebase phone fallback.
      if (rawPhone == null || rawPhone.isEmpty) {
        final fbPhone = context.read<AuthProvider>().currentUser?.phoneNumber;
        if (fbPhone != null && fbPhone.isNotEmpty) rawPhone = fbPhone;
      }

      final normalizedPhone = rawPhone != null ? normalizeKenyanNumber(rawPhone) : null;

      if (normalizedPhone == null) {
        _showSnack(
          'Add a valid M-Pesa number in Profile → Payment Settings.',
          color: AppTheme.warningOrange,
          icon: Icons.phone_android_rounded,
        );
        return;
      }

      final fee = calculatePlatformFee(data.postPrice);
      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PaymentScreen(
            postId: widget.postId,
            postTitle: data.postTitle,
            amount: data.postPrice,
            platformFee: fee,
            buyerUserId: widget.currentUserId,
            buyerPhone: normalizedPhone,
          ),
        ),
      ).then((_) => _loadData(silent: true)); // refresh on return
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  // ── Action: Mark Work Complete (provider) ─────────────────────────────────

  void _markComplete() {
    final data = _data;
    if (data == null || data.selectedProviderId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarkCompleteScreen(
          postId: widget.postId,
          postTitle: data.postTitle,
          providerUserId: widget.currentUserId,
        ),
      ),
    ).then((_) => _loadData(silent: true));
  }

  // ── Action: Release Payment / Report Problem (client) ────────────────────

  void _reviewCompletion() {
    final data = _data;
    if (data == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApproveOrDisputeScreen(
          postId: widget.postId,
          postTitle: data.postTitle,
          clientUserId: widget.currentUserId,
          providerNote: data.completion?.providerNote,
          amount: data.postPrice,
        ),
      ),
    ).then((_) => _loadData(silent: true));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnack(String msg, {required Color color, required IconData icon}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Flexible(child: Text(msg)),
      ]),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 4),
    ));
  }

  bool get _isClient => _data?.authorUserId == widget.currentUserId;
  bool get _isProvider => _data?.selectedProviderId == widget.currentUserId;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Don't render if no postId or no provider selected yet.
    if (_state == _JobState.noProvider) return const SizedBox.shrink();
    if (_state == _JobState.loading && _data == null) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _borderColor(isDark),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(isDark),
            const SizedBox(height: 10),
            _buildStateContent(isDark),
            const SizedBox(height: 10),
            _buildLifecycleLink(isDark),
          ],
        ),
      ),
    );
  }

  // Entry point to the full Job Lifecycle Detail screen, so participants can open
  // the complete payment/dispute/payout timeline directly from the job chat
  // (previously reachable only via a notification tap).
  Widget _buildLifecycleLink(bool isDark) {
    final divider = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    return Column(
      children: [
        Divider(height: 1, color: divider),
        InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => JobLifecycleScreen(postId: widget.postId)),
          ),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.receipt_long_rounded, size: 15, color: AppTheme.primaryAccent),
                const SizedBox(width: 6),
                Text(
                  'View full job details',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.primaryAccent),
                ),
                Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.primaryAccent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Color _borderColor(bool isDark) {
    switch (_state) {
      case _JobState.completed:
        return AppTheme.successGreen.withValues(alpha: 0.5);
      case _JobState.completionPending:
      case _JobState.payoutProcessing:
        return AppTheme.warningOrange.withValues(alpha: 0.5);
      case _JobState.disputed:
        return AppTheme.errorRed.withValues(alpha: 0.5);
      case _JobState.paymentSecured:
        return AppTheme.primaryAccent.withValues(alpha: 0.35);
      default:
        return isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    }
  }

  Widget _buildHeader(bool isDark) {
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Row(
      children: [
        Icon(Icons.lock_outline_rounded, size: 13, color: textTertiary),
        const SizedBox(width: 5),
        Text(
          'JOB STATUS',
          style: TextStyle(
            color: textTertiary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const Spacer(),
        if (_state == _JobState.loading)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: textTertiary,
            ),
          ),
      ],
    );
  }

  Widget _buildStateContent(bool isDark) {
    switch (_state) {
      case _JobState.awaitingPayment:
        return _buildAwaitingPayment(isDark);
      case _JobState.paymentSecured:
        return _buildPaymentSecured(isDark);
      case _JobState.completionPending:
        return _buildCompletionPending(isDark);
      case _JobState.payoutProcessing:
        return _buildPayoutProcessing(isDark);
      case _JobState.completed:
        return _buildCompleted(isDark);
      case _JobState.disputed:
        return _buildDisputed(isDark);
      case _JobState.error:
        return _buildError(isDark);
      case _JobState.loading:
        return _buildSilentLoadingPlaceholder(isDark);
      default:
        return const SizedBox.shrink();
    }
  }

  // STATE 1 ─────────────────────────────────────────────────────────────────

  Widget _buildAwaitingPayment(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Provider selected', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.radio_button_unchecked_rounded, color: textSecondary, label: 'Payment not secured yet', isDone: false),
        const SizedBox(height: 12),
        if (_isClient) ...[
          Text(
            'Secure payment to begin work. Funds are held safely by Help24 until the job is complete.',
            style: TextStyle(color: textSecondary, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _actionLoading ? null : _securePayment,
              icon: _actionLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.lock_rounded, size: 17),
              label: Text(_actionLoading ? 'Loading…' : 'Secure Payment'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ] else if (_isProvider) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warningOrange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.hourglass_top_rounded, size: 15, color: AppTheme.warningOrange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waiting for the client to secure payment.',
                    style: TextStyle(color: textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // STATE 2 ─────────────────────────────────────────────────────────────────

  Widget _buildPaymentSecured(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Provider selected', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Payment secured', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.hourglass_top_rounded, color: AppTheme.warningOrange, label: 'Waiting for provider to complete', isDone: false),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.successGreen.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.lock_rounded, size: 15, color: AppTheme.successGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isClient
                      ? 'Your payment is held safely by Help24. It is released only when you approve.'
                      : 'Payment is secured. Complete the work and mark it done.',
                  style: TextStyle(color: textPrimary, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        if (_isProvider) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _markComplete,
              icon: const Icon(Icons.task_alt_rounded, size: 17),
              label: const Text('Mark Work Complete'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
        if (_isClient)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _data != null
                  ? 'Protected amount: ${formatPriceDisplay(_data!.postPrice)}'
                  : '',
              style: TextStyle(color: textSecondary, fontSize: 12),
            ),
          ),
      ],
    );
  }

  // STATE 3 ─────────────────────────────────────────────────────────────────

  Widget _buildCompletionPending(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final providerNote = _data?.completion?.providerNote;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Provider selected', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Payment secured', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.warningOrange, label: 'Work marked as completed', isDone: true),
        const SizedBox(height: 12),

        if (providerNote != null && providerNote.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkBorder.withValues(alpha: 0.5) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Provider note:',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  providerNote,
                  style: TextStyle(color: textPrimary, fontSize: 12.5, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        if (_isClient) ...[
          Text(
            'Did the provider complete the work satisfactorily?',
            style: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _reviewCompletion,
                  icon: const Icon(Icons.check_rounded, size: 17),
                  label: const Text('Release Payment'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.successGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _reviewCompletion,
                  icon: const Icon(Icons.flag_outlined, size: 17),
                  label: const Text('Report Problem'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.errorRed,
                    side: const BorderSide(color: AppTheme.errorRed, width: 1),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ] else if (_isProvider) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warningOrange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.hourglass_top_rounded, size: 15, color: AppTheme.warningOrange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waiting for client to review and release payment.',
                    style: TextStyle(color: textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // STATE: payout dispatched, awaiting confirmation ──────────────────────────
  // Truthful state for a payout that has been initiated (B2C) but whose result
  // callback has not yet confirmed. Must NOT claim the provider has been paid.
  Widget _buildPayoutProcessing(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Provider selected', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Payment secured', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Work completed & approved', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.hourglass_top_rounded, color: AppTheme.warningOrange, label: 'Payout awaiting confirmation', isDone: false),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.warningOrange.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.hourglass_bottom_rounded, size: 16, color: AppTheme.warningOrange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Payout has been initiated and is awaiting confirmation.',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // STATE 4 ─────────────────────────────────────────────────────────────────

  Widget _buildCompleted(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Provider selected', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Payment secured', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Work completed & approved', isDone: true),
        const SizedBox(height: 6),
        _StepRow(icon: Icons.check_circle_rounded, color: AppTheme.successGreen, label: 'Payment released', isDone: true),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.successGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.celebration_rounded, size: 16, color: AppTheme.successGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Transaction completed successfully.',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // DISPUTED ─────────────────────────────────────────────────────────────────

  Widget _buildDisputed(bool isDark) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(icon: Icons.shield_rounded, color: AppTheme.errorRed, label: 'Dispute in progress', isDone: false),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.errorRed.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.lock_clock_rounded, size: 15, color: AppTheme.errorRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Funds are frozen. Admin is reviewing your dispute and will resolve it within 24-48 hours.',
                  style: TextStyle(color: textPrimary, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildError(bool isDark) {
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      children: [
        Icon(Icons.info_outline_rounded, size: 15, color: textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _error ?? 'Could not load job status.',
            style: TextStyle(color: textSecondary, fontSize: 12.5),
          ),
        ),
        TextButton(
          onPressed: () => _loadData(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildSilentLoadingPlaceholder(bool isDark) {
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: textSecondary),
        ),
        const SizedBox(width: 8),
        Text('Loading status…', style: TextStyle(color: textSecondary, fontSize: 12.5)),
      ],
    );
  }
}

// ── Shared step row widget ────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final bool isDone;

  const _StepRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.isDone,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            color: isDone ? textPrimary : textSecondary,
            fontSize: 12.5,
            fontWeight: isDone ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
