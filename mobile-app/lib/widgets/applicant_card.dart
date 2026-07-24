import 'package:flutter/material.dart';

import '../models/post_model.dart';
import '../models/provider_reputation.dart';
import '../screens/provider_profile_screen.dart';
import '../services/reputation_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/time_utils.dart';
import 'profile_widgets.dart';
import 'reputation_widgets.dart';

// =============================================================================
// The hiring-decision card.
//
// ONE implementation, used by BOTH the Applications screen and the applicants
// list on post detail. Those two surfaces previously had separate, drifting
// renderings of the same decision — one showed a trust block, the other showed
// nothing but a name and a timestamp.
//
// Everything shown is real and server-derived: profession comes from the
// applicant's users row (carried on the application join), and rating / jobs /
// completion rate / member-since come from ReputationService, which is fed by
// the service-role-only `provider_reputation` table. Nothing here is
// fabricated, and a missing value is omitted rather than shown as zero.
// =============================================================================

class ApplicantCard extends StatelessWidget {
  final Application application;

  /// This applicant has been accepted for the post.
  final bool isSelected;

  /// This card's accept action is in flight.
  final bool isAccepting;

  /// Selection is still open (nobody accepted yet).
  final bool canAccept;

  final VoidCallback onAccept;
  final VoidCallback onMessage;

  /// Show the proposed price badge (only meaningful where a price was offered).
  final bool showPrice;

  const ApplicantCard({
    super.key,
    required this.application,
    required this.isSelected,
    required this.isAccepting,
    required this.canAccept,
    required this.onAccept,
    required this.onMessage,
    this.showPrice = true,
  });

  String get _name =>
      application.applicantName.trim().isNotEmpty ? application.applicantName : 'Anonymous';

  void _openProfile(BuildContext context) {
    if (application.applicantUserId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProviderProfileScreen(
          providerId: application.applicantUserId,
          initialName: _name,
          initialAvatarUrl: application.applicantAvatarUrl,
          initialProfession: application.applicantProfession,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isSelected
            ? AppTheme.successGreen.withValues(alpha: 0.06)
            : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? AppTheme.successGreen.withValues(alpha: 0.4)
              : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Identity: photo, name, profession, applied-when ─────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => _openProfile(context),
                  child: ProfileAvatar(
                    imageUrl: application.applicantAvatarUrl,
                    name: _name,
                    size: 48,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      if (application.applicantProfession.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ProfessionChip(
                            profession: application.applicantProfession,
                            fontSize: 11.5,
                            dense: true,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        'Applied ${formatRelativeTime(application.timestamp).toLowerCase()}',
                        style: TextStyle(color: textTertiary, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                if (showPrice && application.proposedPrice > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      formatPriceDisplay(application.proposedPrice),
                      style: const TextStyle(
                        color: AppTheme.primaryAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),

            // ── Trust: rating, jobs completed, completion rate, member since ─
            const SizedBox(height: 12),
            ApplicantTrustStrip(providerId: application.applicantUserId),

            if (application.message.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                application.message.trim(),
                style: TextStyle(color: textSecondary, fontSize: 13, height: 1.45),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],

            const SizedBox(height: 14),

            // ── Decision ────────────────────────────────────────────────────
            if (isSelected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.successGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded,
                        color: AppTheme.successGreen, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'Provider Accepted',
                      style: TextStyle(
                        color: AppTheme.successGreen,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  // View Profile leads; the whole point of the card is an
                  // informed decision, and the profile is where the evidence is.
                  TextButton.icon(
                    onPressed: application.applicantUserId.isEmpty
                        ? null
                        : () => _openProfile(context),
                    icon: const Icon(Icons.person_outline_rounded, size: 15),
                    label: const Text('View Profile'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle:
                          const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton.icon(
                      onPressed: onMessage,
                      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
                      label: const Text('Message'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle:
                            const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  // Accept disappears once someone else is chosen, so the list
                  // never invites an impossible selection.
                  if (canAccept || isAccepting) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 36,
                      child: FilledButton(
                        onPressed: canAccept ? onAccept : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          backgroundColor: AppTheme.successGreen,
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        child: isAccepting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Accept'),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The trust line on an applicant card: tier badge, rating, jobs completed,
/// completion rate, member since — exactly the signals a client needs to
/// compare two strangers.
///
/// Loads once per providerId and holds the future in State (list cards rebuild
/// constantly; a future created in build() re-resolves every frame and flickers).
/// A value that does not exist is OMITTED — a provider with no completed jobs
/// shows "New on Help24", never "0% completion".
class ApplicantTrustStrip extends StatefulWidget {
  final String providerId;

  const ApplicantTrustStrip({super.key, required this.providerId});

  @override
  State<ApplicantTrustStrip> createState() => _ApplicantTrustStripState();
}

class _ApplicantTrustStripState extends State<ApplicantTrustStrip> {
  late Future<ProviderReputation?> _future;
  ProviderReputation? _cached;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ApplicantTrustStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) _load();
  }

  void _load() {
    _cached = ReputationService.getCachedSync(widget.providerId);
    _future = ReputationService.getReputation(widget.providerId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return FutureBuilder<ProviderReputation?>(
      future: _future,
      initialData: _cached,
      builder: (context, snap) {
        final rep = snap.data;
        if (rep == null) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Wrap(
              spacing: 8,
              children: [_skeleton(muted, 92), _skeleton(muted, 76), _skeleton(muted, 84)],
            );
          }
          // Never fabricate. Say the truth and move on.
          return Text('Reputation unavailable',
              style: TextStyle(color: muted, fontSize: 11.5));
        }

        final hasActivity = rep.completedJobs > 0 || rep.hasReviews;

        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TierBadge(tier: rep.tier, label: rep.tierLabel, fontSize: 11),
            if (rep.hasReviews)
              _stat(
                icon: Icons.star_rounded,
                iconColor: AppTheme.warningOrange,
                text: '${rep.averageRating.toStringAsFixed(1)} '
                    '(${rep.totalReviews})',
                muted: muted,
                isDark: isDark,
              ),
            if (rep.completedJobs > 0)
              _stat(
                icon: Icons.task_alt_rounded,
                iconColor: AppTheme.successGreen,
                text: '${rep.completedJobs} '
                    '${rep.completedJobs == 1 ? 'job' : 'jobs'} done',
                muted: muted,
                isDark: isDark,
              ),
            // A completion rate over zero concluded jobs is not a fact.
            if (hasActivity && rep.completedJobs > 0)
              _stat(
                icon: Icons.trending_up_rounded,
                iconColor: AppTheme.primaryAccent,
                text: '${rep.completionPercent}% completion',
                muted: muted,
                isDark: isDark,
              ),
            if (rep.memberSinceYear != null)
              _stat(
                icon: Icons.event_available_rounded,
                iconColor: muted,
                text: 'Since ${rep.memberSinceYear}',
                muted: muted,
                isDark: isDark,
              ),
            if (!hasActivity)
              _stat(
                icon: Icons.auto_awesome_rounded,
                iconColor: muted,
                text: 'New on Help24',
                muted: muted,
                isDark: isDark,
              ),
          ],
        );
      },
    );
  }

  Widget _stat({
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color muted,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(color: muted, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _skeleton(Color muted, double width) => Container(
        width: width,
        height: 20,
        decoration: BoxDecoration(
          color: muted.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
      );
}
