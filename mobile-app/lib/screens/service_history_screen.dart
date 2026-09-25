import 'package:flutter/material.dart';
import '../theme/app_icons.dart';

import '../models/service_record.dart';
import '../services/service_records_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/error_mapper.dart';
import '../utils/format_utils.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';
import 'job_lifecycle_screen.dart';
import 'receipt_screen.dart';

/// Profile → Service History.
///
/// Two perspectives on the same records: what the user paid for ("My Services")
/// and what they were hired to do ("My Work"). The same person routinely has
/// both, so this is one screen with two tabs rather than two entry points.
///
/// Each row opens the EXISTING Job Lifecycle screen — the permanent record of
/// that service. This screen deliberately does not restate lifecycle detail; it
/// is an index, and the detail already has one home.
class ServiceHistoryScreen extends StatefulWidget {
  final String uid;

  /// Which tab to land on. Providers usually arrive wanting their work.
  final int initialTab;

  const ServiceHistoryScreen({super.key, required this.uid, this.initialTab = 0});

  @override
  State<ServiceHistoryScreen> createState() => _ServiceHistoryScreenState();
}

class _ServiceHistoryScreenState extends State<ServiceHistoryScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Service History'),
          bottom: const TabBar(
            tabs: [Tab(text: 'My Services'), Tab(text: 'My Work')],
          ),
        ),
        body: TabBarView(
          children: [
            _HistoryTab(uid: widget.uid, role: 'client'),
            _HistoryTab(uid: widget.uid, role: 'provider'),
          ],
        ),
      ),
    );
  }
}

class _HistoryTab extends StatefulWidget {
  final String uid;
  final String role;

  const _HistoryTab({required this.uid, required this.role});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> with AutomaticKeepAliveClientMixin {
  ServiceHistory? _history;
  String? _error;
  bool _loading = true;

  // Distinguishes "no request has answered yet" from "the answer was empty".
  // An empty list is only an answer once a load has COMPLETED — the same rule
  // the feed and jobs tabs follow, and the reason neither opens on a false
  // "nothing here" while its first fetch is still in flight.
  bool _hasResolved = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final history = await ServiceRecordsService.getHistory(
        userId: widget.uid,
        role: widget.role,
      );
      if (!mounted) return;
      setState(() {
        _history = history;
        _hasResolved = true;
        _loading = false;
      });
    } on ServiceRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        // A failed fetch is never published as an empty result — _history is
        // left untouched so a stale-but-real list survives a flaky refresh.
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // LOADING — only while nothing has answered yet.
    if (_loading && !_hasResolved) {
      return const FeedSkeletonList(itemCount: 4);
    }

    // ERROR — and there is nothing worth showing underneath it.
    if (_error != null && _history == null) {
      return ErrorRetryView(message: _error!, onRetry: _load);
    }

    final history = _history;

    // EMPTY — a completed load that genuinely returned nothing.
    if (history == null || history.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            EmptyStateView(
              icon: widget.role == 'client' ? AppIcons.serviceHistory : AppIcons.jobs,
              title: widget.role == 'client'
                  ? 'No services yet'
                  : 'No work yet',
              subtitle: widget.role == 'client'
                  ? 'Services you hire a provider for will appear here, with their payment records and receipts.'
                  : 'Jobs you are selected for will appear here once a client chooses you.',
              actions: [
                TextButton.icon(
                  // Back to Discover — the tab shell is the root of the stack,
                  // so popping to it is the useful action from here.
                  onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                  icon: const Icon(AppIcons.discover, size: 20),
                  label: const Text('Browse Discover'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // SUCCESS
    return ReconnectListener(
      onReconnect: _load,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: history.records.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _SummaryHeader(history: history, role: widget.role, isDark: isDark);
            }
            final record = history.records[index - 1];
            return _ServiceRecordCard(
              record: record,
              uid: widget.uid,
              isDark: isDark,
              onChanged: _load,
            );
          },
        ),
      ),
    );
  }
}

/// The provider's work summary. Shown only on My Work, and only once there is
/// completed work to summarise — an empty stat line is noise.
class _SummaryHeader extends StatelessWidget {
  final ServiceHistory history;
  final String role;
  final bool isDark;

  const _SummaryHeader({required this.history, required this.role, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (role != 'provider' || history.totalCompleted == 0) {
      return const SizedBox(height: 4);
    }

    final sub = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final jobs = history.totalCompleted;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$jobs completed ${jobs == 1 ? 'job' : 'jobs'}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                // "Value of completed work", never "earnings" or "balance" —
                // a payout can still be in flight, and this figure says nothing
                // about what has actually reached the provider's phone.
                Text(
                  'Value of completed work · ${formatPriceDisplay(history.completedValue)}',
                  style: TextStyle(fontSize: 13, color: sub),
                ),
              ],
            ),
          ),
          const IconBadge(AppIcons.success, color: AppTheme.successGreen),
        ],
      ),
    );
  }
}

class _ServiceRecordCard extends StatelessWidget {
  final ServiceRecord record;
  final String uid;
  final bool isDark;
  final VoidCallback onChanged;

  const _ServiceRecordCard({
    required this.record,
    required this.uid,
    required this.isDark,
    required this.onChanged,
  });

  /// Mirrors _settlementColor in job_lifecycle_screen.dart, so the same money
  /// state is the same colour on the list and on the detail it opens.
  Color get _stateColor {
    final s = record.settlementState;
    if (s == 'settlement_failed' || s == 'inconsistent' || s == 'disputed') return AppTheme.errorRed;
    if (record.attentionRequired) return AppTheme.warningOrange;
    if (s == 'released' || s == 'refunded') return AppTheme.successGreen;
    if (s == 'payout_processing' || s == 'awaiting_payment') return AppTheme.warningOrange;
    if (s == 'no_payment') return isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return AppTheme.primaryAccent;
  }

  /// The date that matters for this record: when the work finished, else when
  /// the money moved, else when the request was posted. Labelled accordingly
  /// rather than presenting whichever one exists as "the" date.
  (String, DateTime)? get _dateLine {
    if (record.completedAt != null) return ('Completed', record.completedAt!);
    if (record.settledAt != null) return ('Settled', record.settledAt!);
    if (record.createdAt != null) return ('Posted', record.createdAt!);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sub = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final color = _stateColor;
    final date = _dateLine;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.lgAll,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => JobLifecycleScreen(postId: record.postId, postTitle: record.title),
            ),
          ).then((_) => onChanged()),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Title + amount ──────────────────────────────────────────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        record.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (record.amount != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        formatPriceDisplay(record.amount!),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),

                // ── Counterparty ────────────────────────────────────────────
                if (record.counterpartyName != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        record.isClient ? AppIcons.provider : AppIcons.account,
                        size: 13,
                        color: tertiary,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          record.counterpartyName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: sub),
                        ),
                      ),
                    ],
                  ),
                ],

                // ── Date + location ─────────────────────────────────────────
                if (date != null || record.location != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (date != null)
                        Text(
                          '${date.$1} ${formatRelativeTime(date.$2)}',
                          style: TextStyle(fontSize: 12, color: tertiary),
                        ),
                      if (date != null && record.location != null)
                        Text(' · ', style: TextStyle(fontSize: 12, color: tertiary)),
                      if (record.location != null)
                        Expanded(
                          child: Text(
                            record.location!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: tertiary),
                          ),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 10),

                // ── Settlement state + receipt affordance ───────────────────
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: AppRadius.pillAll,
                      ),
                      child: Text(
                        // The label comes from the backend's ONE money state
                        // machine — never re-derived here.
                        record.settlementLabel,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
                      ),
                    ),
                    if (record.archived) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: tertiary.withValues(alpha: 0.12),
                          borderRadius: AppRadius.pillAll,
                        ),
                        child: Text(
                          'Removed',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: tertiary),
                        ),
                      ),
                    ],
                    const Spacer(),
                    // Only offered where a receipt can actually exist. A job
                    // with no confirmed payment shows nothing rather than a
                    // button that opens an apology.
                    if (record.receiptAvailable)
                      TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReceiptScreen(postId: record.postId, uid: uid),
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(AppIcons.receipt, size: 15),
                        label: const Text('Receipt', style: TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
