import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The one owner of the `com.help24.help24/links` channel.
///
/// MainActivity forwards verified help24.co.ke App Links — `/a/<CODE>` (an
/// agent's invitation) and `/p/<id>` (a provider's card) — and Flutter's own
/// route handling is off (`flutter_deeplinking_enabled=false`). A channel has
/// exactly one Dart handler, so the features that read links subscribe here
/// instead of each claiming the channel and silently unplugging the other.
///
/// Every subscriber sees every link and ignores the ones that are not its own.
/// The link that STARTED the app is read once and replayed to anyone who
/// subscribes later, because the subscribers start at different moments of
/// the launch and a cold-start link must reach all of them.
class AppLinks {
  AppLinks._();

  static const MethodChannel _channel = MethodChannel('com.help24.help24/links');

  static final List<Future<void> Function(String link)> _handlers = [];
  static Future<String?>? _initial;

  /// Deliver links to [handler]: the launch link (if any), then every link
  /// that arrives while the app runs.
  static Future<void> listen(Future<void> Function(String link) handler) async {
    _handlers.add(handler);
    final initial = await _start();
    if (initial != null) await handler(initial);
  }

  static Future<String?> _start() => _initial ??= () async {
        _channel.setMethodCallHandler((call) async {
          if (call.method != 'link' || call.arguments is! String) return;
          for (final handler in List.of(_handlers)) {
            await handler(call.arguments as String);
          }
        });
        try {
          return await _channel.invokeMethod<String>('initialLink');
        } catch (e) {
          debugPrint('[LINKS] initial link unavailable: ${e.runtimeType}');
          return null;
        }
      }();
}
