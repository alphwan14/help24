import 'package:flutter/material.dart';

import '../services/app_updater.dart';
import '../theme/tokens.dart';

/// The in-app update, step by step: the Update button with the size, the
/// download with its progress, the checksum check, the one-time permission,
/// and Android's install prompt. Used in the bottom sheet the update banner
/// opens, and inline on the blocking update screen.
///
/// Copy is in Dart, not en.json (a Shorebird patch cannot change assets).
class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key, required this.target, this.updater});

  final UpdateTarget target;

  /// Injected in tests; the app uses [AppUpdater.instance].
  final AppUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final u = updater ?? AppUpdater.instance;
    return AnimatedBuilder(
      animation: u,
      builder: (context, _) {
        final current = u.target == target ? u.phase : UpdatePhase.idle;
        return switch (current) {
          UpdatePhase.idle => _Start(target: target, updater: u),
          UpdatePhase.downloading => _Downloading(target: target, updater: u),
          UpdatePhase.verifying => const _Status(text: 'Checking the download', busy: true),
          UpdatePhase.needsPermission => _Step(
              text: 'Android asks you once to let Help24 install its updates. '
                  'Turn on "Allow from this source", then come back.',
              action: 'Open settings',
              onPressed: u.openInstallSettings,
            ),
          UpdatePhase.readyToInstall => _Step(
              text: 'Tap Install on the next screen to finish.',
              action: 'Install update',
              onPressed: u.installAgain,
            ),
          UpdatePhase.failed => _Step(
              text: _failureText(u.failure),
              action: 'Try again',
              onPressed: u.retry,
              critical: true,
            ),
        };
      },
    );
  }

  static String _failureText(UpdateFailure? f) => switch (f) {
        UpdateFailure.checksum =>
          "The download didn't match the published file, so it was deleted. Nothing was installed.",
        UpdateFailure.installer => "Android's installer didn't open. Try again in a moment.",
        UpdateFailure.storage => "The download couldn't be saved on this phone. Free some space and try again.",
        _ => 'The download stopped. Check your connection, then try again. It picks up where it left off.',
      };
}

class _Start extends StatelessWidget {
  const _Start({required this.target, required this.updater});

  final UpdateTarget target;
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final partial = updater.target == target && updater.received > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<bool>(
          future: updater.isOnWifi(),
          builder: (context, snap) {
            if (snap.data != false) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: Text(
                "You're on mobile data. The update is ${formatUpdateSize(target.sizeBytes)}.",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.contentSecondary),
              ),
            );
          },
        ),
        FilledButton(
          onPressed: () => updater.start(target),
          child: Text(partial
              ? 'Continue update, ${formatUpdateSize(updater.received)} of ${formatUpdateSize(target.sizeBytes)}'
              : 'Update, ${formatUpdateSize(target.sizeBytes)}'),
        ),
      ],
    );
  }
}

class _Downloading extends StatelessWidget {
  const _Downloading({required this.target, required this.updater});

  final UpdateTarget target;
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: LinearProgressIndicator(value: updater.progress, minHeight: 6),
        ),
        const SizedBox(height: AppSpace.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                'Downloading, ${formatUpdateSize(updater.received)} of ${formatUpdateSize(target.sizeBytes)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.contentSecondary),
              ),
            ),
            TextButton(onPressed: updater.cancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.text, this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: const LinearProgressIndicator(minHeight: 6),
          ),
        const SizedBox(height: AppSpace.sm),
        Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.contentSecondary)),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.text, required this.action, required this.onPressed, this.critical = false});

  final String text;
  final String action;
  final Future<void> Function() onPressed;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: critical ? c.criticalText : c.contentPrimary,
              ),
        ),
        const SizedBox(height: AppSpace.md),
        FilledButton(onPressed: onPressed, child: Text(action)),
      ],
    );
  }
}

/// The update banner's Update button: a sheet with the message and the panel.
Future<void> showUpdateSheet(BuildContext context, {required UpdateTarget target, required String message}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final c = AppColors.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Update Help24', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpace.sm),
              Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.contentSecondary)),
              const SizedBox(height: AppSpace.xl),
              UpdatePanel(target: target),
            ],
          ),
        ),
      );
    },
  );
}
