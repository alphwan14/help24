import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/agent_code_service.dart';

void main() {
  group('agent codes', () {
    test('every way people type a code means the same code', () {
      for (final typed in ['H24-7K3Q', 'h24 7k3q', 'h247k3q', '7K3Q', ' 7k3q ', 'H24_7K3Q']) {
        expect(AgentCodeService.normalize(typed), 'H24-7K3Q', reason: typed);
      }
    });

    test('codes never contain the look-alike characters, and are 4-6 long', () {
      expect(AgentCodeService.normalize('H24-7K0Q'), isNull); // 0
      expect(AgentCodeService.normalize('H24-7KIQ'), isNull); // I
      expect(AgentCodeService.normalize('H24-7K3'), isNull);
      expect(AgentCodeService.normalize('H24-7K3QABC'), isNull);
      expect(AgentCodeService.normalize(''), isNull);
    });

    test('an agent link carries the code and says whether it was scanned', () {
      final link = AgentCodeService.parseLink('https://help24.co.ke/a/H24-7K3Q');
      expect(link?.code, 'H24-7K3Q');
      expect(link?.method, AgentCodeMethod.link);
      final qr = AgentCodeService.parseLink('https://help24.co.ke/a/h24-7k3q?src=qr');
      expect(qr?.code, 'H24-7K3Q');
      expect(qr?.method, AgentCodeMethod.qr);
    });

    test('anything else is not an agent link', () {
      for (final other in [
        'https://help24.co.ke/download',
        'https://help24.co.ke/a/',
        'https://help24.co.ke/a/H24-7K3Q/extra',
        'http://help24.co.ke/a/H24-7K3Q',
        'https://evil.example/a/H24-7K3Q',
        'https://help24.co.ke.evil.example/a/H24-7K3Q',
        'not a link',
      ]) {
        expect(AgentCodeService.parseLink(other), isNull, reason: other);
      }
    });

    test("the server's words are shown; anything else is generic", () {
      expect(
        AgentCodeService.messageFor('22023',
            "HELP24_AGENT_WINDOW_CLOSED: agent codes can only be added in your first 3 days on Help24"),
        'Agent codes can only be added in your first 3 days on Help24.',
      );
      expect(AgentCodeService.messageFor('PGRST202', 'Could not find the function'), contains("aren't available yet"));
      final generic = AgentCodeService.messageFor('08006', 'connection reset by peer at 10.0.0.1');
      expect(generic, isNot(contains('10.0.0.1')));
    });
  });
}
