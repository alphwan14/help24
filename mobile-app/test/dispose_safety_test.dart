import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// DISPOSE() MUST NOT READ A PROVIDER OFF THE BUILDCONTEXT.
///
/// WHAT WENT WRONG
/// ---------------
/// `_ChatScreenState.dispose()` opened with:
///
///     context.read<AppProvider>().setActiveChatId(null);
///
/// `dispose()` is called from `StatefulElement.unmount()`, which has already
/// released the element's widget. Provider reaches `Element.widget` to find
/// the inherited scope, and that is a null check on a null value — not a debug
/// assert, but a real throw, in a release build, on every single close.
/// Captured on an SM-A217F (Android 12):
///
///     #0  Element.widget                (framework.dart:3653)
///     #1  Provider._inheritedElementOf  (provider.dart:377)
///     #2  Provider.of                   (provider.dart:327)
///     #3  ReadContext.read              (provider.dart:683)
///     #4  _ChatScreenState.dispose      (messages_screen.dart:959)
///     #5  StatefulElement.unmount       (framework.dart:6030)
///
/// Because the throw was on the SECOND line of dispose(), everything after it
/// was skipped: the realtime message subscription, the chats-row channel, six
/// timers, the JourneyEngine listener, the reconnect subscription, the pending
/// cache flush and both controllers. Opening and leaving five conversations
/// left FIVE live `watchMessages` channel pairs, each still running its own
/// exponential-backoff retry loop — verified by counting status lines while
/// toggling the radio with no chat on screen:
///
///     5 attempt 1   5 attempt 2   5 attempt 3   5 attempt 4
///
/// That is the whole "ChatScreen instances outlive their route" leak. The fix
/// is not a `mounted` check — `mounted` is still true here — it is to capture
/// the provider in `initState`, while the element is alive, and use the
/// reference. The same lesson was already learned once in this file's
/// `_markSeenNow`; this guard is so it does not have to be learned a third
/// time.
void main() {
  /// Every `.dart` under lib/, as (repo-relative path, source).
  List<MapEntry<String, String>> libSources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => MapEntry(
            f.path.replaceAll(r'\', '/'),
            f.readAsStringSync().replaceAll('\r\n', '\n'),
          ))
      .toList();

  /// Lines inside a `void dispose()` body, as "path:line: text".
  ///
  /// Deliberately crude — it scans from `void dispose()` to the first
  /// `\n  }`, which is the whole body for a State method and never spans into
  /// the next member. Comments are stripped so the explanatory note now
  /// sitting in that very method does not trip its own guard.
  List<String> disposeBodyLines() {
    final out = <String>[];
    for (final file in libSources()) {
      final lines = file.value.split('\n');
      var inside = false;
      for (var i = 0; i < lines.length; i++) {
        final raw = lines[i];
        if (raw.contains('void dispose()')) {
          inside = true;
          continue;
        }
        if (!inside) continue;
        if (raw == '  }') {
          inside = false;
          continue;
        }
        final comment = raw.indexOf('//');
        final code = comment == -1 ? raw : raw.substring(0, comment);
        if (code.trim().isEmpty) continue;
        out.add('${file.key}:${i + 1}: ${code.trim()}');
      }
    }
    return out;
  }

  test('no dispose() anywhere reads a provider off its BuildContext', () {
    final offenders = disposeBodyLines()
        .where((l) =>
            l.contains('context.read<') ||
            l.contains('context.watch<') ||
            l.contains('Provider.of('))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: 'the element is defunct by the time dispose() runs, so this '
          'throws in release and silently abandons every teardown below it. '
          'Capture the provider in initState and hold the reference instead',
    );
  });

  test('the scan actually finds dispose bodies — it is not vacuously green',
      () {
    final lines = disposeBodyLines();
    expect(lines.length, greaterThan(50),
        reason: 'this app has dozens of dispose() methods; a near-empty scan '
            'means the extraction broke and the guard above proves nothing');
    expect(
      lines.any((l) => l.contains('messages_screen.dart')),
      isTrue,
      reason: 'ChatScreen is the screen this guard exists for',
    );
  });

  test('ChatScreen holds the provider it needs at teardown', () {
    final src = File('lib/screens/messages_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(src.contains('late final AppProvider _appProvider;'), isTrue);
    expect(src.contains('_appProvider = context.read<AppProvider>();'), isTrue,
        reason: 'captured in initState, where the element is still active');
    expect(src.contains('_appProvider.setActiveChatId(null);'), isTrue,
        reason: 'and used through the reference at teardown');
  });

  test('the realtime subscription is still cancelled in dispose', () {
    // The leak was never a missing cancel — it was an unreachable one. If this
    // line ever disappears the channels leak again for a different reason.
    final src = File('lib/screens/messages_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    // Scope to _ChatScreenState — messages_screen.dart declares several
    // States, and the first dispose() in the file belongs to the LIST screen.
    final cls = src.indexOf('class _ChatScreenState');
    expect(cls, isNot(-1));
    final start = src.indexOf('void dispose()', cls);
    expect(start, isNot(-1));
    final end = src.indexOf('\n  }', start);
    final body = src.substring(start, end);
    expect(body.contains('_realtimeSubscription?.cancel();'), isTrue);
    expect(body.contains('_chatRowChannel?.unsubscribe();'), isTrue);
  });
}
