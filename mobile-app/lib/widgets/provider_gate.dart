import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../screens/professional_profile_screen.dart';
import '../services/profession_registry.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';
import 'profile_widgets.dart';

// =============================================================================
// Become a Provider — ONE gate, checked in ONE place.
//
// Before this existed, offering on a request required an M-Pesa number
// (post_flows.dart) while applying to a JOB required nothing at all — two
// different bars for the same act of offering to work. Both paths now call
// [ensureProviderReady].
//
// There is deliberately NO `is_provider` column and no separate provider
// record. "Provider" is a DERIVED state:
//
//     provider-ready  ==  confirmed profession  AND  phone number on file
//
// so it can never drift out of sync with the profile it describes, and
// nothing has to be migrated or backfilled. Profession is required HERE and
// nowhere else — sign-up stays frictionless (spec §3), and a browsing/posting
// user is never asked for it.
// =============================================================================

/// What a user still has to do before they can offer to work.
enum ProviderRequirement {
  profession(
    'Choose your profession',
    'Clients need to know what you do before they can hire you.',
    Icons.work_outline_rounded,
  ),
  phone(
    'Add your M-Pesa number',
    'This is how you get paid when a client selects you.',
    Icons.phone_iphone_rounded,
  );

  const ProviderRequirement(this.title, this.detail, this.icon);
  final String title;
  final String detail;
  final IconData icon;
}

/// The evaluated readiness of a user to act as a provider.
class ProviderReadiness {
  final List<ProviderRequirement> missing;

  const ProviderReadiness(this.missing);

  bool get isReady => missing.isEmpty;

  static ProviderReadiness of(UserModel? profile, {String? fallbackPhone}) {
    final missing = <ProviderRequirement>[];
    if (!ProfessionRegistry.instance.isConfirmed(profile?.profession)) {
      missing.add(ProviderRequirement.profession);
    }
    final phone = (profile?.phone ?? '').trim().isNotEmpty
        ? profile!.phone!
        : (fallbackPhone ?? '');
    if (phone.trim().isEmpty) missing.add(ProviderRequirement.phone);
    return ProviderReadiness(missing);
  }
}

/// Gate an "offer to work" action.
///
/// Returns true when the user may proceed. When they may not, an explanatory
/// sheet is shown that routes to the Professional Profile — the flow the spec
/// asks for (Become Provider → Complete Professional Profile → Profession
/// required → Continue) rather than a dead-end snackbar.
///
/// Fails OPEN on a network error: if we cannot read the profile we do not know
/// that the user is unqualified, and blocking someone from working because a
/// read timed out is worse than letting a downstream check catch it.
Future<bool> ensureProviderReady(
  BuildContext context, {
  required String uid,
  String action = 'offer your services',
}) async {
  if (uid.isEmpty) return false;

  UserModel? profile;
  try {
    profile = await UserProfileService.getUser(uid);
  } catch (e) {
    debugPrint('[PROVIDER_GATE] profile read failed, failing open: $e');
    return true;
  }
  if (!context.mounted) return false;
  if (profile == null) return true; // unknown state → do not block

  final fallbackPhone = context.read<AuthProvider>().currentUser?.phoneNumber;
  final readiness = ProviderReadiness.of(profile, fallbackPhone: fallbackPhone);
  if (readiness.isReady) return true;

  final completed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BecomeProviderSheet(
      uid: uid,
      profile: profile!,
      readiness: readiness,
      action: action,
      fallbackPhone: fallbackPhone,
    ),
  );

  return completed == true;
}

class _BecomeProviderSheet extends StatefulWidget {
  final String uid;
  final UserModel profile;
  final ProviderReadiness readiness;
  final String action;
  final String? fallbackPhone;

  const _BecomeProviderSheet({
    required this.uid,
    required this.profile,
    required this.readiness,
    required this.action,
    this.fallbackPhone,
  });

  @override
  State<_BecomeProviderSheet> createState() => _BecomeProviderSheetState();
}

class _BecomeProviderSheetState extends State<_BecomeProviderSheet> {
  late UserModel _profile = widget.profile;
  late ProviderReadiness _readiness = widget.readiness;
  bool _checking = false;

  Future<void> _recheck() async {
    setState(() => _checking = true);
    try {
      final fresh = await UserProfileService.getUser(widget.uid);
      if (!mounted) return;
      setState(() {
        if (fresh != null) _profile = fresh;
        _readiness =
            ProviderReadiness.of(_profile, fallbackPhone: widget.fallbackPhone);
        _checking = false;
      });
      // Everything is satisfied — hand control straight back to the action the
      // user originally tapped, rather than making them tap it again.
      if (mounted && _readiness.isReady) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.toMessage(e, context: ErrorContext.loadContent)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openProfile() async {
    final auth = context.read<AuthProvider>();
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfessionalProfileScreen(
          uid: widget.uid,
          initialProfile: _profile,
          emailFromAuth: auth.currentUser?.email ?? '',
          phoneFromAuth: auth.currentUser?.phoneNumber,
        ),
      ),
    );
    if (mounted) await _recheck();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final missing = _readiness.missing;

    return ProfileEditorSheet(
      title: 'Complete your professional profile',
      subtitle:
          'Before you can ${widget.action}, clients need to know who they are '
          'hiring — and we need a way to pay you.',
      children: [
        for (final requirement in ProviderRequirement.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RequirementRow(
              requirement: requirement,
              satisfied: !missing.contains(requirement),
            ),
          ),
        const SizedBox(height: 10),
        if (missing.contains(ProviderRequirement.phone))
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.darkCard : AppTheme.lightCard),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.lock_outline_rounded, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your number is added in Account → Payment Settings, '
                    'protected by your device lock.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _checking ? null : _openProfile,
            child: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Complete profile'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
        ),
      ],
    );
  }
}

class _RequirementRow extends StatelessWidget {
  final ProviderRequirement requirement;
  final bool satisfied;

  const _RequirementRow({required this.requirement, required this.satisfied});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          satisfied ? Icons.check_circle_rounded : requirement.icon,
          size: 22,
          color: satisfied ? AppTheme.successGreen : AppTheme.warningOrange,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                requirement.title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  decoration: satisfied ? TextDecoration.lineThrough : null,
                  color: satisfied ? muted : null,
                ),
              ),
              if (!satisfied) ...[
                const SizedBox(height: 2),
                Text(requirement.detail,
                    style: TextStyle(fontSize: 12.5, color: muted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
