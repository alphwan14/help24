import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../../models/payout_models.dart';
import '../../services/payout_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/action_feedback.dart';
import '../../utils/error_mapper.dart';
import '../../utils/phone_utils.dart';
import '../../widgets/loading_empty_offline.dart';
import '../../widgets/profile_widgets.dart';
import 'payout_otp_screen.dart';

/// Where M-Pesa payouts go.
///
/// Lists the provider's payout destinations with their verification state,
/// lets them add a number (which immediately issues an OTP and opens the
/// verify screen), change the default, and retire numbers they no longer use.
///
/// Pops nothing; callers that care about state re-query. The screen refreshes
/// itself after every mutation because writes return the fresh row — the list
/// is never guessed at client-side.
class PayoutDestinationsScreen extends StatefulWidget {
  final String uid;

  const PayoutDestinationsScreen({super.key, required this.uid});

  @override
  State<PayoutDestinationsScreen> createState() => _PayoutDestinationsScreenState();
}

class _PayoutDestinationsScreenState extends State<PayoutDestinationsScreen> {
  List<PayoutDestination>? _destinations;
  bool _loading = true;
  Object? _error;
  bool _featureUnavailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _featureUnavailable = false;
    });
    try {
      final destinations = await PayoutService.listDestinations(widget.uid);
      if (!mounted) return;
      setState(() {
        _destinations = destinations;
        _loading = false;
      });
    } on PayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.featureUnavailable) {
          _featureUnavailable = true;
        } else {
          _error = e;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _addDestination() async {
    final controller = TextEditingController();
    String? errorText;
    bool saving = false;

    final added = await showModalBottomSheet<PayoutDestination>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => ProfileEditorSheet(
          title: 'Add payout number',
          subtitle:
              'The Safaricom number your M-Pesa payouts will be sent to. You will confirm it with a code before it can receive money.',
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              enabled: !saving,
              decoration: InputDecoration(
                hintText: '07XX XXX XXX',
                prefixText: '🇰🇪 ',
                errorText: errorText,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final normalized = normalizeKenyanNumber(controller.text);
                        if (normalized == null || !normalized.startsWith('2547')) {
                          setSheetState(() => errorText =
                              'Enter a valid Safaricom number (07XX XXX XXX).');
                          return;
                        }
                        setSheetState(() {
                          saving = true;
                          errorText = null;
                        });
                        try {
                          final destination = await PayoutService.addDestination(
                              widget.uid, normalized);
                          if (sheetContext.mounted) {
                            Navigator.pop(sheetContext, destination);
                          }
                        } on PayoutException catch (e) {
                          setSheetState(() {
                            saving = false;
                            errorText = e.message;
                          });
                        } catch (e) {
                          setSheetState(() {
                            saving = false;
                            errorText = ErrorMapper.toMessage(e,
                                context: ErrorContext.save);
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Send verification code'),
              ),
            ),
          ],
        ),
      ),
    );

    if (added == null || !mounted) return;
    await _openVerify(added);
  }

  Future<void> _openVerify(PayoutDestination destination) async {
    final verified = await Navigator.push<PayoutDestination>(
      context,
      MaterialPageRoute(
        builder: (_) => PayoutOtpScreen(uid: widget.uid, destination: destination),
      ),
    );
    if (!mounted) return;
    if (verified != null) {
      ActionFeedback.success(
          context, 'Payout number verified. M-Pesa payouts will go here.');
    }
    await _load();
  }

  Future<void> _setDefault(PayoutDestination destination) async {
    final changed = await ActionFeedback.run(
      context,
      () async {
        await PayoutService.setDefault(widget.uid, destination.id);
      },
      successMessage: 'Default payout number updated.',
      context_: ErrorContext.save,
    );
    if (changed && mounted) await _load();
  }

  Future<void> _retire(PayoutDestination destination) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retire this number?'),
        content: Text(
          destination.isDefault
              ? '${maskPhone(destination.destination)} is your default. After retiring it, payouts will pause until you choose another verified number.'
              : 'Payouts can no longer be sent to ${maskPhone(destination.destination)}. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorRed),
            child: const Text('Retire'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final done = await ActionFeedback.run(
      context,
      () async {
        await PayoutService.retire(
            widget.uid, destination.id, 'retired by provider from the app');
      },
      successMessage: 'Number retired.',
      context_: ErrorContext.save,
    );
    if (done && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payout destinations')),
      body: SafeArea(child: _body()),
      floatingActionButton: (_destinations?.isNotEmpty ?? false)
          ? FloatingActionButton.extended(
              onPressed: _addDestination,
              icon: const Icon(Iconsax.add),
              label: const Text('Add number'),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) return const LoadingView(message: 'Loading payout numbers…');
    if (_featureUnavailable) {
      return const EmptyStateView(
        icon: Iconsax.timer_1,
        title: 'Not available yet',
        subtitle:
            'Payout number verification is being rolled out. Check back soon — your earnings are unaffected.',
      );
    }
    if (_error != null) {
      return ErrorRetryView(
        message: ErrorMapper.toMessage(_error, context: ErrorContext.loadContent),
        onRetry: _load,
      );
    }
    final destinations = _destinations ?? const <PayoutDestination>[];
    if (destinations.isEmpty) {
      return EmptyStateView(
        icon: Iconsax.card,
        title: 'No payout number yet',
        subtitle:
            'Add the M-Pesa number your earnings should be sent to. You will verify it with a code — money only ever goes to a number you have proven.',
        actions: [
          FilledButton.icon(
            onPressed: _addDestination,
            icon: const Icon(Iconsax.add),
            label: const Text('Add payout number'),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        itemCount: destinations.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _DestinationCard(
          destination: destinations[index],
          onVerify: () => _openVerify(destinations[index]),
          onSetDefault: () => _setDefault(destinations[index]),
          onRetire: () => _retire(destinations[index]),
        ),
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  final PayoutDestination destination;
  final VoidCallback onVerify;
  final VoidCallback onSetDefault;
  final VoidCallback onRetire;

  const _DestinationCard({
    required this.destination,
    required this.onVerify,
    required this.onSetDefault,
    required this.onRetire,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final retired = destination.status == PayoutDestinationStatus.retired;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: destination.isDefault
              ? AppTheme.primaryAccent
              : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          width: destination.isDefault ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Iconsax.mobile,
                  size: 20,
                  color: retired
                      ? (isDark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.lightTextTertiary)
                      : AppTheme.primaryAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  maskPhone(destination.destination),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    decoration: retired ? TextDecoration.lineThrough : null,
                    color: retired
                        ? (isDark
                            ? AppTheme.darkTextTertiary
                            : AppTheme.lightTextTertiary)
                        : null,
                  ),
                ),
              ),
              _StatusChip(destination: destination),
            ],
          ),
          if (destination.isDefault) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Iconsax.star_1, size: 14, color: AppTheme.primaryAccent),
                const SizedBox(width: 6),
                Text(
                  'Default — new jobs pay out here',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ],
          if (!retired) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (destination.status == PayoutDestinationStatus.pending)
                  TextButton.icon(
                    onPressed: onVerify,
                    icon: const Icon(Iconsax.shield_tick, size: 16),
                    label: const Text('Verify now'),
                  ),
                if (destination.status == PayoutDestinationStatus.active &&
                    !destination.isDefault)
                  TextButton.icon(
                    onPressed: onSetDefault,
                    icon: const Icon(Iconsax.star_1, size: 16),
                    label: const Text('Make default'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: onRetire,
                  style: TextButton.styleFrom(
                    foregroundColor:
                        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
                  child: const Text('Retire'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final PayoutDestination destination;

  const _StatusChip({required this.destination});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (destination.status) {
      PayoutDestinationStatus.active => (AppTheme.successGreen, Iconsax.shield_tick),
      PayoutDestinationStatus.pending => (AppTheme.warningOrange, Iconsax.timer_1),
      PayoutDestinationStatus.retired => (AppTheme.errorRed, Iconsax.slash),
      PayoutDestinationStatus.unknown => (AppTheme.warningOrange, Iconsax.info_circle),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            destination.status.displayLabel,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
