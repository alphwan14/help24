import 'package:flutter/widgets.dart';

/// Chrome that steps aside while someone is browsing.
///
/// Scrolling down through a feed hides the Post button and Discover's search
/// and scope row, so the list gets the whole screen. Scrolling back up, even a
/// little, brings them straight back, and so does reaching the top.
///
/// One notifier for the shell: [HomeScreen] feeds it every vertical scroll in
/// the tabs, and anything that should step aside listens to [visible].
class ScrollChrome {
  ScrollChrome._();

  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  /// Distance scrolled in one direction before the chrome reacts, so a nudge
  /// or a finger settling on the glass does not make it flicker.
  static const double _threshold = 32;

  /// Near the top the chrome always shows: there is nothing to make room for.
  static const double _topZone = 24;

  static double _run = 0;

  /// For a `NotificationListener<ScrollNotification>`. Never consumes the
  /// notification.
  static bool onNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is! ScrollUpdateNotification) return false;

    if (n.metrics.pixels <= n.metrics.minScrollExtent + _topZone) {
      show();
      return false;
    }

    final delta = n.scrollDelta ?? 0;
    if (delta == 0) return false;
    // A change of direction starts the count again.
    if ((delta > 0) != (_run > 0)) _run = 0;
    _run += delta;
    if (_run > _threshold) {
      _set(false);
    } else if (_run < -_threshold) {
      _set(true);
    }
    return false;
  }

  /// Bring the chrome back, e.g. when the reader changes tab.
  static void show() {
    _run = 0;
    _set(true);
  }

  static void _set(bool value) {
    if (visible.value != value) visible.value = value;
  }
}
