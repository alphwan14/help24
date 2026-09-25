import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/provider_reputation.dart';
import '../providers/connectivity_provider.dart';
import '../services/reputation_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'primitives.dart';

// =============================================================================
// Reputation display widgets — backend-sourced trust signals.
//
// Every widget self-loads from ReputationService (GET /reputation/:id). No
// Supabase reads, no fabricated values. Provider STATUS is ALWAYS derived from
// rep.tier (the backend's single source of truth) — never from review count.
// Reviews are a separate signal: 0 reviews => "No Reviews Yet", never a status
// downgrade. completed_jobs is always surfaced so experience shows.
// =============================================================================

/// How far up the ladder a provider is, in the steps EMPHASIS can carry.
///
/// ── The problem with five hues ──────────────────────────────────────────
/// The backend names five rungs — new → rising → top rated → highly
/// recommended → trusted professional — and the app used to paint each one a
/// different hue: amber, green, blue, terracotta, grey. Five unrelated colours
/// say "five unrelated categories", not "five rungs of one ladder". Nothing
/// about green tells you it outranks blue, so the reader has to learn a key
/// that is written down nowhere, and most never do.
///
/// ── Why not a five-step single-hue ramp ─────────────────────────────────
/// That was the obvious fix, and it does not survive measurement. Across the
/// whole amber ramp there is no set of four values that each clear 4.5:1 as
/// text on warm paper AND on a dark card — the same wall that made
/// `AppColors` necessary in the first place. A ramp that fails AA on two of
/// its rungs is not a ramp, it is the old bug in one colour.
///
/// ── What this does instead ──────────────────────────────────────────────
/// Emphasis carries about three steps honestly, so it carries three:
///
///   unproven    neutral tint, no tick   — "has not established anything yet"
///   established accent tint, tick       — "this is a standing worth reading"
///   top         accent FILL, tick       — the one rung that gets the brand
///
/// Monotone, so it reads as a ladder with no key, and the exact rung is still
/// named in words by [ProviderReputation.tierLabel], which is the part of the
/// design that was already doing the job properly. Claiming five visual steps
/// is what produced five hues; three that are actually distinguishable beats
/// five that are not.
enum TierStanding {
  /// new_provider, rising_provider.
  unproven,

  /// top_rated, highly_recommended.
  established,

  /// trusted_professional — the single accent moment on the surface.
  top,
}

/// Which rung a backend tier key sits on. Unknown keys read as [unproven],
/// never as a standing the provider has not earned.
TierStanding tierStanding(String tier) => switch (tier) {
      'trusted_professional' => TierStanding.top,
      'highly_recommended' || 'top_rated' => TierStanding.established,
      _ => TierStanding.unproven,
    };

/// The colour of a provider tier label drawn as PLAIN TEXT (the chat header,
/// the compact feed signal). The chip form is [TierBadge].
///
/// It takes a context because it used to be a pure function over five
/// hard-coded values, two of them raw hexes chosen for the light theme alone.
/// Measured on a dark card, `#B45309` (trusted) was **3.27:1** and `#6B7280`
/// (new) **3.40:1** — both below AA, on a label whose entire job is to be read.
Color tierColor(BuildContext context, String tier) {
  final c = AppColors.of(context);
  return switch (tierStanding(tier)) {
    TierStanding.top || TierStanding.established => c.accentText,
    TierStanding.unproven => c.contentSecondary,
  };
}

/// Small tier chip (e.g. "Highly Recommended").
class TierBadge extends StatelessWidget {
  final String tier;
  final String label;

  /// Retained so existing call sites keep compiling. [AppChip] owns chip
  /// sizing now — one height per size, across the whole app — so this only
  /// chooses between the two of them.
  final double fontSize;

  const TierBadge({
    super.key,
    required this.tier,
    required this.label,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final standing = tierStanding(tier);
    return AppChip(
      label: label,
      // A tick is a claim about VERIFICATION, so the rung that has not
      // established anything does not get one. The old badge drew it
      // unconditionally, which meant a provider who had never taken a job
      // rendered "New Provider" behind a verified tick — the one place in the
      // app where the trust signal said the opposite of the truth.
      icon: standing == TierStanding.unproven ? null : AppIcons.verifiedProvider,
      tone: standing == TierStanding.unproven ? ChipTone.neutral : ChipTone.accent,
      solid: standing == TierStanding.top,
      size: fontSize >= 12 ? ChipSize.md : ChipSize.sm,
    );
  }
}

/// Compact one-line trust signal for discover cards + chat header.
/// "⭐ 4.8 • Top Rated" when reviewed, else the tier label (e.g. "Rising Provider").
class ReputationCompact extends StatefulWidget {
  final String providerId;
  final Color? textColor;
  const ReputationCompact({super.key, required this.providerId, this.textColor});

  @override
  State<ReputationCompact> createState() => _ReputationCompactState();
}

class _ReputationCompactState extends State<ReputationCompact> {
  // Future is created ONCE per providerId and held in State. Feed cards rebuild
  // constantly (AuthProvider notifications, scrolling, pull-to-refresh); a
  // future created inline in build() re-resolved on every rebuild and flashed
  // an empty placeholder for a frame each time — visible as rating flicker.
  // The sync cache read additionally covers the one-frame gap on rebuilds
  // where the service cache is already warm.
  late Future<ReputationResult> _future;
  ReputationResult _seed = const ReputationResult(null, ReputationOutcome.ok);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReputationCompact oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) _load();
  }

  void _load() {
    // Stale-but-real beats a gap: a feed card reopened from disk cache shows
    // the tier it showed yesterday, and the refresh corrects it behind the user.
    _seed = ReputationService.peek(widget.providerId);
    _future = ReputationService.getResult(widget.providerId);
  }

  @override
  Widget build(BuildContext context) {
    final muted = widget.textColor ?? (Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary);
    return FutureBuilder<ReputationResult>(
      future: _future,
      initialData: _seed.hasValue ? _seed : null,
      builder: (context, snap) {
        final rep = snap.data?.rep;
        if (rep == null) {
          // Still loading → hold layout space; error → hide, never fake. A feed
          // card is not the place to explain the network; the surfaces where
          // the signal is the POINT (applicant list, profile) say it instead.
          return snap.connectionState == ConnectionState.waiting
              ? const SizedBox(width: 56, height: 14)
              : const SizedBox.shrink();
        }
        // No reviews yet → fall back to the STATUS (tier), never a review-derived
        // "New Provider". A rising_provider with 0 reviews reads "Rising Provider".
        if (!rep.hasReviews) {
          return Text(rep.tierLabel,
              style: TextStyle(color: tierColor(context, rep.tier), fontSize: 12, fontWeight: FontWeight.w600));
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.reviewFilled, size: 14, color: AppTheme.warningOrange),
            const SizedBox(width: 2),
            Text(rep.averageRating.toStringAsFixed(1),
                style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w700)),
            if (!rep.isNew) ...[
              Text('  •  ', style: TextStyle(color: muted, fontSize: 12)),
              Flexible(
                child: Text(rep.tierLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tierColor(context, rep.tier), fontSize: 12, fontWeight: FontWeight.w600)),
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
class ReputationTrustBlock extends StatefulWidget {
  final String providerId;
  const ReputationTrustBlock({super.key, required this.providerId});

  @override
  State<ReputationTrustBlock> createState() => _ReputationTrustBlockState();
}

class _ReputationTrustBlockState extends State<ReputationTrustBlock> {
  // Same anti-flicker pattern as ReputationCompact: future held in State,
  // sync cache covers the waiting frame on rebuilds.
  late Future<ReputationResult> _future;
  ReputationResult _seed = const ReputationResult(null, ReputationOutcome.ok);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReputationTrustBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) _load();
  }

  void _load() {
    _seed = ReputationService.peek(widget.providerId);
    _future = ReputationService.getResult(widget.providerId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return FutureBuilder<ReputationResult>(
      future: _future,
      initialData: _seed.hasValue ? _seed : null,
      builder: (context, snap) {
        final rep = snap.data?.rep;
        if (rep == null) {
          if (snap.connectionState == ConnectionState.waiting) {
            return _loadingBars(muted);
          }
          final offline = snap.data?.outcome == ReputationOutcome.offline;
          return Text(
            offline
                ? "You're offline — ratings will appear when you reconnect"
                : "Couldn't load ratings — pull down to retry",
            style: TextStyle(color: muted, fontSize: 12),
          );
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
              icon: AppIcons.completedWork,
              iconColor: AppTheme.successGreen,
              text: '${rep.completedJobs} ${rep.completedJobs == 1 ? 'Job' : 'Jobs'} Completed',
              muted: muted,
              isDark: isDark,
            ),
            // Reviews — a SEPARATE concept. Absence shows "No Reviews Yet" and
            // never alters the status badge above.
            if (rep.hasReviews)
              _pill(
                icon: AppIcons.reviewFilled,
                iconColor: AppTheme.warningOrange,
                text: '${rep.averageRating.toStringAsFixed(1)} · ${rep.totalReviews} '
                    '${rep.totalReviews == 1 ? 'Review' : 'Reviews'}',
                muted: muted,
                isDark: isDark,
              )
            else
              _pill(
                icon: AppIcons.review,
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
        borderRadius: AppRadius.pillAll,
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
            borderRadius: AppRadius.pillAll,
          ),
        );
    return Wrap(spacing: 8, children: [bar(90), bar(110), bar(80)]);
  }
}

/// Full reputation section for the provider profile.
class ReputationProfileSection extends StatefulWidget {
  final String providerId;

  /// The value the HOST screen already resolved, when it resolved one.
  ///
  /// The provider profile awaits reputation as part of its own load and then
  /// rendered this widget, which went and fetched the very same thing again on
  /// its own schedule — so the page opened complete except for one panel that
  /// spun by itself for a moment afterwards. Passing the value down means the
  /// screen paints in one piece: when the page appears, this is already on it.
  final ProviderReputation? seed;

  const ReputationProfileSection({
    super.key,
    required this.providerId,
    this.seed,
  });

  @override
  State<ReputationProfileSection> createState() => _ReputationProfileSectionState();
}

class _ReputationProfileSectionState extends State<ReputationProfileSection> {
  // Fetched ONCE per providerId and held in State. The profile screen's parent
  // re-renders frequently (UserProfileService.watchUser polls every 15s), and a
  // future created inline in build() would re-fetch and flash the loading
  // spinner on every rebuild. Caching keeps the stats stable; we only re-fetch
  // when the providerId actually changes.
  late Future<ReputationResult> _future;
  ReputationResult? _seed;
  StreamSubscription<void>? _reconnectSub;

  @override
  void initState() {
    super.initState();
    _load();
    // A fetch that failed while offline is NOT cached (only successes are), so
    // when the connection returns we re-fetch and the unavailable state fills
    // in on its own — no need to reopen the tab.
    _reconnectSub =
        context.read<ConnectivityProvider>().onReconnect.listen((_) => _onReconnect());
  }

  void _load() {
    final seeded = widget.seed;
    _seed = seeded != null
        ? ReputationResult(seeded, ReputationOutcome.ok)
        : ReputationService.peek(widget.providerId);
    _future = ReputationService.getResult(widget.providerId);
  }

  @override
  void didUpdateWidget(covariant ReputationProfileSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) {
      _load();
    } else if (oldWidget.seed == null && widget.seed != null) {
      // The host resolved it after this mounted — take the value rather than
      // keep spinning over a fetch for something already in hand.
      _seed = ReputationResult(widget.seed, ReputationOutcome.ok);
    }
  }

  void _onReconnect() {
    if (!mounted) return;
    // Only re-fetch when we don't already hold a fresh value — a prior failure
    // leaves no cache entry, so this refreshes exactly the unavailable case
    // without flashing a spinner over reputation that already loaded.
    if (ReputationService.getCachedSync(widget.providerId) == null) {
      setState(() {
        _future = ReputationService.getResult(widget.providerId);
      });
    }
  }

  @override
  void dispose() {
    _reconnectSub?.cancel();
    super.dispose();
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
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: border),
      ),
      child: FutureBuilder<ReputationResult>(
        future: _future,
        // With a seed there is no waiting state at all — the panel is on the
        // page the moment the page is.
        initialData: _seed != null && _seed!.hasValue ? _seed : null,
        builder: (context, snap) {
          final rep = snap.data?.rep;
          if (rep == null) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                  height: 80, child: Center(child: CircularProgressIndicator()));
            }
            final offline = snap.data?.outcome == ReputationOutcome.offline;
            return Row(
              children: [
                Icon(offline ? AppIcons.offline : AppIcons.unreachable,
                    size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    offline
                        ? "You're offline — this provider's record will load when you reconnect."
                        : "Couldn't load this provider's record. Pull down to retry.",
                    style: TextStyle(color: muted),
                  ),
                ),
              ],
            );
          }
          // Honest new-user state: someone with no provider activity should
          // read "you're new here", not a zero-filled report card
          // ("0 jobs · 0% · 0% · 0 disputes"). Every value is still real —
          // we just don't dress zeros up as performance metrics.
          final hasProviderActivity =
              rep.completedJobs > 0 || rep.hasReviews || rep.openDisputes > 0;
          if (!hasProviderActivity) {
            return Row(
              children: [
                Icon(AppIcons.verified, size: 20, color: tierColor(context, rep.tier)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rep.memberSinceYear != null
                            ? 'New on Help24 · Member since ${rep.memberSinceYear}'
                            : 'New on Help24',
                        style: TextStyle(
                            color: textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Stats appear after your first completed job.',
                        style: TextStyle(color: muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
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
                    color: tierColor(context, rep.tier), fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              // ── Reviews — a SEPARATE concept. Absence shows "No Reviews Yet"
              // and does NOT downgrade the status above.
              if (rep.hasReviews)
                Row(
                  children: [
                    Icon(AppIcons.reviewFilled, color: AppTheme.warningOrange, size: 22),
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
                  // COUNTS are always honest. A provider who has finished three
                  // jobs has finished three jobs.
                  _metric('${rep.completedJobs}', 'Jobs Completed', textPrimary, muted),
                  // PERCENTAGES need a sample, and are withheld without one.
                  // See [_percentagesAreMeaningful].
                  if (_percentagesAreMeaningful(rep)) ...[
                    _metric('${rep.completionPercent}%', 'Completion Rate',
                        textPrimary, muted),
                    // Only when there is something to report. A "0% Dispute
                    // Rate" is a claim nobody earned by not being complained
                    // about yet, and it took a slot from a metric that meant
                    // something.
                    if (rep.disputePercent > 0)
                      _metric('${rep.disputePercent}%', 'Dispute Rate',
                          textPrimary, muted),
                  ],
                  // A LIVE dispute is material at any sample size, so it is not
                  // gated — but "0 Open Disputes" is not news, and printing it
                  // beside a dispute RATE was two metrics for one idea.
                  if (rep.openDisputes > 0)
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

  /// How many completed jobs a provider needs before a PERCENTAGE about them
  /// is worth printing.
  ///
  /// ── The bug this fixes ──────────────────────────────────────────────────
  /// A public profile rendered `44% Dispute Rate` in the same size and weight
  /// as `Jobs Completed`. The number was arithmetically correct and
  /// informationally worthless: at these volumes it was 4 of 9. One unhappy
  /// client on a provider with two jobs reads **50% Dispute Rate** — a figure
  /// that will follow them for as long as it takes to dilute, on a marketplace
  /// where, as of this writing, there is no provider with enough completed work
  /// to dilute anything.
  ///
  /// The same trap runs the other way: 1 job finished out of 1 prints
  /// `100% Completion Rate`, which is a five-star claim earned by a single
  /// transaction. Both directions are the same mistake — a ratio presented as a
  /// rate without the denominator that would let anyone judge it.
  ///
  /// So the rule is: **counts always, percentages only with a sample.** Below
  /// the threshold the profile shows what is known (jobs completed, member
  /// since, any live dispute) and makes no claims it cannot support. Nothing is
  /// hidden that a client can act on — an OPEN dispute is shown at any volume,
  /// because that one is a fact about right now rather than a rate.
  ///
  /// Five is a product choice, not a statistical one; at five, one dispute
  /// reads 20%, which is at least directionally honest. Raise it if the
  /// marketplace grows into it.
  static const int _percentageMinimumSample = 5;

  static bool _percentagesAreMeaningful(ProviderReputation rep) =>
      rep.completedJobs >= _percentageMinimumSample;

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
