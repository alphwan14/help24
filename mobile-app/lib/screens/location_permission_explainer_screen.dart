import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/location_provider.dart';
import '../theme/app_theme.dart';

class LocationPermissionExplainerScreen extends StatelessWidget {
  final String userId;

  const LocationPermissionExplainerScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 32),
      child: Consumer<LocationProvider>(
        builder: (context, location, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.location_on_rounded,
                    color: AppTheme.primaryAccent),
              ),
              const SizedBox(height: 16),
              Text(
                'See nearby opportunities first',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'We use your location to show posts near you. '
                'You can change this anytime in Profile → Location Access.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                      height: 1.45,
                    ),
              ),
              if (location.isPermanentlyDenied) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppTheme.warningOrange.withValues(alpha: 0.15),
                  ),
                  child: const Text(
                    'Permission blocked — open Settings to enable location.',
                  ),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: location.isLoading
                      ? null
                      : () async {
                          final ok = await context
                              .read<LocationProvider>()
                              .requestFromExplainer(userId);
                          if (!context.mounted) return;
                          Navigator.pop(context, ok);
                        },
                  child: location.isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Allow location'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton(
                  onPressed: () async {
                    await context
                        .read<LocationProvider>()
                        .markExplainerShown(userId);
                    if (!context.mounted) return;
                    Navigator.pop(context, false);
                  },
                  child: const Text('Not now'),
                ),
              ),
              if (location.isPermanentlyDenied) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () =>
                        context.read<LocationProvider>().openSettingsAndRefresh(),
                    child: const Text('Open settings'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
