import 'package:flutter/material.dart';

/// Present a route that can dismiss ITSELF, rather than "whatever is on top".
///
/// WHY THIS EXISTS
/// ---------------
/// `Navigator.pop(context)` does not close the route that owns `context` — it
/// closes the navigator's topmost route. Almost always those are the same
/// route, which is why the difference goes unnoticed until something else is
/// pushed at the wrong moment. In Help24 that something was the
/// location-permission sheet, opened by HomeScreen the instant a new uid
/// appeared: sign-in succeeded, the auth screen popped the location sheet
/// instead of itself, and the user was left staring at a login form they had
/// already completed, with no way out but the Back button.
///
/// A dismisser that names its own route cannot make that mistake:
///
///   * topmost      → `pop()`, so the exit animation is preserved.
///   * buried       → `removeRoute()`, which extracts exactly this route and
///                    leaves whatever is above it alone.
///   * already gone → no-op, so a duplicate dismissal is harmless.
///
/// The returned future completes when the route leaves the stack, however it
/// left — programmatic dismissal, a drag, or the system back gesture. Callers
/// should therefore decide what to do next from application state, never from
/// a pop result: "how the screen closed" and "what the user achieved" are
/// different questions, and only the second one matters.
Future<void> presentDismissibleRoute({
  required BuildContext context,
  required Widget Function(BuildContext context, VoidCallback dismiss) builder,
  bool asSheet = true,
  bool isScrollControlled = true,
  bool enableDrag = true,
  Color backgroundColor = Colors.transparent,
}) async {
  final navigator = Navigator.of(context);
  Route<void>? presented;

  void dismiss() {
    final route = presented;
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  if (asSheet) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: isScrollControlled,
      backgroundColor: backgroundColor,
      enableDrag: enableDrag,
      builder: (routeContext) {
        presented ??= ModalRoute.of(routeContext);
        return builder(routeContext, dismiss);
      },
    );
  } else {
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (routeContext) {
          presented ??= ModalRoute.of(routeContext);
          return builder(routeContext, dismiss);
        },
      ),
    );
  }
}
