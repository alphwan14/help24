import 'package:flutter/material.dart';

import '../models/moderation.dart';
import '../screens/account_status_screen.dart';
import '../services/account_status_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import 'primitives.dart';

/// Pre-flight explanations for an account restriction.
///
/// The database and the backend refuse a restricted account's writes whatever
/// the app does; these widgets exist so a person learns that BEFORE they type a
/// message or fill in a listing, in words, with the reason and a way to get
/// help — instead of from a failed send.
class RestrictionGate {
  RestrictionGate._();

  /// True when [capability] may proceed. When the account is known to be
  /// denied it, explains why in a sheet and returns false. An unknown status
  /// always proceeds: the server decides, the app only explains.
  static bool allows(BuildContext context, String capability) {
    final status = AccountStatusStore.instance.status;
    if (!status.denies(capability)) return true;
    RestrictionExplainerSheet.show(context, status.restrictionFor(capability));
    return false;
  }
}

/// What is restricted, why (in the words the admin wrote for this person),
/// until when, and where to go next.
class RestrictionExplainerSheet extends StatelessWidget {
  const RestrictionExplainerSheet._({required this.restriction});

  final AccountRestriction? restriction;

  static Future<void> show(BuildContext context, AccountRestriction? restriction) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RestrictionExplainerSheet._(restriction: restriction),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = restriction;
    final severe = r == null || r.kind == RestrictionKind.ban || r.kind == RestrictionKind.suspension;
    return Material(
      color: c.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Icon(AppIcons.securityAlert, size: 32, color: severe ? c.criticalText : c.cautionText),
              const SizedBox(height: AppSpace.md),
              Text(r?.kind.title ?? 'Account restricted', style: AppTypeScale.headingM.copyWith(color: c.contentPrimary)),
              const SizedBox(height: AppSpace.xs),
              Text(
                r == null ? "Your account can't do this right now." : r.kind.effect,
                style: AppTypeScale.bodyM.copyWith(color: c.contentSecondary),
              ),
              if (r != null) ...[
                const SizedBox(height: AppSpace.lg),
                RestrictionFacts(restriction: r),
              ],
              const SizedBox(height: AppSpace.xl),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push(MaterialPageRoute(builder: (_) => const AccountStatusScreen()));
                  },
                  child: const Text('View account status'),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              SizedBox(
                width: double.infinity,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reason, the end and the reference of one restriction.
class RestrictionFacts extends StatelessWidget {
  const RestrictionFacts({super.key, required this.restriction});

  final AccountRestriction restriction;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = restriction;
    Widget fact(String label, String value, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTypeScale.meta.copyWith(color: c.contentTertiary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(value, style: style ?? AppTypeScale.bodyM.copyWith(color: c.contentPrimary)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (r.reason.trim().isNotEmpty) fact('Reason', r.reason.trim()),
        fact(
          r.kind == RestrictionKind.ban ? 'Duration' : 'Ends',
          r.endsAt == null
              ? (r.kind == RestrictionKind.ban ? 'Permanent' : 'Until Help24 lifts it')
              : formatRestrictionEnd(r.endsAt!),
        ),
        if (r.reference.isNotEmpty)
          fact('Reference', r.reference, style: AppTypeScale.mono.copyWith(color: c.contentPrimary)),
      ],
    );
  }
}

/// "04 October 2026, 14:00" — the restriction's end, in the phone's time zone.
String formatRestrictionEnd(DateTime at) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final l = at.toLocal();
  final day = l.day.toString().padLeft(2, '0');
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '$day ${months[l.month - 1]} ${l.year}, $hh:$mm';
}

/// The shell's standing notice while a restriction is in force. Renders
/// nothing otherwise — which is every launch for almost everyone.
class AccountStatusBanner extends StatelessWidget {
  const AccountStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AccountStatusStore.instance,
      builder: (context, _) {
        final r = AccountStatusStore.instance.status.primary;
        if (r == null) return const SizedBox.shrink();
        final c = AppColors.of(context);
        final severe = r.kind == RestrictionKind.ban || r.kind == RestrictionKind.suspension;
        final text = switch (r.kind) {
          RestrictionKind.ban => 'Your account has been banned',
          RestrictionKind.suspension =>
            r.endsAt == null ? 'Your account is suspended' : 'Your account is suspended until ${formatRestrictionEnd(r.endsAt!)}',
          RestrictionKind.messaging => 'Messaging is restricted on your account',
          RestrictionKind.marketplace => 'Posting, applying and hiring are restricted',
        };
        return Material(
          color: severe ? c.criticalSubtle : c.cautionSubtle,
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountStatusScreen())),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm + 2),
              child: Row(
                children: [
                  Icon(AppIcons.securityAlert, size: 18, color: severe ? c.criticalText : c.cautionText),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypeScale.bodyS.copyWith(
                        color: severe ? c.criticalText : c.cautionText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text('Details', style: AppTypeScale.label.copyWith(color: severe ? c.criticalText : c.cautionText)),
                  Icon(Icons.chevron_right_rounded, size: 18, color: severe ? c.criticalText : c.cautionText),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Stands in for the chat composer while messaging is denied, so nobody
/// writes a message that cannot be sent.
class RestrictedComposerNotice extends StatelessWidget {
  const RestrictedComposerNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final status = AccountStatusStore.instance.status;
    final r = status.restrictionFor(Capability.message);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        border: Border(top: BorderSide(color: c.borderHairline)),
      ),
      child: Row(
        children: [
          Icon(AppIcons.locked, size: 18, color: c.contentSecondary),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              r?.kind == RestrictionKind.ban
                  ? 'Your account has been banned, so you can’t send messages.'
                  : r?.kind == RestrictionKind.suspension
                      ? 'Your account is suspended, so you can’t send messages right now.'
                      : 'Messaging is restricted on your account right now.',
              style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
            ),
          ),
          TextButton(
            onPressed: () => RestrictionExplainerSheet.show(context, r),
            child: const Text('Why?'),
          ),
        ],
      ),
    );
  }
}
