import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';
import '../providers/connectivity_provider.dart';
import '../theme/app_theme.dart';

/// Consistent loading view (spinner + message). Use when data is being fetched.
class LoadingView extends StatelessWidget {
  final String? message;

  const LoadingView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.primaryAccent,
            ),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              message!,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Consistent empty state: icon, title, subtitle, optional actions.
class EmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget>? actions;

  const EmptyStateView({
    super.key,
    this.icon = Iconsax.document,
    required this.title,
    required this.subtitle,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                size: 36,
                color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
              textAlign: TextAlign.center,
            ),
            if (actions != null && actions!.isNotEmpty) ...[
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: actions!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The FAILURE state of the universal load contract: Loading → Success | Empty
/// | Failure→Retry. Distinct from [EmptyStateView] on purpose — "we couldn't
/// load this" must never be rendered as "there's nothing here", because the two
/// call for different user actions (retry vs. nothing to do). Pair the [message]
/// with an [ErrorMapper]-produced string so it is always human, never technical.
class ErrorRetryView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;

  const ErrorRetryView({
    super.key,
    required this.message,
    this.onRetry,
    this.icon = Iconsax.warning_2,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 56,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
            const SizedBox(height: 18),
            Text(
              "We couldn't load this",
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Re-runs [onReconnect] whenever the app transitions offline → online, so a
/// screen that owns its own fetch (Notifications, Saved, Urgent, …) recovers
/// automatically without the user leaving and returning. Wrap the screen body:
///
///   ReconnectListener(onReconnect: _load, child: ...)
///
/// Subscribes to the single [ConnectivityProvider.onReconnect] edge source, so
/// every screen shares one definition of "reconnected" instead of duplicating
/// `_wasOffline` bookkeeping.
class ReconnectListener extends StatefulWidget {
  final Widget child;
  final VoidCallback onReconnect;

  const ReconnectListener({
    super.key,
    required this.onReconnect,
    required this.child,
  });

  @override
  State<ReconnectListener> createState() => _ReconnectListenerState();
}

class _ReconnectListenerState extends State<ReconnectListener> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    // read (not watch) — we want the stream, not rebuilds on connectivity ticks.
    _sub = context.read<ConnectivityProvider>().onReconnect.listen((_) {
      if (mounted) widget.onReconnect();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Offline empty state when there is no cached data to show.
class OfflineEmptyView extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;

  const OfflineEmptyView({super.key, this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Iconsax.wifi_square,
              size: 64,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
            const SizedBox(height: 20),
            Text(
              message ?? 'No internet connection',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to load content.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Subtle banner shown at top when the app is offline. Does not block content.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    // Two different failures deserve two different sentences. "No connection"
    // sends someone to check their Wi-Fi; but the common case on mobile data is
    // a live radio carrying nothing — an expired bundle — and telling that user
    // they have "no connection" is misleading, because their phone plainly
    // shows bars. Naming it is the difference between a confusing app and one
    // that tells them to top up.
    final connectivity = context.watch<ConnectivityProvider>();
    final unreachable = connectivity.isConnectedButUnreachable;
    final checking = connectivity.isProbing;
    // Brief, calm labels — this is a background state indicator on the Discover
    // feed, not an alarm. Recovery is automatic, so we don't nag with a Retry
    // button; the whole strip stays quietly tappable for the impatient.
    final message = checking
        ? 'Checking connection…'
        : unreachable
            ? 'Help24 is temporarily unavailable'
            : 'No internet connection';

    return Semantics(
      liveRegion: true,
      label: message,
      child: Material(
        color: AppTheme.warningOrange.withValues(alpha: 0.2),
        child: InkWell(
          // Quietly tappable to force a check, but no loud Retry label —
          // recovery happens on its own the moment the connection returns.
          onTap: checking ? null : () => connectivity.checkNow(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              children: [
                Icon(
                  unreachable ? Iconsax.global_refresh : Iconsax.wifi_square,
                  size: 18,
                  color: AppTheme.warningOrange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.warningOrange,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Continuously pulsing wrapper for skeleton placeholders: fades out, fades
/// back in, and loops until the skeleton is removed from the tree (i.e. until
/// the real data arrives). Opacity is driven by [FadeTransition] at the render
/// layer — no widget rebuilds per frame — and the single [AnimationController]
/// is disposed with the skeleton, so there is no idle animation cost.
class SkeletonPulse extends StatefulWidget {
  final Widget child;

  const SkeletonPulse({super.key, required this.child});

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(begin: 1.0, end: 0.45)
      .chain(CurveTween(curve: Curves.easeInOut))
      .animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

/// Lightweight skeleton list used while feed data loads in background.
class FeedSkeletonList extends StatelessWidget {
  final int itemCount;
  final EdgeInsetsGeometry padding;

  const FeedSkeletonList({
    super.key,
    this.itemCount = 3,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final lineColor = isDark
        ? AppTheme.darkTextTertiary.withValues(alpha: 0.18)
        : AppTheme.lightTextTertiary.withValues(alpha: 0.18);

    return SkeletonPulse(
        child: ListView.separated(
      padding: padding,
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _skeletonLine(lineColor, 120, 10),
            const SizedBox(height: 8),
            _skeletonLine(lineColor, double.infinity, 14),
            const SizedBox(height: 6),
            _skeletonLine(lineColor, 180, 14),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: lineColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _skeletonLine(lineColor, 120, 10)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _skeletonLine(lineColor, 130, 12)),
                const SizedBox(width: 8),
                Container(
                  width: 76,
                  height: 34,
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ));
  }

  Widget _skeletonLine(Color color, double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

/// Skeleton placeholder list for the conversation/messages screen.
class ConversationSkeletonList extends StatelessWidget {
  final int itemCount;

  const ConversationSkeletonList({super.key, this.itemCount = 6});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor = isDark
        ? AppTheme.darkTextTertiary.withValues(alpha: 0.18)
        : AppTheme.lightTextTertiary.withValues(alpha: 0.18);

    return SkeletonPulse(
        child: ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: itemCount,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: lineColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 13,
                    width: 120,
                    decoration: BoxDecoration(
                      color: lineColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 11,
                    decoration: BoxDecoration(
                      color: lineColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 11,
                    width: 160,
                    decoration: BoxDecoration(
                      color: lineColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  height: 10,
                  width: 36,
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ));
  }
}
