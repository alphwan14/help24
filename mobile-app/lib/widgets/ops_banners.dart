import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../services/remote_config_service.dart';
import '../theme/app_theme.dart';
import '../utils/external_links.dart';

/// The operational surfaces the backend can raise without an app release:
/// a maintenance notice, a product announcement, and the two update prompts.
///
/// DESIGN RULE: these INFORM, they do not obstruct.
///
/// [OpsBanners] is a strip above the tab content — it never covers what the
/// user was doing, never intercepts a tap, and never appears over a flow in
/// progress. The single exception is [HardUpdateScreen], which is the one
/// control whose entire purpose is to stop the app being used; it is shown only
/// at cold start, from the launch snapshot, so it can never interrupt a payment
/// that is already running. See RemoteConfigService.launchConfig.
///
/// Everything here degrades to nothing: with no config fetched, no banner shows
/// and the app looks exactly as it does today.
class OpsBanners extends StatelessWidget {
  const OpsBanners({super.key});

  @override
  Widget build(BuildContext context) {
    // Listens to the singleton directly rather than through a Provider: this
    // is app-wide infrastructure with one instance, and threading it through
    // the provider tree would buy nothing but a wiring step.
    return AnimatedBuilder(
      animation: RemoteConfigService.instance,
      builder: (context, _) {
        final config = RemoteConfigService.instance;
        final banners = <Widget>[];

        // Order is deliberate: an outage outranks an upgrade nudge, which
        // outranks a product announcement.
        if (config.config.maintenance.shouldShow) {
          banners.add(_OpsBanner(
            key: const ValueKey('maintenance'),
            icon: Iconsax.warning_2,
            tone: AppTheme.warningOrange,
            message: config.config.maintenance.message,
          ));
        }

        if (config.suggestsUpdate) {
          final minVersion = config.config.minVersion;
          banners.add(_OpsBanner(
            key: const ValueKey('soft-update'),
            icon: Iconsax.arrow_circle_up,
            tone: AppTheme.primaryAccent,
            message: minVersion.message.trim().isEmpty
                ? 'A newer version of Help24 is available.'
                : minVersion.message,
            actionLabel: minVersion.storeUrl.trim().isEmpty ? null : 'Update',
            onAction: minVersion.storeUrl.trim().isEmpty
                ? null
                : () => openHelp24Url(context, minVersion.storeUrl),
          ));
        }

        final announcement = config.visibleAnnouncement;
        if (announcement != null) {
          banners.add(_OpsBanner(
            key: ValueKey('announcement-${announcement.id}'),
            icon: Iconsax.info_circle,
            tone: AppTheme.secondaryAccent,
            message: announcement.message,
            actionLabel: announcement.url.trim().isEmpty ? null : 'Learn more',
            onAction: announcement.url.trim().isEmpty
                ? null
                : () => openHelp24Url(context, announcement.url),
            onDismiss: () => config.dismissAnnouncement(announcement.id),
          ));
        }

        if (banners.isEmpty) return const SizedBox.shrink();
        return Column(mainAxisSize: MainAxisSize.min, children: banners);
      },
    );
  }
}

class _OpsBanner extends StatelessWidget {
  const _OpsBanner({
    super.key,
    required this.icon,
    required this.tone,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final IconData icon;
  final Color tone;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          fontWeight: FontWeight.w500,
        );

    return Material(
      color: tone.withValues(alpha: isDark ? 0.16 : 0.10),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: tone),
              const SizedBox(width: 10),
              Expanded(child: Text(message, style: textStyle)),
              if (actionLabel != null)
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: tone,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(actionLabel!),
                ),
              if (onDismiss != null)
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Iconsax.close_circle, size: 18),
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The blocking update screen.
///
/// The ONE surface in this plane that stops the app being used, so it is
/// deliberately hard to trigger: it renders only when the LAUNCH snapshot puts
/// the running version below `min_version.hard`. A hard gate arriving mid-session
/// waits for the next cold start — the remedy is a store visit either way, and
/// yanking someone out of a half-finished payment to tell them so would be a
/// worse failure than the stale client.
class HardUpdateScreen extends StatelessWidget {
  const HardUpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final config = RemoteConfigService.instance;
    final minVersion = config.launchConfig.minVersion;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Iconsax.arrow_circle_up,
                    size: 56, color: AppTheme.primaryAccent),
                const SizedBox(height: 24),
                Text(
                  'Update Help24 to continue',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  minVersion.message.trim().isEmpty
                      ? 'This version of Help24 is no longer supported. '
                          'Please update to keep using the app.'
                      : minVersion.message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                ),
                const SizedBox(height: 32),
                if (minVersion.storeUrl.trim().isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () =>
                          openHelp24Url(context, minVersion.storeUrl),
                      child: const Text('Update now'),
                    ),
                  ),
                if (config.appVersion.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Installed version ${config.appVersion}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AppTheme.darkTextTertiary
                              : AppTheme.lightTextTertiary,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
