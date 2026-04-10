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
    return Scaffold(
      appBar: AppBar(title: const Text('Enable location')),
      body: SafeArea(
        child: Consumer<LocationProvider>(
          builder: (context, location, _) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.location_on_rounded, color: AppTheme.primaryAccent),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'See nearby opportunities first',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'We use your location after sign-in to prioritize posts near you. '
                    'You can change this anytime from Settings.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                        ),
                  ),
                  const SizedBox(height: 24),
                  if (location.isPermanentlyDenied)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppTheme.warningOrange.withValues(alpha: 0.15),
                      ),
                      child: const Text(
                        'Location permission is blocked. Open system settings to enable it.',
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: location.isLoading
                          ? null
                          : () async {
                              final ok =
                                  await context.read<LocationProvider>().requestFromExplainer(userId);
                              if (!context.mounted) return;
                              if (ok) {
                                Navigator.pop(context, true);
                              }
                            },
                      child: location.isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Allow'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        await context.read<LocationProvider>().markExplainerShown(userId);
                        if (!context.mounted) return;
                        Navigator.pop(context, false);
                      },
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: () => context.read<LocationProvider>().openSettingsAndRefresh(),
                      child: const Text('Open settings'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
