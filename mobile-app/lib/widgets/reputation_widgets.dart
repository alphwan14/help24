import 'package:flutter/material.dart';
import '../models/provider_reputation.dart';
import '../services/reputation_service.dart';
import '../theme/app_theme.dart';

// =============================================================================
// Reputation display widgets — backend-sourced trust signals.
//
// Every widget self-loads from ReputationService (GET /reputation/:id). No
// Supabase reads, no fabricated values. Provider STATUS is ALWAYS derived from
// rep.tier (the backend's single source of truth) — never from review count.
// Reviews are a separate signal: 0 reviews => "No Reviews Yet", never a status
// downgrade. completed_jobs is always surfaced so experience shows.
// =============================================================================

Color tierColor(String tier) {
  switch (tier) {
    case 'trusted_professional':
      return const Color(0xFFB45309); // amber-700 (premium)
    case 'highly_recommended':
      return AppTheme.successGreen;
    case 'top_rated':
      return AppTheme.primaryAccent;
    case 'rising_provider':
      return AppTheme.warningOrange;
    case 'new_provider':
    default:
      return const Color(0xFF6B7280); // muted grey
  }
}

/// Small tier chip (e.g. "Highly Recommended").
class TierBadge extends StatelessWidget {
  final String tier;
  final String label;
  final double fontSize;
  const TierBadge({super.key, required this.tier, required this.label, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    final c = tierColor(tier);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: fontSize + 2, color: c),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: c, fontSize: fontSize, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Compact one-line trust signal for discover cards + chat header.
/// "⭐ 4.8 • Top Rated" when reviewed, else the tier label (e.g. "Rising Provider").
class ReputationCompact extends StatelessWidget {
  final String providerId;
  final Color? textColor;
  const ReputationCompact({super.key, required this.providerId, this.textColor});

  @override
  Widget build(BuildContext context) {
    final muted = textColor ?? (Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary);
    return FutureBuilder<ProviderReputation?>(
      future: ReputationService.getReputation(providerId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(width: 56, height: 14);
        }
        final rep = snap.data;
        if (rep == null) return const SizedBox.shrink(); // error: hide, never fake
        // No reviews yet → fall back to the STATUS (tier), never a review-derived
        // "New Provider". A rising_provider with 0 reviews reads "Rising Provider".
        if (!rep.hasReviews) {
          return Text(rep.tierLabel,
              style: TextStyle(color: tierColor(rep.tier), fontSize: 12, fontWeight: FontWeight.w600));
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, size: 14, color: AppTheme.warningOrange),
            const SizedBox(width: 2),
            Text(rep.averageRating.toStringAsFixed(1),
                style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
            if (!rep.isNew) ...[
              Text('  •  ', style: TextStyle(color: muted, fontSize: 12)),
              Flexible(
                child: Text(rep.tierLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tierColor(rep.tier), fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Multi-signal block for application cards + provider selection — the highest
/// priority trust surface. Visibly differentiates trusted vs new providers.
class ReputationTrustBlock extends StatelessWidget {
  final String providerId;
  const ReputationTrustBlock({super.key, required this.providerId});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return FutureBuilder<ProviderReputation?>(
      future: ReputationService.getReputation(providerId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return _loadingBars(muted);
        }
        final rep = snap.data;
        if (rep == null) {
          return Text('Reputation unavailable',
              style: TextStyle(color: muted, fontSize: 12));
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Provider STATUS — single source of truth: rep.tier. Always shown,
            // for new and established providers alike.
            TierBadge(tier: rep.tier, label: rep.tierLabel),
            _pill(
              icon: Icons.task_alt_rounded,
              iconColor: AppTheme.successGreen,
              text: '${rep.completedJobs} ${rep.completedJobs == 1 ? 'Job' : 'Jobs'} Completed',
              muted: muted,
              isDark: isDark,
            ),
            // Reviews — a SEPARATE concept. Absence shows "No Reviews Yet" and
            // never alters the status badge above.
            if (rep.hasReviews)
              _pill(
                icon: Icons.star_rounded,
                iconColor: AppTheme.warningOrange,
                text: '${rep.averageRating.toStringAsFixed(1)} · ${rep.totalReviews} '
                    '${rep.totalReviews == 1 ? 'Review' : 'Reviews'}',
                muted: muted,
                isDark: isDark,
              )
            else
              _pill(
                icon: Icons.rate_review_outlined,
                iconColor: muted,
                text: 'No Reviews Yet',
                muted: muted,
                isDark: isDark,
              ),
          ],
        );
      },
    );
  }

  Widget _pill({
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color muted,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.darkBackground : AppTheme.lightBackground),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: muted, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _loadingBars(Color muted) {
    Widget bar(double w) => Container(
          width: w,
          height: 18,
          decoration: BoxDecoration(
            color: muted.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
        );
    return Wrap(spacing: 8, children: [bar(90), bar(110), bar(80)]);
  }
}

/// Full reputation section for the provider profile.
class ReputationProfileSection extends StatefulWidget {
  final String providerId;
  const ReputationProfileSection({super.key, required this.providerId});

  @override
  State<ReputationProfileSection> createState() => _ReputationProfileSectionState();
}

class _ReputationProfileSectionState extends State<ReputationProfileSection> {
  // Fetched ONCE per providerId and held in State. The profile screen's parent
  // re-renders frequently (UserProfileService.watchUser polls every 15s), and a
  // future created inline in build() would re-fetch and flash the loading
  // spinner on every rebuild. Caching keeps the stats stable; we only re-fetch
  // when the providerId actually changes.
  late Future<ProviderReputation?> _future;

  @override
  void initState() {
    super.initState();
    _future = ReputationService.getReputation(widget.providerId);
  }

  @override
  void didUpdateWidget(covariant ReputationProfileSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) {
      _future = ReputationService.getReputation(widget.providerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: FutureBuilder<ProviderReputation?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
                height: 80, child: Center(child: CircularProgressIndicator()));
          }
          final rep = snap.data;
          if (rep == null) {
            return Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 18, color: muted),
                const SizedBox(width: 8),
                Text('Reputation unavailable', style: TextStyle(color: muted)),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Provider STATUS headline — SINGLE SOURCE OF TRUTH: rep.tier ──
              // Never derived from review count. A provider with completed jobs
              // and zero reviews reads "Rising Provider", not "New Provider".
              Text(
                rep.tierLabel,
                style: TextStyle(
                    color: tierColor(rep.tier), fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              // ── Reviews — a SEPARATE concept. Absence shows "No Reviews Yet"
              // and does NOT downgrade the status above.
              if (rep.hasReviews)
                Row(
                  children: [
                    Icon(Icons.star_rounded, color: AppTheme.warningOrange, size: 22),
                    const SizedBox(width: 4),
                    Text(rep.averageRating.toStringAsFixed(1),
                        style: TextStyle(
                            color: textPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    Text('${rep.totalReviews} ${rep.totalReviews == 1 ? 'review' : 'reviews'}',
                        style: TextStyle(color: muted, fontSize: 14)),
                  ],
                )
              else
                Text('No Reviews Yet',
                    style: TextStyle(color: muted, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 20,
                runSpacing: 14,
                children: [
                  _metric('${rep.completedJobs}', 'Jobs Completed', textPrimary, muted),
                  _metric('${rep.completionPercent}%', 'Completion Rate', textPrimary, muted),
                  _metric('${rep.disputePercent}%', 'Dispute Rate', textPrimary, muted),
                  _metric('${rep.openDisputes}', 'Open Disputes', textPrimary, muted),
                  if (rep.memberSinceYear != null)
                    _metric(rep.memberSinceYear!, 'Member Since', textPrimary, muted),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _metric(String value, String label, Color primary, Color muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(color: primary, fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: muted, fontSize: 12)),
      ],
    );
  }
}
