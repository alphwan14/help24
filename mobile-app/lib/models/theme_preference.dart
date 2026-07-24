import 'package:flutter/material.dart';

/// The user's theme choice: Device Default, Light or Dark.
///
/// Replaces the old boolean `isDarkMode`. A boolean cannot express "follow the
/// device", which is what a modern app defaults to — and what the OS-level
/// dark-mode schedule expects.
///
/// The enum wraps [ThemeMode] rather than replacing it so `MaterialApp` is fed
/// the framework's own type and every existing `Theme.of(context).brightness`
/// read across the app keeps working untouched.
enum ThemePreference {
  system('system', 'Device Default', 'Match your device settings', Icons.brightness_auto_rounded),
  light('light', 'Light', 'Always light', Icons.light_mode_rounded),
  dark('dark', 'Dark', 'Always dark', Icons.dark_mode_rounded);

  const ThemePreference(this.storageKey, this.label, this.description, this.icon);

  /// Persisted value. Stable — never rename; it is what is in SharedPreferences.
  final String storageKey;
  final String label;
  final String description;
  final IconData icon;

  ThemeMode get themeMode => switch (this) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      };

  /// Resolve to a concrete brightness. Needed for the system UI overlay style
  /// (status bar / navigation bar), which the framework does not derive from
  /// `themeMode` for us.
  bool isDark(Brightness platformBrightness) => switch (this) {
        ThemePreference.system => platformBrightness == Brightness.dark,
        ThemePreference.light => false,
        ThemePreference.dark => true,
      };

  static ThemePreference fromStorage(String? value) {
    for (final p in ThemePreference.values) {
      if (p.storageKey == value) return p;
    }
    return ThemePreference.system;
  }
}
