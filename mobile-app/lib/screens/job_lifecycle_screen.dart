import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/job_lifecycle.dart';
import '../providers/auth_provider.dart';
import '../services/jobs_service.dart';
import '../services/review_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import 'approve_or_dispute_screen.dart';
import 'review_submission_screen.dart';

/// Job Lifecycle Detail — the single, unified surface for a job's progress:
/// payment, completion, dispute and payout, plus a chronological timeline.
///
/// Drives entirely off GET /jobs/:postId/lifecycle (the backend is the source of
/// truth). No lifecycle state is stored or recomputed locally beyond mapping raw
/// statuses to human-readable stages.
class JobLifecycleScreen extends StatefulWidget {
  final String postId;
  final String? postTitle;

  const JobLifecycleScreen({super.key, required this.postId, this.postTitle});

  @override
  State<JobLifecycleScreen> createState() => _JobLifecycleScreenState();
}

class _JobLifecycleScreenState extends State<JobLifecycleScreen> {
  JobLifecycle? _data;
  bool _loading = true;
  String? _error;
  ReviewEligibility? _reviewEligibility;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid == null || uid.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Please sign in to view this job.';
      });
      return;
    }
    try {
      final data = await JobsService.getLifecycle(postId: widget.postId, userId: uid);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
      // Best-effort review eligibility (drives the "Leave Review" button — entry 2).
      final elig = await ReviewService.checkEligibility(postId: widget.postId, userId: uid);
      if (!mounted) return;
      setState(() => _reviewEligibility = elig);
    } on JobsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load job status. Pull to retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      appBar: AppBar(
        title: Text(_data?.post.title ?? widget.postTitle ?? 'Job Status'),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(isDark),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.error_outline, size: 48, color: AppTheme.errorRed),
          const SizedBox(height: 12),
          Center(child: Text(_error!, textAlign: TextAlign.center)),
        ],
      );
    }
    final d = _data!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _summaryCard(d, isDark),
        const SizedBox(height: 12),
        _paymentSection(d, isDark),
        const SizedBox(height: 12),
        _completionSection(d, isDark),
        const SizedBox(height: 12),
        if (d.dispute != null) ...[
          _disputeSection(d, isDark),
          const SizedBox(height: 12),
        ],
        _timelineSection(d, isDark),
        if (_showReviewCta(d)) ...[
          const SizedBox(height: 20),
          _reviewCta(d),
        ],
        _reviewProviderSection(d),
      ],
    );
  }

  // ── Leave-a-review CTA (client, completed + approved + eligible) ────────────

  Widget _reviewProviderSection(JobLifecycle d) {
    final e = _reviewEligibility;
    if (e == null) return const SizedBox.shrink();
    if (e.alreadyReviewed) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 18, color: AppTheme.successGreen),
            const SizedBox(width: 6),
            const Text('Review submitted', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    if (e.canReview) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _openLeaveReview,
            icon: const Icon(Icons.star_rounded),
            label: const Text('Leave Review'),
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Future<void> _openLeaveReview() async {
    final uid = context.read<AuthProvider>().currentUserId ?? '';
    final d = _data;
    if (d == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReviewSubmissionScreen(
        postId: d.post.id,
        clientUserId: uid,
        postTitle: d.post.title,
      ),
    ));
    if (mounted) _load(); // refresh eligibility (now reviewed)
  }

  // ── Sections ────────────────────────────────────────────────────────────────

  Widget _summaryCard(JobLifecycle d, bool isDark) {
    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d.post.title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              _pill(_postStatusLabel(d.post.status), _postStatusColor(d.post.status)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatPriceDisplay(d.post.price),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentSection(JobLifecycle d, bool isDark) {
    final special = _paymentSpecial(d); // refunded / frozen banner, or null
    final stages = ['Payment Required', 'Payment Secured', 'Escrow Locked', 'Payout Pending', 'Payout Released'];
    final current = _paymentStageIndex(d);
    return _sectionCard(
      isDark,
      icon: Icons.account_balance_wallet_outlined,
      title: 'Payment',
      pill: special != null ? _pill(special.$1, special.$2) : null,
      child: _StageTrack(stages: stages, currentIndex: current, isDark: isDark),
    );
  }

  Widget _completionSection(JobLifecycle d, bool isDark) {
    final stages = ['In Progress', 'Completion Requested', 'Awaiting Approval', 'Approved'];
    final current = _completionStageIndex(d);
    final disputed = d.completion?.status == 'disputed';
    final note = d.completion?.providerNote;
    return _sectionCard(
      isDark,
      icon: Icons.task_alt_outlined,
      title: 'Completion',
      pill: disputed ? _pill('Disputed', AppTheme.errorRed) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StageTrack(stages: stages, currentIndex: current, isDark: isDark),
          if (note != null && note.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _noteBox("Provider's note", note, isDark),
          ],
        ],
      ),
    );
  }

  Widget _disputeSection(JobLifecycle d, bool isDark) {
    final dispute = d.dispute!;
    final stage = _disputeStageLabel(dispute.status);
    final stageColor = _disputeStageColor(dispute.status);
    final decision = dispute.finalDecision;
    return _sectionCard(
      isDark,
      icon: Icons.gavel_outlined,
      title: 'Dispute',
      pill: _pill(stage, stageColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StageTrack(
            stages: const ['Submitted', 'Under Review', 'Resolved'],
            currentIndex: _disputeStageIndex(dispute.status),
            isDark: isDark,
            branchLabel: dispute.status == 'escalated' ? 'Escalated to senior admin' : null,
          ),
          if (dispute.reason != null && dispute.reason!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _noteBox('Reason', dispute.reason!, isDark),
          ],
          if (_isResolved(dispute.status)) ...[
            const SizedBox(height: 10),
            _outcomeBox(dispute, decision, isDark),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              'Funds are frozen while an admin reviews this dispute. You will be notified of the outcome.',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timelineSection(JobLifecycle d, bool isDark) {
    if (d.timeline.isEmpty) return const SizedBox.shrink();
    return _sectionCard(
      isDark,
      icon: Icons.history,
      title: 'Timeline',
      child: Column(
        children: [
          for (int i = 0; i < d.timeline.length; i++)
            _timelineRow(d.timeline[i], isLast: i == d.timeline.length - 1, isDark: isDark),
        ],
      ),
    );
  }

  Widget _timelineRow(TimelineEvent e, {required bool isLast, required bool isDark}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: AppTheme.primaryAccent, shape: BoxShape.circle),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)
                        .withValues(alpha: 0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _fmtTime(e.at),
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Review CTA (client, completion pending) ─────────────────────────────────

  bool _showReviewCta(JobLifecycle d) =>
      d.isClient && d.completion?.status == 'pending_approval';

  Widget _reviewCta(JobLifecycle d) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _openReview(d),
        icon: const Icon(Icons.rate_review_outlined),
        label: const Text('Review completion'),
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
      ),
    );
  }

  Future<void> _openReview(JobLifecycle d) async {
    final uid = context.read<AuthProvider>().currentUserId ?? '';
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ApproveOrDisputeScreen(
        postId: d.post.id,
        postTitle: d.post.title,
        clientUserId: uid,
        providerNote: d.completion?.providerNote,
        amount: d.payment?.amount ?? 0,
      ),
    ));
    if (mounted) _load(); // refresh lifecycle after an approve/dispute
  }

  // ── Stage mapping ───────────────────────────────────────────────────────────

  int _paymentStageIndex(JobLifecycle d) {
    final escrow = d.escrow?.status;
    final pay = d.payment?.status;
    if (escrow == 'released') return 4;
    if (escrow == 'payout_pending') return 3;
    if (escrow == 'locked' || pay == 'paid') return 2; // secured + locked reached
    if (pay == null || pay == 'pending') return 0;
    return 2;
  }

  /// (label, color) banner when payment is in a branch state, else null.
  (String, Color)? _paymentSpecial(JobLifecycle d) {
    final escrow = d.escrow?.status;
    final pay = d.payment?.status;
    if (escrow == 'refunded' || pay == 'refunded') return ('Refunded', AppTheme.warningOrange);
    if (escrow == 'disputed' || pay == 'disputed') return ('Funds Frozen', AppTheme.errorRed);
    if (pay == 'failed') return ('Payment Failed', AppTheme.errorRed);
    return null;
  }

  int _completionStageIndex(JobLifecycle d) {
    final c = d.completion?.status;
    if (c == 'approved') return 3;
    if (c == 'pending_approval') return 2; // requested + awaiting approval
    if (c == 'disputed') return 2;
    return d.post.status == 'assigned' ? 0 : 0;
  }

  int _disputeStageIndex(String status) {
    if (_isResolved(status)) return 2;
    if (status == 'reviewing' || status == 'under_review' || status == 'escalated' || status == 'awaiting_evidence') {
      return 1;
    }
    return 0; // open / submitted
  }

  bool _isResolved(String status) =>
      status == 'resolved' ||
      status == 'resolved_release' ||
      status == 'resolved_refund' ||
      status == 'resolved_partial';

  String _disputeStageLabel(String status) {
    switch (status) {
      case 'open':
        return 'Submitted';
      case 'reviewing':
      case 'under_review':
        return 'Under Review';
      case 'awaiting_evidence':
        return 'Awaiting Evidence';
      case 'escalated':
        return 'Escalated';
      default:
        return _isResolved(status) ? 'Resolved' : status;
    }
  }

  Color _disputeStageColor(String status) {
    if (_isResolved(status)) return AppTheme.successGreen;
    if (status == 'escalated') return AppTheme.errorRed;
    if (status == 'open') return AppTheme.warningOrange;
    return AppTheme.primaryAccent;
  }

  Widget _outcomeBox(LifecycleDispute dispute, LifecycleDecision? decision, bool isDark) {
    final type = decision?.decisionType ?? '';
    final providerAmt = decision?.providerAmount ?? dispute.providerAmount ?? 0;
    final refundAmt = decision?.clientRefundAmount ?? dispute.buyerRefund ?? 0;
    String headline;
    switch (type) {
      case 'FULL_RELEASE':
        headline = 'Full payment released to the provider.';
        break;
      case 'FULL_REFUND':
        headline = 'Full refund issued to the client.';
        break;
      case 'PARTIAL_SPLIT':
        headline =
            'Payment split — provider ${formatPriceDisplay(providerAmt)}, client refund ${formatPriceDisplay(refundAmt)}.';
        break;
      default:
        headline = 'Dispute resolved.';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_outlined, size: 18, color: AppTheme.successGreen),
              const SizedBox(width: 8),
              const Text('Outcome', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Text(headline, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          if (decision?.reasoning != null && decision!.reasoning!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              decision.reasoning!,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Generic UI helpers ──────────────────────────────────────────────────────

  Widget _sectionCard(
    bool isDark, {
    required IconData icon,
    required String title,
    Widget? pill,
    required Widget child,
  }) {
    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.primaryAccent),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (pill != null) pill,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _card(bool isDark, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary).withValues(alpha: 0.15),
        ),
      ),
      child: child,
    );
  }

  Widget _pill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  Widget _noteBox(String label, String value, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.darkBackground : AppTheme.lightBackground),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 13.5)),
        ],
      ),
    );
  }

  String _postStatusLabel(String s) {
    switch (s) {
      case 'open':
        return 'Open';
      case 'assigned':
        return 'In Progress';
      case 'completed':
        return 'Completed';
      case 'disputed':
        return 'Disputed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return s;
    }
  }

  Color _postStatusColor(String s) {
    switch (s) {
      case 'completed':
        return AppTheme.successGreen;
      case 'disputed':
        return AppTheme.errorRed;
      case 'assigned':
        return AppTheme.primaryAccent;
      default:
        return AppTheme.warningOrange;
    }
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.day} ${_months[dt.month - 1]} ${dt.year}, $h:$m $ampm';
  }
}

/// Vertical stage track: filled (done), highlighted (current), or muted (upcoming).
class _StageTrack extends StatelessWidget {
  final List<String> stages;
  final int currentIndex;
  final bool isDark;
  final String? branchLabel;

  const _StageTrack({
    required this.stages,
    required this.currentIndex,
    required this.isDark,
    this.branchLabel,
  });

  @override
  Widget build(BuildContext context) {
    final muted = (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < stages.length; i++)
          _row(
            label: stages[i],
            done: i < currentIndex,
            active: i == currentIndex,
            muted: muted,
            isLast: i == stages.length - 1,
          ),
        if (branchLabel != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.errorRed),
              const SizedBox(width: 6),
              Text(branchLabel!, style: TextStyle(fontSize: 13, color: AppTheme.errorRed, fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _row({
    required String label,
    required bool done,
    required bool active,
    required Color muted,
    required bool isLast,
  }) {
    final Color color = done
        ? AppTheme.successGreen
        : active
            ? AppTheme.primaryAccent
            : muted.withValues(alpha: 0.5);
    final IconData icon = done
        ? Icons.check_circle
        : active
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: done || active ? null : muted,
            ),
          ),
        ],
      ),
    );
  }
}
