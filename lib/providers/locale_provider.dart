import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/user_profile_service.dart';

/// Holds app locale (en / sw). Syncs with Firestore users/{uid}.language when user is logged in.
/// When locale changes, notifyListeners so MaterialApp rebuilds with new locale.
class LocaleProvider extends ChangeNotifier {
  Locale _locale = const Locale('en');
  bool _isLoading = false;

  Locale get locale => _locale;
  bool get isLoading => _isLoading;
  String get languageCode => _locale.languageCode;

  /// Load language from Firestore for current user and apply.
  Future<void> loadLanguageForUser() async {
    final uid = AuthService.currentUserId;
    if (uid == null) return;
    _isLoading = true;
    notifyListeners();
    try {
      final code = await UserProfileService.getLanguage(uid);
      _locale = code == 'sw' ? const Locale('sw') : const Locale('en');
    } catch (_) {
      _locale = const Locale('en');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Set language and persist to Firestore. Call after login or from profile settings.
  Future<void> setLanguage(String languageCode) async {
    if (languageCode != 'en' && languageCode != 'sw') return;
    final uid = AuthService.currentUserId;
    _locale = languageCode == 'sw' ? const Locale('sw') : const Locale('en');
    notifyListeners();
    if (uid != null) {
      try {
        await UserProfileService.setLanguage(uid, languageCode);
      } catch (_) {}
    }
  }

  /// Set locale without persisting (e.g. for guest).
  void setLocale(Locale locale) {
    if (locale.languageCode == _locale.languageCode) return;
    _locale = locale;
    notifyListeners();
  }
}
