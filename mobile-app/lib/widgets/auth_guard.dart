import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../screens/auth_screen.dart';
import '../utils/action_feedback.dart';
import '../utils/precise_route.dart';

/// Auth guard utility for protecting actions that require authentication
/// 
/// The app remains FULLY USABLE without login:
/// - Browse Discover ✓
/// - View posts ✓
/// - Search ✓
/// - Filter ✓
/// 
/// Auth required ONLY for:
/// - Post content
/// - Apply/respond to posts
/// - Send messages
/// - Edit profile
/// 
/// Usage:
/// ```dart
/// AuthGuard.requireAuth(
///   context,
///   action: 'post content',
///   onAuthenticated: () {
///     // User is authenticated, proceed with action
///     _createPost();
///   },
/// );
/// ```
class AuthGuard {
  /// Completes when no auth screen is on screen.
  ///
  /// WHY THIS IS PUBLIC
  /// ------------------
  /// Sign-in is not the only thing that reacts to a uid change. HomeScreen also
  /// opens a location-permission sheet the first time it sees a new account,
  /// and both were racing to use the same navigator at the same instant. The
  /// loser used to be the auth sheet: `Navigator.pop(context)` removes the
  /// navigator's TOPMOST route, so when the location sheet arrived first the
  /// pop dismissed *that* and left the auth screen stranded — the "sign-in
  /// worked but I have to press Back" report.
  ///
  /// The pop is now route-precise (see [_dismiss]), which fixes the collision
  /// on its own. This gate additionally stops the two sheets from ever
  /// overlapping, so the user sees one thing at a time. Callers that open a
  /// modal in response to an auth change should `await AuthGuard.settled`
  /// first.
  static Future<void> get settled => _presentation?.future ?? Future.value();

  static Completer<void>? _presentation;

  /// True while an auth screen is being presented.
  static bool get isPresenting => _presentation != null;

  /// Check if user is authenticated and either execute action or show auth screen
  ///
  /// [context] - BuildContext
  /// [action] - Description of the action (e.g., "post content", "send a message")
  /// [onAuthenticated] - Callback to execute when user is authenticated
  /// [showModal] - If true, shows auth as modal bottom sheet. If false, pushes full screen
  static Future<bool> requireAuth(
    BuildContext context, {
    required String action,
    required VoidCallback onAuthenticated,
    bool showModal = true,
  }) async {
    final authProvider = context.read<AuthProvider>();

    // Require real authentication; no guest mode for posting/messaging.
    if (!authProvider.isAuthAvailable) {
      // Developer detail stays in the log. The user gets a calm, actionable
      // sentence that says nothing about which service is unavailable or why —
      // "not configured" is a fact about our deployment, not about them.
      debugPrint('[AUTH][GUARD] identity backend unavailable — action blocked');
      // Routed through ActionFeedback so it clears itself. It previously
      // carried a "Dismiss" action, which — because Flutter defaults `persist`
      // to `action != null` — is precisely what made dismissing it necessary.
      ActionFeedback.info(
        context,
        "Signing in isn't available right now. Please try again shortly.",
      );
      return false;
    }

    // If already logged in, execute action immediately
    if (authProvider.isLoggedIn) {
      onAuthenticated();
      return true;
    }

    await present(context, action: action, showModal: showModal);

    // ── The action runs off AUTH STATE, never off a navigation result ────────
    //
    // This used to be `if (authenticated == true)`, i.e. it trusted the value
    // the sheet was popped with. That made the user's intent depend on HOW the
    // screen closed: a drag-dismiss, an Android back press, or a pop that
    // returned no value all discarded the action even though the user was, by
    // then, signed in. Asking the provider instead is both simpler and
    // impossible to get wrong — the only question that ever mattered is "are
    // they signed in now?".
    if (!context.mounted) return authProvider.isLoggedIn;
    if (authProvider.isLoggedIn) {
      onAuthenticated();
      return true;
    }
    return false;
  }

  /// Present the auth screen and return when it has been dismissed, however
  /// that happened. Does not decide anything — callers read [AuthProvider].
  ///
  /// Shared by every entry point (the guard, and the Profile tab's sign-in
  /// tiles) so there is exactly ONE auth presentation in the app. Two
  /// implementations is how one of them drifted and started depending on a
  /// result value again.
  static Future<void> present(
    BuildContext context, {
    String? action,
    bool showModal = true,
  }) async {
    final presentation = Completer<void>();
    _presentation = presentation;
    try {
      final override = debugPresentOverride;
      if (override != null) {
        await override(context, action, showModal);
        return;
      }
      // Dismissal targets THIS route, never "whatever is on top" — see
      // [presentDismissibleRoute] for why that distinction is the whole bug.
      await presentDismissibleRoute(
        context: context,
        asSheet: showModal,
        builder: (routeContext, dismiss) {
          if (!showModal) {
            return AuthScreen(action: action, onSuccess: dismiss);
          }
          return DraggableScrollableSheet(
            initialChildSize: 0.92,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (sheetContext, scrollController) => Container(
              decoration: BoxDecoration(
                color: Theme.of(sheetContext).scaffoldBackgroundColor,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: AuthScreen(
                action: action,
                isModal: true,
                onSuccess: dismiss,
              ),
            ),
          );
        },
      );
    } finally {
      _presentation = null;
      presentation.complete();
    }
  }

  /// Test seam: replaces the auth UI so the guard's DECISION can be exercised
  /// without a real identity backend. Production always uses the real path.
  @visibleForTesting
  static Future<void> Function(
    BuildContext context,
    String? action,
    bool showModal,
  )? debugPresentOverride;

  /// Check if user is authenticated without taking any action (real auth only; no guest)
  static bool isAuthenticated(BuildContext context) {
    return context.read<AuthProvider>().isLoggedIn;
  }
  
  /// Get the current user ID (or null if not authenticated)
  static String? getUserId(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    return authProvider.currentUserId;
  }
  
  /// Get current user name (empty if not authenticated)
  static String getUserName(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    return authProvider.currentUserName;
  }
}
