import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../../models/payout_models.dart';
import '../../models/user_model.dart';
import '../../services/payout_service.dart';
import '../../services/user_profile_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/error_mapper.dart';
import '../../widgets/loading_empty_offline.dart';
import '../../widgets/provider_gate.dart';
import '../professional_profile_screen.dart';
import 'payout_destinations_screen.dart';

/// Provider onboarding — the one screen that answers "what is left before I
/// can work and get paid?".
///
/// A provider on Help24 is derived, not registered: a confirmed profession plus
/// a contact number makes you hireable (ProviderReadiness), and a VERIFIED
/// payout destination makes you payable. This screen tracks all three and
/// routes into the flow that completes each one. There is no server-side
/// "provider account" to create — finishing the steps IS the registration.
class ProviderOnboardingScreen extends StatefulWidget {
  final String uid;
  final UserModel? initialProfile;
  final String emailFromAuth;
  final String? phoneFromAuth;

  const ProviderOnboardingScreen({
    super.key,
    required this.uid,
    this.initialProfile,
    required this.emailFromAuth,
    this.phoneFromAuth,
  });

  @override
  State<ProviderOnboardingScreen> createState() => _ProviderOnboardingScreenState();
}

enum _PayoutStepState { loading, none, pending, needsDefault, complete, unavailable, error }

class _ProviderOnboardingScreenState extends State<ProviderOnboardingScreen> {
  UserModel? _profile;
  bool _loadingProfile = true;
  Object? _profileError;

  _PayoutStepState _payoutState = _PayoutStepState.loading;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadingProfile = true;
      _profileError = null;
      _payoutState = _PayoutStepState.loading;
    });

    try {
      final profile = await UserProfileService.getUser(widget.uid);
      if (!mounted) return;
      setState(() {
        _profile = profile ?? _profile;
        _loadingProfile = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingProfile = false;
        _profileError = e;
      });
    }

    try {
      final destinations = await PayoutService.listDestinations(widget.uid);
      if (!mounted) return;
      setState(() => _payoutState = _payoutStateOf(destinations));
    } on PayoutException catch (e) {
      if (!mounted) return;
      setState(() => _payoutState =
          e.featureUnavailable ? _PayoutStepState.unavailable : _PayoutStepState.error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _payoutState = _PayoutStepState.error);
    }
  }

  _PayoutStepState _payoutStateOf(List<PayoutDestination> destinations) {
    final live = destinations
        .where((d) => d.status != PayoutDestinationStatus.retired)
        .toList();
    if (live.isEmpty) return _PayoutStepState.none;
    if (live.any((d) => d.status == PayoutDestinationStatus.active && d.isDefault)) {
      return _PayoutStepState.complete;
    }
    if (live.any((d) => d.status == PayoutDestinationStatus.active)) {
      return _PayoutStepState.needsDefault;
    }
    return _PayoutStepState.pending;
  }

  Future<void> _openProfessionalProfile() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfessionalProfileScreen(
          uid: widget.uid,
          initialProfile: _profile,
          emailFromAuth: widget.emailFromAuth,
          phoneFromAuth: widget.phoneFromAuth,
        ),
      ),
    );
    if (changed == true) _changed = true;
    if (mounted) await _load();
  }

  Future<void> _openPayoutDestinations() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PayoutDestinationsScreen(uid: widget.uid),
      ),
    );
    _changed = true;
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Become a provider')),
        body: SafeArea(
          child: _loadingProfile && _profile == null
              ? const LoadingView(message: 'Checking your progress…')
              : _profileError != null && _profile == null
                  ? ErrorRetryView(
                      message: ErrorMapper.toMessage(_profileError,
                          context: ErrorContext.loadContent),
                      onRetry: _load,
                    )
                  : _steps(isDark),
        ),
      ),
    );
  }

  Widget _steps(bool isDark) {
    final readiness =
        ProviderReadiness.of(_profile, fallbackPhone: widget.phoneFromAuth);
    final professionDone =
        !readiness.missing.contains(ProviderRequirement.profession);
    final phoneDone = !readiness.missing.contains(ProviderRequirement.phone);
    final payoutDone = _payoutState == _PayoutStepState.complete;
    final doneCount =
        (professionDone ? 1 : 0) + (phoneDone ? 1 : 0) + (payoutDone ? 1 : 0);
    final allDone = doneCount == 3;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: allDone
                  ? AppTheme.successGreen.withValues(alpha: 0.10)
                  : AppTheme.primaryAccent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  allDone ? Iconsax.verify : Iconsax.briefcase,
                  color: allDone ? AppTheme.successGreen : AppTheme.primaryAccent,
                  size: 32,
                ),
                const SizedBox(height: 12),
                Text(
                  allDone
                      ? "You're ready to work and get paid"
                      : 'Set up your provider account',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  allDone
                      ? 'Clients can hire you, and your earnings go to your verified M-Pesa number.'
                      : '$doneCount of 3 steps complete. Finish them to offer services and receive payouts.',
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _StepTile(
            index: 1,
            done: professionDone,
            icon: Icons.work_outline_rounded,
            title: 'Choose your profession',
            detail: professionDone
                ? 'Confirmed — clients can see what you do.'
                : 'Clients need to know what you do before they can hire you.',
            actionLabel: professionDone ? 'Edit' : 'Choose',
            onTap: _openProfessionalProfile,
          ),
          _StepTile(
            index: 2,
            done: phoneDone,
            icon: Icons.phone_iphone_rounded,
            title: 'Add your contact number',
            detail: phoneDone
                ? 'On file — clients and Help24 can reach you.'
                : 'Added under Account → Payment Settings, protected by your device lock.',
            actionLabel: phoneDone ? 'Edit' : 'Add',
            onTap: _openProfessionalProfile,
          ),
          _StepTile(
            index: 3,
            done: payoutDone,
            icon: Iconsax.card,
            title: 'Verify your payout number',
            detail: switch (_payoutState) {
              _PayoutStepState.loading => 'Checking…',
              _PayoutStepState.none =>
                'Prove the M-Pesa number your earnings are sent to. Money only goes to a number you have verified.',
              _PayoutStepState.pending =>
                'A number is waiting for its verification code.',
              _PayoutStepState.needsDefault =>
                'Verified — now choose which number is your default.',
              _PayoutStepState.complete =>
                'Verified — payouts go to your default M-Pesa number.',
              _PayoutStepState.unavailable =>
                'Rolling out soon. Your other steps still count.',
              _PayoutStepState.error =>
                "Couldn't check just now. Pull to refresh.",
            },
            actionLabel: switch (_payoutState) {
              _PayoutStepState.none => 'Add',
              _PayoutStepState.pending => 'Verify',
              _PayoutStepState.needsDefault => 'Choose',
              _PayoutStepState.complete => 'Manage',
              _ => null,
            },
            onTap: _openPayoutDestinations,
          ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  final int index;
  final bool done;
  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback onTap;

  const _StepTile({
    required this.index,
    required this.done,
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ),
      child: InkWell(
        onTap: actionLabel == null ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: done
                      ? AppTheme.successGreen.withValues(alpha: 0.12)
                      : AppTheme.primaryAccent.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  done ? Icons.check_rounded : icon,
                  size: 18,
                  color: done ? AppTheme.successGreen : AppTheme.primaryAccent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Step $index · $title',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                Text(
                  actionLabel!,
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
