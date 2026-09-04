import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// THE ONE OWNER OF THE ANDROID SYSTEM BARS.
///
/// WHY THIS EXISTS
/// ---------------
/// Flutter offers two ways to style the status and navigation bars, and they do
/// not compose:
///
///   * [SystemChrome.setSystemUIOverlayStyle] — imperative, applied once.
///   * [AnnotatedRegion] — declarative, re-applied on EVERY composite, which
///     means it overwrites any imperative call made while it is mounted.
///
/// The trap is what happens when an [AnnotatedRegion] UNMOUNTS. From
/// `RenderView._updateSystemChrome` (rendering/view.dart):
///
///     // If there are no overlay style in the UI don't bother updating.
///     if (upperOverlayStyle == null && lowerOverlayStyle == null) return;
///
/// Finding no annotation, Flutter pushes NOTHING and the last style stays on
/// the window. So the last screen to declare a style owns the bars for the rest
/// of the process — long after that screen is gone.
///
/// Help24 shipped exactly that. Measured on a Galaxy S20+ (Android 13, light
/// theme, 3-button navigation), reading the framebuffer directly:
///
///   * The launch splash declared brand-dark bars (#0A0A0A, light icons) and
///     then faded out. Nine seconds after `[LAUNCH] lifted` the bars were still
///     #0A0A0A on a #F8F9FA app, because nothing had replaced them.
///   * Once the signed-out screen had been shown, ITS style latched instead. It
///     used [SystemUiOverlayStyle.dark] — a Flutter constant that hard-codes
///     `systemNavigationBarColor: Color(0xFF000000)` and sets NO status bar
///     colour. The result was dark status icons over a dark bar: the clock
///     measured #030303 on #0A0A0A, a contrast ratio of 1.0:1, and the
///     navigation glyphs measured #E6E6E6 on the app's #FFFFFF bottom bar, a
///     ratio of 1.25:1. Time, battery, notifications and the back button were
///     all invisible — while Android Settings on the same device showed
///     #F6F6F6 bars and `LIGHT_STATUS_BARS LIGHT_NAVIGATION_BARS`.
///
/// The fix is OWNERSHIP, not colour. [SystemBars] wraps the whole app in one
/// root [AnnotatedRegion], so the correct style is re-asserted on every frame
/// and staleness is structurally impossible. Screens that genuinely need other
/// bars (the splash, the fullscreen image viewer) declare their own annotation
/// deeper in the tree: it wins while mounted and reverts BY ITSELF the moment
/// it goes, because the root is still there underneath. No handover call, no
/// ordering requirement, no flag to keep in sync.
///
/// EVERY FIELD IS SET EXPLICITLY, AND THAT IS LOAD-BEARING. A null field does
/// not mean "inherit"; the Android embedding skips null entries, so the value
/// falls through to whatever the window already had — which is
/// `android:statusBarColor` from `values/styles.xml`, the brand-dark splash
/// colour. A null `statusBarColor` is precisely how the invisible clock
/// happened, so this class never leaves one.
class SystemBars extends StatelessWidget {
  const SystemBars({super.key, required this.brightness, required this.child});

  /// The app's resolved brightness — not the platform's. Under "Device Default"
  /// these agree; under an explicit choice the app's wins, and the bars must
  /// follow the app the user is looking at.
  final Brightness brightness;

  final Widget child;

  /// Bars for the light theme: the scaffold field behind the status bar, the
  /// bottom-nav surface behind the navigation bar, dark icons on both.
  static const SystemUiOverlayStyle light = SystemUiOverlayStyle(
    statusBarColor: AppTheme.lightBackground,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: AppTheme.lightSurface,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  );

  /// Bars for the dark theme. Same construction, inverted.
  static const SystemUiOverlayStyle dark = SystemUiOverlayStyle(
    statusBarColor: AppTheme.darkBackground,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: AppTheme.darkSurface,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  /// The brand field the app launches on. Declared by [LaunchSplash] so the
  /// bars carry on from the Android launch theme with nothing flashing between
  /// them; it reverts to [light]/[dark] on its own when the splash unmounts.
  static const SystemUiOverlayStyle splash = SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0A0A0A),
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: Color(0xFF0A0A0A),
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  /// Fullscreen media on a black backdrop, where black bars are the design
  /// rather than an accident.
  static const SystemUiOverlayStyle immersive = SystemUiOverlayStyle(
    statusBarColor: Color(0xFF000000),
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: Color(0xFF000000),
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  static SystemUiOverlayStyle forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: forBrightness(brightness),
        child: child,
      );
}
