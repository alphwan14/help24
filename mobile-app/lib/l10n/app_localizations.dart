import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/locale_provider.dart';

/// App translations. Use AppLocalizations.of(context).t('key').
/// Strings are provided by [AppLocalizationsScope] (driven by [LocaleProvider]),
/// so language can switch to sw without changing MaterialApp locale (avoids
/// "sw not supported by MaterialLocalizations").
class AppLocalizations {
  final Map<String, String> _strings;

  AppLocalizations(this._strings);

  String translate(String key) => _strings[key] ?? key;
  String t(String key) => translate(key);

  /// Prefer scope (from AppLocalizationsLoader); fallback to delegate if scope not found.
  static AppLocalizations? of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppLocalizationsScope>();
    if (scope != null) return scope.localizations;
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }
}

/// Provides app strings for the current [LocaleProvider.languageCode] (en/sw).
/// Keeps MaterialApp locale as 'en' so framework never sees unsupported 'sw'.
class AppLocalizationsScope extends InheritedWidget {
  final AppLocalizations localizations;

  const AppLocalizationsScope({
    super.key,
    required this.localizations,
    required super.child,
  });

  @override
  bool updateShouldNotify(AppLocalizationsScope old) =>
      old.localizations != localizations;
}

/// Loads assets/l10n/{en|sw}.json from [LocaleProvider] and provides [AppLocalizationsScope].
/// Place above MaterialApp so locale switches work without setting MaterialApp.locale to 'sw'.
class AppLocalizationsLoader extends StatefulWidget {
  final Widget child;

  const AppLocalizationsLoader({super.key, required this.child});

  @override
  State<AppLocalizationsLoader> createState() => _AppLocalizationsLoaderState();
}

class _AppLocalizationsLoaderState extends State<AppLocalizationsLoader> {
  Map<String, String> _strings = {};
  String _loadedCode = 'en';

  Future<void> _load(String code) async {
    if (code != 'en' && code != 'sw') return;
    if (_loadedCode == code && _strings.isNotEmpty) return;
    try {
      final jsonString = await rootBundle.loadString('assets/l10n/$code.json');
      final map = json.decode(jsonString) as Map<String, dynamic>;
      final strings = map.map((k, v) => MapEntry(k, v.toString()));
      if (mounted) {
        setState(() {
          _strings = strings;
          _loadedCode = code;
        });
      }
    } catch (_) {
      if (mounted && _strings.isEmpty) {
        setState(() => _strings = {'': ''});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = context.watch<LocaleProvider>().languageCode;
    if (_loadedCode != code || _strings.isEmpty) {
      _load(code);
    }
    return AppLocalizationsScope(
      localizations: AppLocalizations(_strings),
      child: widget.child,
    );
  }
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final jsonString = await rootBundle.loadString('assets/l10n/en.json');
    final map = json.decode(jsonString) as Map<String, dynamic>;
    final strings = map.map((k, v) => MapEntry(k, v.toString()));
    return AppLocalizations(strings);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

const LocalizationsDelegate<AppLocalizations> appLocalizationsDelegate =
    _AppLocalizationsDelegate();
