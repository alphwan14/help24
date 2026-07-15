import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../../models/promotion_models.dart';
import '../../services/promotion_service.dart';
import '../../theme/app_theme.dart';

/// Campaign analytics + lifecycle actions. Answers one question:
/// "Is promoting my business working?"
class CampaignDetailScreen extends StatefulWidget {
  final String campaignId;
  final String uid;
  const CampaignDetailScreen({super.key, required this.campaignId, required this.uid});

  @override
  State<CampaignDetailScreen> createState() => _CampaignDetailScreenState();
}

class _CampaignDetailScreenState extends State<CampaignDetailScreen> {
  late Future<CampaignAnalytics> _analytics;
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _analytics = PromotionService.fetchAnalytics(
        campaignId: widget.campaignId,
        userId: widget.uid,
      );
    });
  }

  Future<void> _runAction(Future<PromotionCampaign> Function() action) async {
    setState(() => _actionBusy = true);
    try {
      await action();
      _reload();
    } on PromotionException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel promotion?'),
        content: const Text(
          'Your listing will stop being featured. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel promotion'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAction(
        () => PromotionService.cancelCampaign(widget.campaignId, widget.uid),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Campaign')),
      body: FutureBuilder<CampaignAnalytics>(
        future: _analytics,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snap.error ?? 'Could not load campaign.'}',
                      textAlign: TextAlign.center, maxLines: 3),
                  TextButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final a = snap.data!;
          final c = a.campaign;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Header ──────────────────────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.postTitle,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                )),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _HeaderChip(
                              icon: Iconsax.box,
                              label: '${c.packageName} · KES ${c.priceKes}',
                            ),
                            if (c.startsAt != null && c.endsAt != null)
                              _HeaderChip(
                                icon: Iconsax.calendar_1,
                                label:
                                    '${_date(c.startsAt!)} – ${_date(c.endsAt!)}',
                              ),
                            if (c.status == CampaignStatus.active)
                              _HeaderChip(
                                icon: Iconsax.timer_1,
                                label:
                                    '${c.daysRemaining} day${c.daysRemaining == 1 ? '' : 's'} left',
                              ),
                          ],
                        ),
                        if (c.status == CampaignStatus.rejected &&
                            c.rejectionReason != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Reason: ${c.rejectionReason}',
                            style: const TextStyle(color: AppTheme.errorRed),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _StatusPill(status: c.status),
                            const Spacer(),
                            if (!_actionBusy) ..._actionsFor(c),
                            if (_actionBusy)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Results ─────────────────────────────────────────────
                Text('Results', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.15,
                  children: [
                    _MetricTile(label: 'Views', value: '${a.impressions}', icon: Iconsax.eye),
                    _MetricTile(label: 'Clicks', value: '${a.clicks}', icon: Iconsax.mouse),
                    _MetricTile(
                      label: 'CTR',
                      value: a.impressions > 0
                          ? '${(a.ctr * 100).toStringAsFixed(1)}%'
                          : '—',
                      icon: Iconsax.percentage_square,
                    ),
                    _MetricTile(
                        label: 'Profile views', value: '${a.profileViews}', icon: Iconsax.user),
                    _MetricTile(label: 'Phone taps', value: '${a.phoneTaps}', icon: Iconsax.call),
                    _MetricTile(label: 'Messages', value: '${a.messages}', icon: Iconsax.message),
                  ],
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Where people saw you',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        _PlacementRow(label: 'Discover feed', value: a.impressionsDiscover, total: a.impressions),
                        _PlacementRow(label: 'Search results', value: a.impressionsSearch, total: a.impressions),
                        _PlacementRow(label: 'Category pages', value: a.impressionsCategory, total: a.impressions),
                        _PlacementRow(label: 'Nearby', value: a.impressionsNearby, total: a.impressions),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Daily trend ─────────────────────────────────────────
                if (a.daily.isNotEmpty) ...[
                  Text('Daily views', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: _DailyTrend(daily: a.daily),
                    ),
                  ),
                ] else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        c.status == CampaignStatus.active
                            ? 'Results appear here as people discover your listing.'
                            : 'No activity recorded yet.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _actionsFor(PromotionCampaign c) {
    switch (c.status) {
      case CampaignStatus.active:
        return [
          TextButton(
            onPressed: () => _runAction(
                () => PromotionService.pauseCampaign(widget.campaignId, widget.uid)),
            child: const Text('Pause'),
          ),
          TextButton(
            onPressed: _confirmCancel,
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorRed),
            child: const Text('Cancel'),
          ),
        ];
      case CampaignStatus.paused:
        return [
          TextButton(
            onPressed: () => _runAction(
                () => PromotionService.resumeCampaign(widget.campaignId, widget.uid)),
            child: const Text('Resume'),
          ),
          TextButton(
            onPressed: _confirmCancel,
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorRed),
            child: const Text('Cancel'),
          ),
        ];
      case CampaignStatus.awaitingPayment:
      case CampaignStatus.pendingReview:
        return [
          TextButton(
            onPressed: _confirmCancel,
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorRed),
            child: const Text('Cancel'),
          ),
        ];
      default:
        return const [];
    }
  }

  static String _date(DateTime d) =>
      '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';
}

class _StatusPill extends StatelessWidget {
  final CampaignStatus status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      CampaignStatus.active => AppTheme.successGreen,
      CampaignStatus.pendingReview => AppTheme.primaryAccent,
      CampaignStatus.awaitingPayment || CampaignStatus.paused => AppTheme.warningOrange,
      CampaignStatus.rejected => AppTheme.errorRed,
      _ => Theme.of(context).brightness == Brightness.dark
          ? AppTheme.darkTextTertiary
          : AppTheme.lightTextTertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.displayLabel,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _HeaderChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: muted),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12.5, color: muted)),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _MetricTile({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppTheme.primaryAccent),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _PlacementRow extends StatelessWidget {
  final String label;
  final int value;
  final int total;
  const _PlacementRow({required this.label, required this.value, required this.total});

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? value / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text('$value',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Dependency-free daily bar trend (last 14 days).
class _DailyTrend extends StatelessWidget {
  final List<CampaignDailyStat> daily;
  const _DailyTrend({required this.daily});

  @override
  Widget build(BuildContext context) {
    final window = daily.length > 14 ? daily.sublist(daily.length - 14) : daily;
    final maxImpressions =
        window.fold<int>(1, (m, d) => d.impressions > m ? d.impressions : m);
    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in window)
            Expanded(
              child: Tooltip(
                message: '${d.day}: ${d.impressions} views, ${d.clicks} clicks',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: 90.0 * (d.impressions / maxImpressions),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent.withValues(alpha: 0.75),
                          borderRadius:
                              const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        d.day.length >= 10 ? d.day.substring(8) : '',
                        style: const TextStyle(fontSize: 9),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
