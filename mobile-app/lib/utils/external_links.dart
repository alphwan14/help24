import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import 'error_mapper.dart';

/// Opens a Help24 web address (Help Centre, Privacy, Terms, Support) in an
/// in-app browser tab — Chrome Custom Tabs on Android, SFSafariViewController on
/// iOS — so the user stays inside the Help24 experience instead of being kicked
/// out to a separate browser app.
///
/// This is the single gateway for every legal/support link. That content lives
/// once, on help24.co.ke (see [AppUrls]); the app only points at it, so policies
/// and help articles can change without shipping an app update.
///
/// Offline is handled by the browser tab itself (it shows its own no-connection
/// page). Our SnackBar only appears if the launch genuinely fails — e.g. a
/// device with no browser at all, or a malformed URL — routed through
/// [ErrorMapper] for consistent, human copy.
Future<void> openHelp24Url(BuildContext context, String url) async {
  // Capture the messenger before any await so we never touch a stale context.
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.parse(url);

  try {
    if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return;
    // Rare: the in-app tab couldn't be shown. Fall back to the OS browser.
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    throw Exception('Unable to open $url');
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(ErrorMapper.toMessage(e, context: ErrorContext.generic)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.errorRed,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
