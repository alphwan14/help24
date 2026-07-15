import 'dart:async';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../../models/post_model.dart';
import '../../models/promotion_models.dart';
import '../../services/post_service.dart';
import '../../services/promotion_service.dart';
import '../../theme/app_theme.dart';

/// The one-minute "Promote Business" flow:
///   Choose listing → Choose package → Review → Pay with M-Pesa → live.
/// Payment is an STK push with the PaymentScreen-style poll loop; the
/// campaign activates automatically (or enters review) on confirmation.
class PromoteListingFlowScreen extends StatefulWidget {
  final String uid;
  const PromoteListingFlowScreen({super.key, required this.uid});

  @override
  State<PromoteListingFlowScreen> createState() => _PromoteListingFlowScreenState();
}

enum _PayPhase { idle, sending, awaitingPin, success, failed }

class _PromoteListingFlowScreenState extends State<PromoteListingFlowScreen> {
  int _step = 0;

  List<PostModel>? _offers;
  String? _offersError;
  PostModel? _selectedPost;

  List<PromotionPackage>? _packages;
  String? _packagesError;
  PromotionPackage? _selectedPackage;

  // Checkout
  _PayPhase _phase = _PayPhase.idle;
  String _payMessage = '';
  String? _campaignStatus;
  Timer? _pollTimer;
  int _polls = 0;
  static const int _maxPolls = 24; // × 5 s ≈ 2 minutes

  @override
  void initState() {
    super.initState();
    _loadOffers();
    _loadPackages();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOffers() async {
    try {
      final mine = await PostService.getMyPosts(widget.uid);
      if (!mounted) return;
      setState(() {
        _offers = mine
            .where((p) => p.type == PostType.offer && p.status == 'open')
            .toList();
        _offersError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _offersError = '$e');
    }
  }

  Future<void> _loadPackages() async {
    try {
      final packages = await PromotionService.fetchPackages();
      if (!mounted) return;
      setState(() {
        _packages = packages;
        _packagesError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _packagesError = '$e');
    }
  }

  // ── Checkout ────────────────────────────────────────────────────────────────

  Future<void> _payNow() async {
    final post = _selectedPost;
    final pkg = _selectedPackage;
    if (post == null || pkg == null) return;

    setState(() {
      _phase = _PayPhase.sending;
      _payMessage = 'Setting up your promotion…';
    });

    try {
      final campaign = await PromotionService.createCampaign(
        userId: widget.uid,
        postId: post.id,
        packageId: pkg.id,
      );
      final message = await PromotionService.payCampaign(
        campaignId: campaign.id,
        userId: widget.uid,
      );
      if (!mounted) return;
      setState(() {
        _phase = _PayPhase.awaitingPin;
        _payMessage = message;
      });
      _polls = 0;
      _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll(campaign.id));
    } on PromotionException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PayPhase.failed;
        _payMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PayPhase.failed;
        _payMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _poll(String campaignId) async {
    _polls++;
    try {
      final status = await PromotionService.paymentStatus(
        campaignId: campaignId,
        userId: widget.uid,
      );
      if (!mounted) return;
      final paymentStatus = status['payment_status']?.toString();
      final campaignStatus = status['campaign_status']?.toString();

      if (paymentStatus == 'paid') {
        _pollTimer?.cancel();
        setState(() {
          _phase = _PayPhase.success;
          _campaignStatus = campaignStatus;
          _payMessage = campaignStatus == 'active'
              ? 'Payment received — your promotion is live!'
              : 'Payment received — your promotion is being reviewed and '
                  'usually goes live within a few hours.';
        });
        return;
      }
      if (paymentStatus == 'failed') {
        _pollTimer?.cancel();
        setState(() {
          _phase = _PayPhase.failed;
          _payMessage = status['failure_reason']?.toString() ??
              'Payment was not completed. You can try again.';
        });
        return;
      }
    } catch (_) {
      // transient poll error — keep trying until the window closes
    }
    if (_polls >= _maxPolls && mounted) {
      _pollTimer?.cancel();
      setState(() {
        _phase = _PayPhase.failed;
        _payMessage =
            'We did not receive a confirmation in time. If you entered your '
            'PIN, check Campaigns in a few minutes before paying again.';
      });
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  bool get _payBusy => _phase == _PayPhase.sending || _phase == _PayPhase.awaitingPin;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_payBusy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (_step) {
            0 => 'Choose a listing',
            1 => 'Choose a package',
            _ => 'Review & pay',
          }),
        ),
        body: switch (_step) {
          0 => _buildListingStep(),
          1 => _buildPackageStep(),
          _ => _buildReviewStep(),
        },
      ),
    );
  }

  Widget _buildListingStep() {
    if (_offersError != null) {
      return _RetryView(message: _offersError!, onRetry: _loadOffers);
    }
    final offers = _offers;
    if (offers == null) return const Center(child: CircularProgressIndicator());
    if (offers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Iconsax.shop, size: 44, color: AppTheme.primaryAccent),
              const SizedBox(height: 14),
              Text('No service listings yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                'Promotion features one of your service offers. Create an '
                'offer post first, then come back to promote it.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: offers.length,
      itemBuilder: (context, i) {
        final post = offers[i];
        final selected = _selectedPost?.id == post.id;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? AppTheme.primaryAccent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: ListTile(
            title: Text(post.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${post.category.name} · ${post.location}'),
            trailing: selected
                ? const Icon(Icons.check_circle, color: AppTheme.primaryAccent)
                : const Icon(Icons.radio_button_unchecked),
            onTap: () => setState(() {
              _selectedPost = post;
              _step = 1;
            }),
          ),
        );
      },
    );
  }

  Widget _buildPackageStep() {
    if (_packagesError != null) {
      return _RetryView(message: _packagesError!, onRetry: _loadPackages);
    }
    final packages = _packages;
    if (packages == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final pkg in packages)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: _selectedPackage?.id == pkg.id
                    ? AppTheme.primaryAccent
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: ListTile(
              enabled: pkg.isPurchasable,
              title: Text(pkg.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(pkg.description),
              ),
              trailing: pkg.isPurchasable
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('KES ${pkg.priceKes}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppTheme.successGreen)),
                        Text('${pkg.durationDays} days',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    )
                  : Text('Contact us', style: Theme.of(context).textTheme.bodySmall),
              onTap: pkg.isPurchasable
                  ? () => setState(() {
                        _selectedPackage = pkg;
                        _step = 2;
                      })
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _buildReviewStep() {
    final post = _selectedPost;
    final pkg = _selectedPackage;
    if (post == null || pkg == null) {
      return const Center(child: Text('Pick a listing and a package first.'));
    }

    if (_phase == _PayPhase.success) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, size: 56, color: AppTheme.successGreen),
              const SizedBox(height: 16),
              Text(
                _campaignStatus == 'active' ? 'Your promotion is live!' : 'Payment received',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(_payMessage, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Summary', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _SummaryRow(label: 'Listing', value: post.title),
                _SummaryRow(label: 'Package', value: pkg.name),
                _SummaryRow(label: 'Duration', value: '${pkg.durationDays} days'),
                _SummaryRow(
                  label: 'Visibility',
                  value: 'Discover · Search · Categories · Nearby',
                ),
                const Divider(height: 24),
                _SummaryRow(
                  label: 'Total',
                  value: 'KES ${pkg.priceKes}',
                  emphasize: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_phase == _PayPhase.awaitingPin || _phase == _PayPhase.sending)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      _phase == _PayPhase.awaitingPin
                          ? 'Check your phone and enter your M-Pesa PIN.\n$_payMessage'
                          : _payMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_phase == _PayPhase.failed)
          Card(
            color: AppTheme.errorRed.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppTheme.errorRed),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_payMessage)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _payBusy ? null : _payNow,
          icon: const Icon(Iconsax.card, size: 18),
          label: Text(_phase == _PayPhase.failed ? 'Try again' : 'Pay with M-Pesa'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Paid to Help24 · Campaign starts automatically after approval',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;
  const _SummaryRow({required this.label, required this.value, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                color: emphasize ? AppTheme.successGreen : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RetryView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _RetryView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
