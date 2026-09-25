import 'package:flutter/material.dart';

import '../theme/tokens.dart';

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
///
/// ── Selection is the brand moment ───────────────────────────────────────
/// The selected pill is the one place on Discover where the accent is spent,
/// and it is spent properly: brand gold `#E8A33D` with ink on top, 8.43:1.
/// It used to be an accent fill under WHITE text, which measured 4.53:1 with
/// indigo and would have measured 2.16:1 the moment the accent became gold —
/// the label colour was the thing that had to change, not the accent.
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
  static const double _radius = 22;
  static const double _height = 40;
  static const EdgeInsets _padding = EdgeInsets.symmetric(horizontal: 16);

  /// Horizontal gap between adjacent pills. Exposed so both bars space them
  /// identically instead of each picking a number.
  static const double gap = AppSpace.sm;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.state,
          curve: AppMotion.enter,
          height: _height,
          padding: _padding,
          decoration: BoxDecoration(
            color: isActive ? c.accentFill : c.surfaceSunken,
            borderRadius: BorderRadius.circular(_radius),
            // The selected chip needs no outline — its fill already separates
            // it. No shadow either: a glow spreads the accent colour into the
            // background and blurs the edge.
            border: isActive ? null : Border.all(color: c.borderHairline),
          ),
          alignment: Alignment.center,
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.state,
            curve: AppMotion.enter,
            // Built from the role, not from a bare TextStyle:
            // AnimatedDefaultTextStyle REPLACES the inherited style rather than
            // merging it, so a from-scratch TextStyle silently dropped the app
            // font and fell back to the platform one — which is what made these
            // labels look softer than the rest of the screen.
            style: AppTypeScale.label.copyWith(
              fontFamily: AppTypeScale.family,
              fontSize: 14,
              color: isActive ? c.contentOnAccent : c.contentSecondary,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
