import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A standalone filter chip — Discover's All / Requests / Offers and Jobs'
/// All / Full-time / Part-time / Contract / Remote.
///
/// ONE definition, deliberately. Both bars previously carried their own inline
/// copy of the same decoration, so restyling one silently left the other on the
/// old look. Anything that reads as "a filter chip" in this app should come
/// from here.
///
/// Each pill is INDEPENDENT: its own surface, its own boundary, real space
/// between it and its neighbours. It is not a segment of a shared track.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  /// Sharp capsule. At this height the ends round fully without the stadium
  /// look of a 999 radius, which is what keeps the edge reading as crisp.
  static const double _radius = 24;
  static const double _height = 42;
  static const EdgeInsets _padding = EdgeInsets.symmetric(horizontal: 18);
  static const Duration _transition = Duration(milliseconds: 200);

  /// Horizontal gap between adjacent pills. Exposed so both bars space them
  /// identically instead of each picking a number.
  static const double gap = 10;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Every unselected chip carries its OWN surface, one step lighter than the
    // page behind it, plus a slightly lighter hairline so the pill boundary is
    // definite rather than dissolving into the background.
    final inactiveBg =
        isDark ? const Color(0xFF242428) : const Color(0xFFEFF0F3);
    final inactiveBorder =
        isDark ? const Color(0xFF3A3A42) : const Color(0xFFDCDEE3);
    final inactiveText =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    // Derived from the text theme, not built from a bare TextStyle.
    // AnimatedDefaultTextStyle REPLACES the inherited style rather than merging
    // it, so a from-scratch TextStyle silently dropped Poppins and fell back to
    // the platform font — which is what made these labels look softer than the
    // rest of the screen.
    final baseStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: _transition,
          curve: Curves.easeInOut,
          height: _height,
          padding: _padding,
          decoration: BoxDecoration(
            color: isActive ? AppTheme.primaryAccent : inactiveBg,
            borderRadius: BorderRadius.circular(_radius),
            // The selected chip needs no outline — its fill already separates
            // it. No shadow either: a glow spreads the accent colour into the
            // background and blurs the edge.
            border:
                isActive ? null : Border.all(color: inactiveBorder, width: 1),
          ),
          alignment: Alignment.center,
          child: AnimatedDefaultTextStyle(
            duration: _transition,
            curve: Curves.easeInOut,
            style: baseStyle.copyWith(
              color: isActive ? Colors.white : inactiveText,
              fontSize: 14,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0.1,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
