import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/remote_config.dart';
import 'package:help24/services/remote_config_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The scenarios this covers are the ones that happen during an incident —
/// which is exactly when the configuration plane has to work. Every one of them
/// must leave the app with a complete config and its switches ENABLED unless a
/// fetched document explicitly said otherwise.

const _serverConfig = {
  'ops': {
    'kill_switches': {
      'payments': false,
      'promotions': true,
      'posting': true,
      'applications': true,
    },
    'maintenance': {'active': true, 'message': 'Back at 18:00'},
    'min_version': {
      'soft': '2.0.0',
      'hard': '1.0.0',
      'message': 'Please update',
      'store_url': 'https://example.com/app',
    },
    'announcement': {
      'id': 'a1',
      'active': true,
      'message': 'Payouts are faster',
      'url': '',
    },
  },
  'tuning': {
    'payments': {'poll_interval_seconds': 4, 'poll_budget': 30},
    'listings': {'urgent_window_minutes': 120},
  },
};

String _body({String version = 'v1', Map<String, dynamic>? config}) =>
    jsonEncode({'version': version, 'config': config ?? _serverConfig});

/// Records every request so header behaviour can be asserted.
class _Recorder {
  final List<http.Request> requests = [];
  int get count => requests.length;
  http.Request get last => requests.last;
}

MockClient _client(
  _Recorder recorder,
  Future<http.Response> Function(http.Request request) handler,
) {
  return MockClient((request) async {
    recorder.requests.add(request);
    return handler(request);
  });
}

/// A server that always answers with [_serverConfig]. Every test that calls
/// `refresh()` must inject a transport — without one the service falls back to
/// the real authenticated client, which is not reachable from a test.
MockClient _okClient({String version = 'v1'}) =>
    MockClient((_) async => http.Response(_body(version: version), 200));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = RemoteConfigService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Help24',
      packageName: 'co.ke.help24',
      version: '1.5.0',
      buildNumber: '42',
      buildSignature: '',
    );
    service.resetForTest();
  });

  group('Cold start', () {
    test('a fresh install renders on compiled defaults, before any network', () async {
      final recorder = _Recorder();
      service.resetForTest(
        transport: _client(recorder, (_) async => http.Response(_body(), 200)),
      );

      await service.warmUp();

      // warmUp is disk-only: the launch transaction must never wait on a fetch.
      expect(recorder.count, 0, reason: 'warmUp must not touch the network');
      expect(service.paymentsEnabled, isTrue);
      expect(service.config.payments.pollBudget, 24);
      expect(service.appVersion, '1.5.0');
    });

    test('a warm start renders on the cached document', () async {
      SharedPreferences.setMockInitialValues({
        'help24_remote_config_v1': jsonEncode(_serverConfig),
        'help24_remote_config_at_v1': DateTime.now().millisecondsSinceEpoch,
        'help24_remote_config_version_v1': 'v1',
      });
      service.resetForTest();

      await service.warmUp();

      expect(service.paymentsEnabled, isFalse, reason: 'cached switch applies');
      expect(service.config.maintenance.message, 'Back at 18:00');
    });
  });

  group('Backend unavailable', () {
    test('offline keeps the current config and never throws', () async {
      SharedPreferences.setMockInitialValues({
        'help24_remote_config_v1': jsonEncode(_serverConfig),
        'help24_remote_config_at_v1': 0, // stale, so a refresh is attempted
      });
      service.resetForTest(
        transport: _client(_Recorder(), (_) async {
          throw const SocketExceptionStub();
        }),
      );
      await service.warmUp();

      await expectLater(service.refresh(), completes);
      expect(service.config.maintenance.message, 'Back at 18:00',
          reason: 'the cached document survives an offline refresh');
    });

    test('a 500 keeps the current config', () async {
      service.resetForTest(
        transport: _client(_Recorder(), (_) async => http.Response('boom', 500)),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.paymentsEnabled, isTrue);
      expect(service.config.payments.pollBudget, 24);
    });

    test('a 404 — an old backend with no /config route — keeps defaults', () async {
      // This is exactly the state during a staged rollout: a new APK talking to
      // a backend that has not deployed the config plane yet.
      service.resetForTest(
        transport:
            _client(_Recorder(), (_) async => http.Response('Not Found', 404)),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.config.toJson(), equals(RemoteConfig.defaults.toJson()));
    });

    test('a malformed body keeps the current config', () async {
      service.resetForTest(
        transport: _client(
            _Recorder(), (_) async => http.Response('<html>nope</html>', 200)),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.config.toJson(), equals(RemoteConfig.defaults.toJson()));
    });

    test('a partial response — no config key — keeps the current config', () async {
      service.resetForTest(
        transport: _client(_Recorder(),
            (_) async => http.Response(jsonEncode({'version': 'v9'}), 200)),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.config.toJson(), equals(RemoteConfig.defaults.toJson()));
      expect(service.cachedVersionForTest, isNull,
          reason: 'a body we could not use must not claim a version');
    });
  });

  group('Cache and ETag', () {
    test('applies a fetched document and remembers its version', () async {
      final recorder = _Recorder();
      service.resetForTest(
        transport: _client(
            recorder, (_) async => http.Response(_body(version: 'abc'), 200)),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.paymentsEnabled, isFalse);
      expect(service.config.payments.pollBudget, 30);
      expect(service.cachedVersionForTest, 'abc');
    });

    test('sends If-None-Match once a version is known', () async {
      final recorder = _Recorder();
      service.resetForTest(
        transport: _client(recorder, (request) async {
          if (request.headers.containsKey('If-None-Match')) {
            return http.Response('', 304);
          }
          return http.Response(_body(version: 'abc'), 200);
        }),
      );
      await service.warmUp();

      await service.refresh();
      expect(recorder.requests.first.headers.containsKey('If-None-Match'),
          isFalse);

      await service.refresh();
      expect(recorder.last.headers['If-None-Match'], '"abc"');
    });

    test('a 304 keeps the config and does not clear it', () async {
      final recorder = _Recorder();
      service.resetForTest(
        transport: _client(recorder, (request) async =>
            request.headers.containsKey('If-None-Match')
                ? http.Response('', 304)
                : http.Response(_body(version: 'abc'), 200)),
      );
      await service.warmUp();
      await service.refresh(); // 200
      await service.refresh(); // 304

      expect(service.paymentsEnabled, isFalse);
      expect(service.config.payments.pollBudget, 30);
    });

    test('refreshIfStale skips the network while the cache is fresh', () async {
      final recorder = _Recorder();
      service.resetForTest(
        transport: _client(
            recorder, (_) async => http.Response(_body(version: 'abc'), 200)),
      );
      await service.warmUp();

      await service.refresh(); // 1 request, stamps fetchedAt
      await service.refreshIfStale(); // fresh → no request
      await service.refreshIfStale();

      expect(recorder.count, 1,
          reason: 'resume must be free while the cache is fresh');
    });

    test('refreshIfStale fetches once the TTL has passed', () async {
      final recorder = _Recorder();
      SharedPreferences.setMockInitialValues({
        'help24_remote_config_v1': jsonEncode(_serverConfig),
        // Older than the 15-minute TTL.
        'help24_remote_config_at_v1': DateTime.now()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      service.resetForTest(
        transport: _client(
            recorder, (_) async => http.Response(_body(version: 'abc'), 200)),
      );
      await service.warmUp();
      await service.refreshIfStale();

      expect(recorder.count, 1);
    });

    test('a corrupt cache falls back to defaults without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'help24_remote_config_v1': '{ this is not json',
        'help24_remote_config_at_v1': DateTime.now().millisecondsSinceEpoch,
      });
      service.resetForTest();

      await expectLater(service.warmUp(), completes);
      expect(service.config.toJson(), equals(RemoteConfig.defaults.toJson()));
      expect(service.paymentsEnabled, isTrue);
    });
  });

  group('Version gates', () {
    test('a hard gate below the running version does not block', () async {
      service.resetForTest(appVersion: '1.5.0');
      await service.warmUp();
      await service.refresh();
      // server hard = 1.0.0, running 1.5.0 → not blocked
      expect(service.requiresHardUpdate, isFalse);
    });

    test('the hard gate reads the LAUNCH snapshot, not live config', () async {
      // A hard gate arriving mid-session must not close over whatever the user
      // is doing; it takes effect at the next cold start.
      service.resetForTest(
        appVersion: '1.5.0',
        transport: _client(
          _Recorder(),
          (_) async => http.Response(
            _body(config: {
              'ops': {
                'min_version': {'hard': '9.9.9'},
              },
            }),
            200,
          ),
        ),
      );
      await service.warmUp();
      await service.refresh();

      expect(service.config.minVersion.hard, '9.9.9',
          reason: 'live config has the new gate');
      expect(service.requiresHardUpdate, isFalse,
          reason: 'but the launch snapshot does not, so the session continues');
    });

    test('a soft gate suggests without blocking', () async {
      service.resetForTest(appVersion: '1.5.0', transport: _okClient());
      await service.warmUp();
      await service.refresh(); // soft = 2.0.0
      expect(service.suggestsUpdate, isTrue);
      expect(service.requiresHardUpdate, isFalse);
    });

    test('no config means no gate at all', () async {
      service.resetForTest(appVersion: '0.0.1');
      await service.warmUp();
      expect(service.requiresHardUpdate, isFalse);
      expect(service.suggestsUpdate, isFalse);
    });
  });

  group('Announcements', () {
    test('shows an active announcement, then remembers its dismissal', () async {
      service.resetForTest(transport: _okClient());
      await service.warmUp();
      await service.refresh();

      expect(service.visibleAnnouncement?.id, 'a1');

      await service.dismissAnnouncement('a1');
      expect(service.visibleAnnouncement, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('help24_remote_config_dismissed_announcement_v1'),
          'a1');
    });

    test('a dismissal survives a restart', () async {
      SharedPreferences.setMockInitialValues({
        'help24_remote_config_dismissed_announcement_v1': 'a1',
      });
      service.resetForTest(transport: _okClient());
      await service.warmUp();
      await service.refresh();

      expect(service.visibleAnnouncement, isNull);
    });
  });

  group('Notification', () {
    test('notifies listeners when a fetched config changes', () async {
      var notifications = 0;
      void listener() => notifications++;

      service.resetForTest(transport: _okClient());
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.warmUp(); // notifies once, on load
      await service.refresh(); // notifies again, on apply

      expect(notifications, greaterThanOrEqualTo(2));
    });
  });
}

/// Stand-in for a socket failure without importing dart:io into a test that
/// otherwise needs none.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: no route to host';
}
