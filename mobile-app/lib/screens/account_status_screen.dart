import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_urls.dart';
import '../models/moderation.dart';
import '../services/account_status_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/external_links.dart';
import '../widgets/account_restriction.dart';
import '../widgets/primitives.dart';

/// The person's own standing with Help24, and the way back if something is
/// wrong.
///
/// It shows exactly what `my_account_status()` returns: what is restricted,
/// the reason an admin wrote FOR them, when it ends, and a reference to quote.
/// Never an internal note, never the admin, never who reported them — the
/// database does not return those, so this screen cannot leak them.
class AccountStatusScreen extends StatefulWidget {
  const AccountStatusScreen({super.key});

  @override
  State<AccountStatusScreen> createState() => _AccountStatusScreenState();
}

class _AccountStatusScreenState extends State<AccountStatusScreen> {
  final _store = AccountStatusStore.instance;
  bool _refreshing = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _store.refresh();
    if (!mounted) return;
    setState(() => _refreshing = false);
    // Opening this screen IS being shown the restriction.
    if (_store.unacknowledged != null) unawaited(_store.acknowledge());
  }

  Future<void> _email(String? reference) async {
    final subject = reference == null ? 'Question about my Help24 account' : 'Appeal — reference $reference';
    final uri = Uri(
      scheme: 'mailto',
      path: AppSupport.email,
      query: 'subject=${Uri.encodeComponent(subject)}',
    );
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await launchUrl(uri)) return;
    } catch (_) {
      // Fall through to copying the address.
    }
    await Clipboard.setData(const ClipboardData(text: AppSupport.email));
    messenger.showSnackBar(const SnackBar(
      content: Text('No email app found. We copied ${AppSupport.email} for you.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      appBar: AppBar(title: const Text('Account status')),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final status = _store.status;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.lg, AppSpace.gutter, AppSpace.xxl),
              children: [
                if (!status.isKnown)
                  _refreshing ? const _Loading() : const _Unavailable()
                else if (status.restrictions.isEmpty)
                  const _GoodStanding()
                else
                  for (final r in _ordered(status.restrictions)) ...[
                    _RestrictionCard(restriction: r),
                    const SizedBox(height: AppSpace.md),
                  ],
                if (status.isKnown && status.restrictions.isNotEmpty) const _StillAllowed(),
                if (status.warnings.isNotEmpty) ...[
                  const SectionHeader('Warnings in the last 90 days'),
                  for (final w in status.warnings) ...[
                    _WarningCard(warning: w),
                    const SizedBox(height: AppSpace.sm),
                  ],
                ],
                const SectionHeader('Need help?'),
                AppRowGroup(children: [
                  AppRow(
                    icon: AppIcons.support,
                    title: 'Contact Help24',
                    onTap: () => openHelp24Url(context, AppUrls.supportPortal),
                  ),
                  AppRow(
                    icon: AppIcons.email,
                    title: status.restrictions.isEmpty ? 'Email support' : 'Appeal by email',
                    value: AppSupport.email,
                    onTap: () => _email(status.primary?.reference),
                  ),
                ]),
                const SizedBox(height: AppSpace.md),
                Text(
                  status.restrictions.isEmpty
                      ? 'If one of your listings was hidden, contact us with its title and we will explain why and review it.'
                      : 'To appeal, contact us and quote the reference above. A person reviews every appeal. '
                          'Explain what happened and include anything that shows it — screenshots, receipts or messages.',
                  style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Reports are confidential in both directions: we never tell anyone who reported them, and we '
                  "don't share the outcome of a report with the person who made it.",
                  style: AppTypeScale.meta.copyWith(color: c.contentTertiary),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static List<AccountRestriction> _ordered(List<AccountRestriction> list) {
    int rank(RestrictionKind k) => switch (k) {
          RestrictionKind.ban => 0,
          RestrictionKind.suspension => 1,
          RestrictionKind.marketplace => 2,
          RestrictionKind.messaging => 3,
        };
    return [...list]..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
  }
}

class _RestrictionCard extends StatelessWidget {
  const _RestrictionCard({required this.restriction});

  final AccountRestriction restriction;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = restriction;
    final severe = r.kind == RestrictionKind.ban || r.kind == RestrictionKind.suspension;
    final headline = switch (r.kind) {
      RestrictionKind.ban => 'Your account has been banned',
      RestrictionKind.suspension => r.endsAt == null
          ? 'Your account is temporarily suspended'
          : 'Your account is temporarily suspended until ${formatRestrictionEnd(r.endsAt!)}',
      RestrictionKind.messaging => 'Messaging is restricted on your account',
      RestrictionKind.marketplace => 'Marketplace activity is restricted on your account',
    };
    return AppCard(
      borderColor: severe ? c.criticalFill : c.cautionFill,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppChip(
            label: r.kind.title,
            icon: AppIcons.securityAlert,
            tone: severe ? ChipTone.critical : ChipTone.caution,
          ),
          const SizedBox(height: AppSpace.md),
          Text(headline, style: AppTypeScale.headingS.copyWith(color: c.contentPrimary)),
          const SizedBox(height: AppSpace.xs),
          Text(r.kind.effect, style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary)),
          const SizedBox(height: AppSpace.lg),
          RestrictionFacts(restriction: r),
        ],
      ),
    );
  }
}

class _StillAllowed extends StatelessWidget {
  const _StillAllowed();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xs),
      child: Text(
        'You can still sign in, read your messages and history, approve or dispute work on jobs already paid for, '
        'and contact Help24.',
        style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
      ),
    );
  }
}

class _GoodStanding extends StatelessWidget {
  const _GoodStanding();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      child: Row(
        children: [
          Icon(AppIcons.successFilled, size: 28, color: c.positiveText),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your account is in good standing', style: AppTypeScale.headingS.copyWith(color: c.contentPrimary)),
                const SizedBox(height: 2),
                Text('Nothing on your account is restricted.', style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.warning});

  final AccountWarning warning;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final at = warning.createdAt;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.warning, size: 18, color: c.cautionText),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text('Policy warning', style: AppTypeScale.label.copyWith(color: c.contentPrimary, fontWeight: FontWeight.w600)),
              ),
              if (at != null) Text(formatRestrictionEnd(at), style: AppTypeScale.meta.copyWith(color: c.contentTertiary)),
            ],
          ),
          if (warning.reason.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(warning.reason.trim(), style: AppTypeScale.bodyM.copyWith(color: c.contentPrimary)),
          ],
          if (warning.reference.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text('Reference ${warning.reference}', style: AppTypeScale.mono.copyWith(color: c.contentTertiary, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpace.xxl),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      child: Row(
        children: [
          Icon(AppIcons.info, size: 24, color: c.contentSecondary),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              "We couldn't check your account status right now. Pull down to try again.",
              style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
