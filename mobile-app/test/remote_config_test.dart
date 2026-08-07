import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/remote_config.dart';

/// The property under test throughout: a client can never end up with a broken
/// configuration. Every failure mode — no config, partial config, wrong types,
/// corrupt JSON, a future server sending fields this build has never heard of —
/// must resolve to a complete document, and the switches must stay ENABLED.

void main() {
  group('RemoteConfig — the compiled floor', () {
    test('defaults are exactly today\'s shipped behaviour', () {
      const d = RemoteConfig.defaults;
      // These numbers are the ones that were compiled into the app before the
      // configuration plane existed. If one of them changes here, the app's
      // behaviour changed for every offline user — which is a decision, not a
      // refactor.
      expect(d.payments.pollIntervalSeconds, 5);
      expect(d.payments.pollBudget, 24);
      expect(d.listings.urgentWindowMinutes, 60);
      expect(d.maintenance.active, isFalse);
      expect(d.minVersion.soft, '');
      expect(d.minVersion.hard, '');
      expect(d.announcement.active, isFalse);
    });

    test('every kill switch defaults to ENABLED', () {
      // Fail-open is the whole safety argument: config trouble must never be
      // able to disable commerce.
      final switches = RemoteConfig.defaults.killSwitches;
      expect(switches.payments, isTrue);
      expect(switches.promotions, isTrue);
      expect(switches.posting, isTrue);
      expect(switches.applications, isTrue);
    });

    test('matches the backend contract byte for byte', () {
      // The golden pair. backend/src/app-config/client-config.ts holds the same
      // document as DEFAULT_CLIENT_CONFIG; this is the assertion that stops the
      // two drifting the way the platform-fee tables did.
      const backendDefaults = '''
{"ops":{"kill_switches":{"payments":true,"promotions":true,"posting":true,"applications":true},
"maintenance":{"active":false,"message":""},
"min_version":{"soft":"","hard":"","message":"","store_url":""},
"announcement":{"id":"","active":false,"message":"","url":""}},
"tuning":{"payments":{"poll_interval_seconds":5,"poll_budget":24},
"listings":{"urgent_window_minutes":60}}}
''';
      final expected = jsonDecode(backendDefaults) as Map<String, dynamic>;
      expect(RemoteConfig.defaults.toJson(), equals(expected));
    });
  });

  group('RemoteConfig — parsing', () {
    test('a null document yields the defaults', () {
      expect(RemoteConfig.fromJson(null).toJson(),
          equals(RemoteConfig.defaults.toJson()));
    });

    test('an empty document yields the defaults', () {
      expect(RemoteConfig.fromJson({}).toJson(),
          equals(RemoteConfig.defaults.toJson()));
    });

    test('applies a well-typed override', () {
      final config = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {'payments': false},
        },
      });
      expect(config.killSwitches.payments, isFalse);
      // Siblings keep their defaults — a partial document is legal.
      expect(config.killSwitches.posting, isTrue);
    });

    test('a wrong-typed value degrades exactly one field', () {
      final config = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {'payments': 'false', 'promotions': false},
        },
      });
      expect(config.killSwitches.payments, isTrue, reason: 'string rejected');
      expect(config.killSwitches.promotions, isFalse, reason: 'bool accepted');
    });

    test('a non-object section is ignored wholesale', () {
      final config = RemoteConfig.fromJson({
        'ops': 'maintenance mode',
        'tuning': [1, 2, 3],
      });
      expect(config.toJson(), equals(RemoteConfig.defaults.toJson()));
    });

    test('unknown fields from a future server are ignored, known ones applied', () {
      // Forward compatibility: an old APK must survive a newer backend.
      final config = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {'payments': false, 'time_travel': true},
          'a_section_this_build_has_never_heard_of': {'x': 1},
        },
      });
      expect(config.killSwitches.payments, isFalse);
      expect(config.toJson()['ops'], isNot(contains('time_travel')));
    });

    test('numeric tunables are clamped to workable bounds', () {
      final zeroed = RemoteConfig.fromJson({
        'tuning': {
          'payments': {'poll_interval_seconds': 0, 'poll_budget': 0},
        },
      });
      // A zero interval spins the timer; a zero budget expires the payment
      // instantly. Both are well-typed nonsense, so the type guard alone is not
      // enough protection.
      expect(zeroed.payments.pollIntervalSeconds, 2);
      expect(zeroed.payments.pollBudget, 6);

      final huge = RemoteConfig.fromJson({
        'tuning': {
          'payments': {'poll_interval_seconds': 99999, 'poll_budget': 99999},
          'listings': {'urgent_window_minutes': 99999},
        },
      });
      expect(huge.payments.pollIntervalSeconds, 60);
      expect(huge.payments.pollBudget, 120);
      expect(huge.listings.urgentWindowMinutes, 1440);
    });

    test('non-finite numbers fall back to the default', () {
      final config = RemoteConfig.fromJson({
        'tuning': {
          'payments': {'poll_budget': double.nan},
          'listings': {'urgent_window_minutes': double.infinity},
        },
      });
      expect(config.payments.pollBudget, 24);
      expect(config.listings.urgentWindowMinutes, 60);
    });

    test('survives a full round trip', () {
      final original = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {'payments': false, 'posting': false},
          'maintenance': {'active': true, 'message': 'Back at 18:00'},
          'min_version': {
            'soft': '1.2.0',
            'hard': '1.0.0',
            'message': 'Please update',
            'store_url': 'https://play.google.com/store/apps/details?id=x',
          },
          'announcement': {
            'id': 'launch-2026',
            'active': true,
            'message': 'M-Pesa payouts are faster now',
            'url': '',
          },
        },
        'tuning': {
          'payments': {'poll_interval_seconds': 4, 'poll_budget': 30},
          'listings': {'urgent_window_minutes': 120},
        },
      });
      final reparsed = RemoteConfig.fromJson(original.toJson());
      expect(reparsed.toJson(), equals(original.toJson()));
    });
  });

  group('Banner visibility rules', () {
    test('maintenance shows only when active AND it has something to say', () {
      expect(
        MaintenanceConfig.fromJson({'active': true, 'message': 'Back soon'})
            .shouldShow,
        isTrue,
      );
      expect(
        MaintenanceConfig.fromJson({'active': true, 'message': '   '}).shouldShow,
        isFalse,
      );
      expect(
        MaintenanceConfig.fromJson({'active': false, 'message': 'Back soon'})
            .shouldShow,
        isFalse,
      );
    });

    test('an announcement without an id never shows', () {
      // It could never be dismissed, so it would be permanent.
      expect(
        AnnouncementConfig.fromJson(
                {'id': '', 'active': true, 'message': 'Hello'})
            .shouldShow,
        isFalse,
      );
      expect(
        AnnouncementConfig.fromJson(
                {'id': 'a1', 'active': true, 'message': 'Hello'})
            .shouldShow,
        isTrue,
      );
    });
  });

  group('Version comparison', () {
    test('orders versions numerically, not lexically', () {
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.4'), lessThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('treats missing segments as zero', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('tolerates build and pre-release suffixes', () {
      // package_info_plus can report either shape; neither may read as "older".
      expect(compareVersions('1.2.3+45', '1.2.3'), 0);
      expect(compareVersions('1.2.3-rc1', '1.2.3'), 0);
    });

    test('a malformed version can never lock anyone out', () {
      expect(compareVersions('banana', '0.0.0'), 0);
      expect(isBelowVersion('banana', '1.0.0'), isTrue,
          reason: 'unparseable reads as 0.0.0, which IS below 1.0.0');
      expect(isBelowVersion('', '1.0.0'), isFalse,
          reason: 'an UNKNOWN version is never gated');
    });

    test('an empty minimum is no gate at all', () {
      // This is the state every install is in until someone sets a gate, so it
      // must be unambiguously permissive.
      expect(isBelowVersion('1.0.0', ''), isFalse);
      expect(isBelowVersion('0.0.1', '   '), isFalse);
    });

    test('the gate triggers only strictly below the minimum', () {
      expect(isBelowVersion('1.0.0', '1.0.0'), isFalse);
      expect(isBelowVersion('1.0.1', '1.0.0'), isFalse);
      expect(isBelowVersion('0.9.9', '1.0.0'), isTrue);
    });
  });

  group('Corruption and hostile input', () {
    test('deeply nested nonsense resolves to defaults without throwing', () {
      expect(
        () => RemoteConfig.fromJson({
          'ops': {
            'kill_switches': {
              'payments': {'nested': 'object'},
            },
            'min_version': {'hard': 42},
          },
          'tuning': {
            'payments': {'poll_budget': 'twenty-four'},
          },
        }),
        returnsNormally,
      );

      final config = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {
            'payments': {'nested': 'object'},
          },
          'min_version': {'hard': 42},
        },
        'tuning': {
          'payments': {'poll_budget': 'twenty-four'},
        },
      });
      expect(config.killSwitches.payments, isTrue);
      expect(config.minVersion.hard, '');
      expect(config.payments.pollBudget, 24);
    });

    test('a config that would disable everything is still honoured when explicit', () {
      // Fail-open protects against ABSENCE, not against a deliberate decision.
      // An operator who explicitly turns everything off must be obeyed.
      final config = RemoteConfig.fromJson({
        'ops': {
          'kill_switches': {
            'payments': false,
            'promotions': false,
            'posting': false,
            'applications': false,
          },
        },
      });
      expect(config.killSwitches.payments, isFalse);
      expect(config.killSwitches.promotions, isFalse);
      expect(config.killSwitches.posting, isFalse);
      expect(config.killSwitches.applications, isFalse);
    });
  });
}
