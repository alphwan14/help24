import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../../models/promotion_models.dart';
import '../../services/promotion_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/time_utils.dart';
import 'campaign_detail_screen.dart';
import 'promote_listing_flow_screen.dart';

/// Profile → Promote Business hub: the owner's campaigns and payment history.
/// Native marketplace feel — this is a Help24 feature, not an ad portal.
class PromoteBusinessScreen extends StatefulWidget {
  final String uid;
  const PromoteBusinessScreen({super.key, required this.uid});

  @override
  State<PromoteBusinessScreen> createState() => _PromoteBusinessScreenState();
}

class _PromoteBusinessScreenState extends State<PromoteBusinessScreen> {
  late Future<List<PromotionCampaign>> _campaigns;
  late Future<List<PromotionPaymentRecord>> _payments;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _campaigns = PromotionService.fetchCampaigns(widget.uid);
      _payments = PromotionService.fetchPayments(widget.uid);
    });
  }

  Future<void> _startPromotionFlow() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PromoteListingFlowScreen(uid: widget.uid)),
    );
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Promote Business'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Campaigns'), Tab(text: 'Payments')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _startPromotionFlow,
          icon: const Icon(Iconsax.flash_1),
          label: const Text('Promote a listing'),
        ),
        body: TabBarView(
          children: [
            _CampaignsTab(
              future: _campaigns,
              uid: widget.uid,
              onChanged: _reload,
              onPromote: _startPromotionFlow,
            ),
            _PaymentsTab(future: _payments, onRefresh: _reload),
          ],
        ),
      ),
    );
  }
}

class _CampaignsTab extends StatelessWidget {
  final Future<List<PromotionCampaign>> future;
  final String uid;
  final VoidCallback onChanged;
  final VoidCallback onPromote;

  const _CampaignsTab({
    required this.future,
    required this.uid,
    required this.onChanged,
    required this.onPromote,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PromotionCampaign>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(message: '${snap.error}', onRetry: onChanged);
        }
        final campaigns = snap.data ?? const <PromotionCampaign>[];
        if (campaigns.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Iconsax.flash_1, size: 48, color: AppTheme.primaryAccent),
                  const SizedBox(height: 16),
                  Text('Get discovered', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Feature one of your service listings across Help24 — '
                    'search, categories and the discover feed.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onPromote,
                    icon: const Icon(Iconsax.flash_1, size: 18),
                    label: const Text('Promote a listing'),
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => onChanged(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: campaigns.length,
            itemBuilder: (context, i) {
              final c = campaigns[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  title: Text(
                    c.postTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      c.status == CampaignStatus.active
                          ? '${c.packageName} · ${c.daysRemaining} day${c.daysRemaining == 1 ? '' : 's'} left'
                          : '${c.packageName} · KES ${c.priceKes} · ${formatRelativeTime(c.createdAt)}',
                    ),
                  ),
                  trailing: CampaignStatusChip(status: c.status),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CampaignDetailScreen(campaignId: c.id, uid: uid),
                      ),
                    );
                    onChanged();
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PaymentsTab extends StatelessWidget {
  final Future<List<PromotionPaymentRecord>> future;
  final VoidCallback onRefresh;

  const _PaymentsTab({required this.future, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PromotionPaymentRecord>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(message: '${snap.error}', onRetry: onRefresh);
        }
        final payments = snap.data ?? const <PromotionPaymentRecord>[];
        if (payments.isEmpty) {
          return const Center(child: Text('No promotion payments yet.'));
        }
        return RefreshIndicator(
          onRefresh: () async => onRefresh(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: payments.length,
            itemBuilder: (context, i) {
              final p = payments[i];
              final (color, icon) = switch (p.status) {
                'paid' => (AppTheme.successGreen, Icons.check_circle_outline),
                'failed' => (AppTheme.errorRed, Icons.error_outline),
                _ => (AppTheme.warningOrange, Icons.hourglass_top_rounded),
              };
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: Icon(icon, color: color),
                  title: Text(
                    '${p.packageName.isEmpty ? 'Promotion' : p.packageName} — KES ${p.amountKes}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      if (p.postTitle.isNotEmpty) p.postTitle,
                      if (p.mpesaReceipt != null && p.mpesaReceipt!.isNotEmpty)
                        'Receipt ${p.mpesaReceipt}',
                      if (p.status == 'failed' && p.failureReason != null) p.failureReason!,
                      formatRelativeTime(p.createdAt),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status chip shared by the hub and the detail screen.
class CampaignStatusChip extends StatelessWidget {
  final CampaignStatus status;
  const CampaignStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      CampaignStatus.active => AppTheme.successGreen,
      CampaignStatus.pendingReview => AppTheme.primaryAccent,
      CampaignStatus.awaitingPayment => AppTheme.warningOrange,
      CampaignStatus.paused => AppTheme.warningOrange,
      CampaignStatus.rejected => AppTheme.errorRed,
      _ => Theme.of(context).brightness == Brightness.dark
          ? AppTheme.darkTextTertiary
          : AppTheme.lightTextTertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.displayLabel,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
