import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/user_profile_service.dart';

/// Holds the app locale, and refuses one the app cannot actually deliver.
///
/// ── THE COVERAGE PROBLEM ────────────────────────────────────────────────
/// `assets/l10n/{en,sw}.json` hold **39 keys**, and every one of the 14
/// `AppLocalizations.of(context)` call sites in the app is inside
/// `profile_screen.dart`. Nothing else reads them: not Discover, not the
/// composer, not the apply flow, not payments, not escrow, not the dispute
/// thread, not a single error message. Against roughly 27,700 lines of screen
/// code, that is the settings list and nothing more.
///
/// So switching to Kiswahili would translate the Settings labels and leave the
/// user in English for every screen where money changes hands. That is worse
/// than English-only, because it tells them the app is localised immediately
/// before the screens where being wrong is expensive.
///
/// ── WHAT THIS GATE IS FOR ───────────────────────────────────────────────
/// The picker already refused Kiswahili at the point of choice ("Coming soon",
/// with a lock). But `users.language` is a stored server value, and BOTH
/// [loadLanguageForUser] and [setLanguage] used to accept `'sw'` from it — so
/// any account carrying that value from an earlier build got the half-
/// translated Profile the picker was there to prevent. The picker guarded the
/// door; nothing guarded the window.
///
/// [_deliverable] is now the single answer to "may the app run in this
/// language", and it is enforced on the way IN from storage as well as on the
/// way out from the UI.
///
/// ── TO SHIP KISWAHILI ───────────────────────────────────────────────────
/// Translate the strings the app actually renders, not the 39 that exist; add
/// `'sw'` to [_deliverable]; and restore the Language row in Profile (removed
/// because a setting with one option is not a setting). The machinery below,
/// `AppLocalizations`, both JSON bundles and the Firestore/Supabase round trip
/// are all kept working precisely so that this is a small change when the
/// translation work is done.
class LocaleProvider extends ChangeNotifier {
  /// Languages the app can be used in END TO END. Not "languages a bundle
  /// exists for" — a bundle that covers the settings screen is not a language
  /// the product supports.
  static const Set<String> _deliverable = {'en'};

  static const Locale _fallback = Locale('en');

  /// Whether [code] is a language this build can actually be used in.
  static bool canDeliver(String? code) =>
      code != null && _deliverable.contains(code);

  /// True when there is a real choice to offer. While this is false, Profile
  /// shows no Language row at all — see the class doc.
  static bool get offersAChoice => _deliverable.length > 1;

  Locale _locale = _fallback;
  bool _isLoading = false;

  Locale get locale => _locale;
  bool get isLoading => _isLoading;
  String get languageCode => _locale.languageCode;

  /// Load the stored language for the current user and apply it IF the app can
  /// deliver it. A stored value this build cannot honour is ignored, not
  /// applied — see the class doc.
  Future<void> loadLanguageForUser() async {
    final uid = AuthService.currentUserId;
    if (uid == null) return;
    _isLoading = true;
    notifyListeners();
    try {
      final code = await UserProfileService.getLanguage(uid);
      _locale = canDeliver(code) ? Locale(code!) : _fallback;
    } catch (_) {
      _locale = _fallback;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Set the language and persist it. Rejects anything [canDeliver] refuses.
  ///
  /// The write is skipped too, not just the local change: persisting a language
  /// the app will then decline to honour is how the stored value and the
  /// rendered app came to disagree in the first place.
  Future<void> setLanguage(String languageCode) async {
    if (!canDeliver(languageCode)) {
      debugPrint('[LOCALE] refused "$languageCode" — not deliverable yet');
      return;
    }
    final uid = AuthService.currentUserId;
    _locale = Locale(languageCode);
    notifyListeners();
    if (uid != null) {
      try {
        await UserProfileService.setLanguage(uid, languageCode);
      } catch (_) {}
    }
  }

  /// Set locale without persisting (e.g. for a guest). Same gate.
  void setLocale(Locale locale) {
    if (!canDeliver(locale.languageCode)) return;
    if (locale.languageCode == _locale.languageCode) return;
    _locale = locale;
    notifyListeners();
  }
}
