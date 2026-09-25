import 'package:flutter/material.dart';
import '../theme/app_icons.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../theme/tokens.dart';

/// The bottom navigation bar.
///
/// ── What changed, and why ───────────────────────────────────────────────
/// This bar used to carry the accent four times over: a tinted pill behind the
/// active glyph, an accent-coloured icon, an accent-coloured label, and a
/// gradient-plus-glow centre button. It was the loudest chrome in the app, on
/// every screen.
///
/// Now the active tab is marked ONCE — full-contrast content plus a short
/// amber rule under the label. Everything else recedes. That is Deference:
/// the bar says where you are and then gets out of the way.
///
/// The centre button lost its gradient and its coloured shadow. It was the
/// app's only gradient and its only glow, which is precisely what made it read
/// as decoration; a solid ink square reads as an action. (The gradient also
/// had a latent bug: it was built as `[accent, accent.withBlue(255)]`, so the
/// moment the accent stopped being indigo the ramp ran from gold to violet.)
///
/// ── Four tabs, not five slots ───────────────────────────────────────────
/// The centre slot was never a destination: it set a boolean that swapped the
/// body and hid the bar, which is why `HomeScreen` carried index arithmetic to
/// translate "nav slot" into "tab". Post is a FAB now, owned by the shell, and
/// this bar holds only places you can BE.
///
/// The fourth tab is Activity. It replaced Jobs, which was a filter over the
/// corpus Discover already serves and is now a scope pill in Discover's row.
class CustomBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;

  const CustomBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  /// Content height, excluding the system inset. Was 70 + 12 top padding.
  static const double _height = 60;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        // navSurface, not surface: this has to equal what Android paints the
        // system navigation bar, or a seam appears along the bottom edge.
        color: c.navSurface,
        // A border OR a shadow, never both. The bar sits in the page plane,
        // so it takes the border.
        border: Border(top: BorderSide(color: c.borderHairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: AppSpace.md,
            right: AppSpace.md,
            top: AppSpace.sm,
            bottom: bottomPadding > 0 ? 0 : AppSpace.sm,
          ),
          child: SizedBox(
            height: _height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _NavItem(
                  icon: AppIcons.discover,
                  activeIcon: AppIcons.discoverActive,
                  label: 'Discover',
                  isActive: currentIndex == 0,
                  onTap: () => onTap(0),
                ),
                _NavItem(
                  icon: AppIcons.activity,
                  activeIcon: AppIcons.activityActive,
                  label: 'Activity',
                  isActive: currentIndex == 1,
                  onTap: () => onTap(1),
                ),
                Consumer<AppProvider>(
                  builder: (_, appProvider, __) => _NavItem(
                    icon: AppIcons.messages,
                    activeIcon: AppIcons.messagesActive,
                    label: 'Messages',
                    isActive: currentIndex == 2,
                    badgeCount: appProvider.totalUnreadCount,
                    onTap: () => onTap(2),
                  ),
                ),
                _NavItem(
                  icon: AppIcons.profile,
                  activeIcon: AppIcons.profileActive,
                  label: 'Profile',
                  isActive: currentIndex == 3,
                  onTap: () => onTap(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final int badgeCount;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = isActive ? c.contentPrimary : c.contentTertiary;

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        // 64 × 60 — comfortably past the 48 dp minimum target.
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    isActive ? activeIcon : icon,
                    size: AppIconSize.lg,
                    color: color,
                  ),
                  if (badgeCount > 0)
                    Positioned(
                      top: -4,
                      right: -8,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          // Unread is a red count everywhere people already
                          // know. It is not a brand moment.
                          color: c.criticalFill,
                          borderRadius: AppRadius.smAll,
                          border: Border.all(color: c.navSurface, width: 1.5),
                        ),
                        child: Text(
                          badgeCount > 99 ? '99+' : badgeCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                label,
                style: AppTypeScale.meta.copyWith(
                  fontFamily: AppTypeScale.family,
                  color: color,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 3),
              // The single mark. Brand gold, 2 px, and it is the ONLY place
              // the accent appears in the app's chrome.
              AnimatedContainer(
                duration: AppMotion.state,
                curve: AppMotion.enter,
                height: 2,
                width: isActive ? 18 : 0,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: AppRadius.pillAll,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _CenterButton removed. Post is not a destination, so it is not a tab: the
// shell owns it as a FAB. See HomeScreen.
