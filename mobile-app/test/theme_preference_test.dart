import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/theme_preference.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemePreference', () {
    test('maps to the framework ThemeMode', () {
      expect(ThemePreference.system.themeMode, ThemeMode.system);
      expect(ThemePreference.light.themeMode, ThemeMode.light);
      expect(ThemePreference.dark.themeMode, ThemeMode.dark);
    });

    test('Device Default resolves against the platform brightness', () {
      expect(ThemePreference.system.isDark(Brightness.dark), isTrue);
      expect(ThemePreference.system.isDark(Brightness.light), isFalse);
    });

    test('explicit choices ignore the platform brightness', () {
      expect(ThemePreference.dark.isDark(Brightness.light), isTrue);
      expect(ThemePreference.light.isDark(Brightness.dark), isFalse);
    });

    test('unknown/absent storage values fall back to Device Default', () {
      expect(ThemePreference.fromStorage(null), ThemePreference.system);
      expect(ThemePreference.fromStorage('sepia'), ThemePreference.system);
      expect(ThemePreference.fromStorage('dark'), ThemePreference.dark);
    });
  });

  group('AppProvider.loadThemePreference — legacy migration', () {
    test('fresh install → Device Default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(await AppProvider.loadThemePreference(prefs), ThemePreference.system);
    });

    test('legacy isDarkMode=true is preserved as an EXPLICIT Dark, not system',
        () async {
      SharedPreferences.setMockInitialValues({'isDarkMode': true});
      final prefs = await SharedPreferences.getInstance();
      expect(await AppProvider.loadThemePreference(prefs), ThemePreference.dark);
      // Migrated once and written through, so the legacy key is never read again.
      expect(prefs.getString(AppProvider.themePrefsKey), 'dark');
    });

    test('legacy isDarkMode=false is preserved as an EXPLICIT Light', () async {
      SharedPreferences.setMockInitialValues({'isDarkMode': false});
      final prefs = await SharedPreferences.getInstance();
      expect(await AppProvider.loadThemePreference(prefs), ThemePreference.light);
    });

    test('the new key wins over a stale legacy key', () async {
      SharedPreferences.setMockInitialValues({
        'isDarkMode': true,
        AppProvider.themePrefsKey: 'system',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await AppProvider.loadThemePreference(prefs), ThemePreference.system);
    });
  });
}
