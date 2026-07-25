import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'error_mapper.dart';

/// Every user action ends in a visible outcome — success or a stated reason.
///
/// WHY THIS EXISTS
/// ---------------
/// "Sending an offer does absolutely nothing. No error. No loading. No success.
/// Nothing." The cause was not one missing snackbar; it was that no layer owned
/// the *end* of an action. A modal caught every exception with `catch (_)` on
/// the assumption that its caller had already spoken, and the caller only spoke
/// for one exception type. Both halves believed the other was reporting, so a
/// rejected write produced silence.
///
/// The rule this file encodes: the layer that STARTS an action owns its
/// outcome, and there is exactly one way to end. A `catch` that shows nothing
/// is a bug, not an optimisation.
class ActionFeedback {
  ActionFeedback._();

  /// Confirm that something happened.
  static void success(BuildContext context, String message) {
    if (!context.mounted) return;
    _show(
      context,
      message: message,
      icon: Icons.check_circle_rounded,
      background: AppTheme.successGreen,
    );
  }

  /// Report a failure in the user's language. [error] is the raw exception —
  /// it is mapped here and never shown verbatim.
  static void failure(
    BuildContext context,
    Object? error, {
    ErrorContext context_ = ErrorContext.generic,
    VoidCallback? onRetry,
  }) {
    if (!context.mounted) return;
    _show(
      context,
      message: ErrorMapper.toMessage(error, context: context_),
      icon: Icons.error_outline_rounded,
      background: AppTheme.errorRed,
      actionLabel: onRetry == null ? null : 'Retry',
      onAction: onRetry,
    );
  }

  /// State a rule or a neutral fact ("you already applied to this request").
  /// Not a failure — no alarming colour.
  ///
  /// [actionLabel] adds an optional way forward, for cases where the fact has
  /// one (e.g. "this listing is closed" → "View" it anyway).
  static void info(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!context.mounted) return;
    _show(
      context,
      message: message,
      icon: Icons.info_outline_rounded,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Run [action] and guarantee a terminal outcome.
  ///
  /// This is the safe default for any fire-and-forget call site — in
  /// particular a `Future`-returning function passed where a `VoidCallback` is
  /// expected, where an exception would otherwise become an unhandled async
  /// error and vanish. Returns true when the action completed.
  static Future<bool> run(
    BuildContext context,
    Future<void> Function() action, {
    String? successMessage,
    ErrorContext context_ = ErrorContext.generic,
  }) async {
    try {
      await action();
      if (!context.mounted) return true;
      if (successMessage != null) success(context, successMessage);
      return true;
    } catch (e) {
      if (!context.mounted) {
        // The screen is gone, so there is nobody to tell — but the failure must
        // still be recorded rather than disappearing.
        debugPrint('[FEEDBACK] action failed after unmount: $e');
        return false;
      }
      failure(context, e, context_: context_);
      return false;
    }
  }

  static void _show(
    BuildContext context, {
    required String message,
    required IconData icon,
    Color? background,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // No messenger means no way to speak. Say so in the log rather than
    // returning quietly — a silent action is the defect being fixed here.
    if (messenger == null) {
      debugPrint('[FEEDBACK] no ScaffoldMessenger for: $message');
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: background,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 4),
          // MUST be explicit. Flutter defaults `persist` to `action != null`
          // (SnackBar: `persist = persist ?? action != null`), so simply
          // offering a "View" or "Retry" button opts the notification into
          // staying on screen forever — the auto-hide timer checks `persist`
          // and returns without hiding. These are transient notifications, not
          // dismissible bars: the action is a shortcut while it is visible, not
          // a condition for it going away.
          persist: false,
          action: (actionLabel == null || onAction == null)
              ? null
              : SnackBarAction(
                  label: actionLabel,
                  textColor: Colors.white,
                  onPressed: onAction,
                ),
        ),
      );
  }
}
