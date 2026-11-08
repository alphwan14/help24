import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/plain_copy.dart';

/// NO EM DASHES IN THE INTERFACE (owner decision, 2026-11-08).
///
/// The app's own strings are written without them; server-written text is
/// cleaned by [plainCopy] as it is displayed. This file holds both halves:
/// a gate over every string literal in lib/, and the cleaner's behaviour.
void main() {
  group('no em dash in any string literal under lib/', () {
    // The two places that must NAME the character in order to remove it.
    const allowed = {
      'lib/utils/plain_copy.dart',
      'lib/utils/error_mapper.dart',
    };

    test('every string the app can show is written without one', () {
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final path = file.path.replaceAll(r'\', '/');
        if (allowed.contains(path)) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_dashInsideString(lines[i])) offenders.add('$path:${i + 1}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Help24 shows no em dashes. Use a full stop, a comma or a '
            'colon instead (log text can use a plain hyphen).\n'
            '${offenders.join('\n')}',
      );
    });
  });

  group('plainCopy, for server-written text', () {
    test('a dash between clauses becomes a sentence break', () {
      expect(plainCopy('Job completed — payment released'),
          'Job completed. Payment released');
    });

    test('works without spaces around the dash', () {
      expect(plainCopy('Offer accepted—pay to start'), 'Offer accepted. Pay to start');
    });

    test('a trailing dash is dropped', () {
      expect(plainCopy('Payment pending —'), 'Payment pending');
    });

    test('text without a dash comes back unchanged', () {
      const s = 'Your request has a new offer';
      expect(identical(plainCopy(s), s), isTrue);
    });
  });
}

/// True when [line] has an em dash inside a quoted string, ignoring
/// everything after a `//` that is outside quotes. Line by line is enough
/// for this codebase: no multi-line string literal in lib/ contains a dash.
bool _dashInsideString(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote == null) {
      if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') return false;
      if (ch == "'" || ch == '"') quote = ch;
    } else {
      if (ch == r'\') {
        i++; // skip the escaped character
      } else if (ch == quote) {
        quote = null;
      } else if (ch == '—') {
        return true;
      }
    }
  }
  return false;
}
