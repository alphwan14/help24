import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/remote_config.dart';
import 'package:help24/services/app_updater.dart';
import 'package:help24/services/remote_config_service.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/widgets/ops_banners.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// THE IN-APP UPDATER (sideloaded builds, app 1.0.13+).
///
/// The rules held here: an update is offered in-app only when the config
/// carries the APK, its SHA-256 and its size, otherwise Update opens the
/// download page as before; nothing is installed unless the file hashes to the
/// published value (a mismatch is deleted); the install permission is asked
/// for once and the flow carries on when the member comes back; a broken or
/// cancelled download resumes where it stopped.

class _FakeInstaller implements UpdateInstaller {
  bool allowed = true;
  bool opens = true;
  final List<String> installed = [];
  int settingsOpened = 0;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<bool> openInstallSettings() async {
    settingsOpened++;
    return true;
  }

  @override
  Future<bool> install(String path) async {
    installed.add(path);
    return opens;
  }
}

Uint8List _bytes(int n, {int seed = 1}) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

String _sha(List<int> b) => sha256.convert(b).toString();

UpdateTarget _target(List<int> published, {String? sha}) => UpdateTarget(
      url: 'https://github.com/alphwan14/help24/releases/download/v1.0.13/app-release.apk',
      sha256: sha ?? _sha(published),
      sizeBytes: published.length,
    );

/// Serves [file] like GitHub does: 200 for the whole thing, 206 for a Range.
MockClient _server(List<int> file, {List<String>? ranges, bool honourRange = true, int? breakAfter}) {
  return MockClient.streaming((request, _) async {
    final range = request.headers['Range'];
    ranges?.add(range ?? '');
    var start = 0;
    var status = 200;
    if (range != null && honourRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      status = 206;
    }
    final body = file.sublist(start);
    Stream<List<int>> stream() async* {
      const chunk = 512;
      var sent = 0;
      for (var i = 0; i < body.length; i += chunk) {
        if (breakAfter != null && sent >= breakAfter) throw const SocketException('connection reset');
        final piece = body.sublist(i, min(i + chunk, body.length));
        sent += piece.length;
        yield piece;
      }
    }

    return http.StreamedResponse(stream(), status, contentLength: body.length);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('h24_updates_'));
  tearDown(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  AppUpdater updater(http.Client client, _FakeInstaller installer) =>
      AppUpdater(client: client, installer: installer, cacheDir: () async => cache, onWifi: () async => true);

  group('versions', () {
    test('compare segment by segment, ignoring build numbers', () {
      expect(isBelowVersion('1.0.12', '1.0.13'), isTrue);
      expect(isBelowVersion('1.0.13', '1.0.13'), isFalse);
      expect(isBelowVersion('1.0.13+14', '1.0.13'), isFalse);
      expect(isBelowVersion('1.0.9', '1.0.13'), isTrue, reason: 'numeric, not text: 9 < 13');
      expect(isBelowVersion('1.0.14', '1.0.13'), isFalse);
      expect(isBelowVersion('1.0.12', ''), isFalse, reason: 'no gate');
    });
  });

  group('when the update is offered in the app', () {
    const sha = 'eae851787e4ddd249294f1cdbd1d738b598fd0d64eb8a0fac1740ae4fc1cdf9f';
    MinVersionConfig cfg({String url = 'https://github.com/alphwan14/help24/releases/download/v1.0.13/app-release.apk', String s = sha, int size = 84986212}) =>
        MinVersionConfig(soft: '1.0.13', hard: '', message: '', storeUrl: 'https://help24.co.ke/download', apkUrl: url, sha256: s, sizeBytes: size);

    test('only with all three fields, on Android, in a sideloaded build', () {
      expect(UpdateTarget.fromConfig(cfg(), android: true, enabled: true), isNotNull);
      expect(UpdateTarget.fromConfig(cfg(url: '', s: '', size: 0), android: true, enabled: true), isNull,
          reason: 'empty fields fall back to the download page');
      expect(UpdateTarget.fromConfig(cfg(s: ''), android: true, enabled: true), isNull, reason: 'never unverified');
      expect(UpdateTarget.fromConfig(cfg(size: 0), android: true, enabled: true), isNull);
      expect(UpdateTarget.fromConfig(cfg(url: 'http://example.com/a.apk'), android: true, enabled: true), isNull);
      expect(UpdateTarget.fromConfig(cfg(), android: false, enabled: true), isNull);
      expect(UpdateTarget.fromConfig(cfg(), android: true, enabled: false), isNull, reason: 'a Play build');
    });

    test('the button shows the size first, in decimal megabytes like Android', () {
      expect(formatUpdateSize(84986212), '85 MB');
      expect(formatUpdateSize(3400000), '3.4 MB');
    });

    test('the config carries the fields from /config and back', () {
      final m = MinVersionConfig.fromJson({'soft': '1.0.13', 'apk_url': 'https://x', 'sha256': sha, 'size_bytes': 84986212});
      expect(m.sizeBytes, 84986212);
      expect(m.toJson()['sha256'], sha);
      expect(MinVersionConfig.fromJson({'soft': '1.0.13'}).hasInAppDownload, isFalse);
    });
  });

  group('download, verify, install', () {
    test('a file that matches is installed', () async {
      final apk = _bytes(5000);
      final installer = _FakeInstaller();
      final u = updater(_server(apk), installer);
      await u.start(_target(apk));
      expect(u.phase, UpdatePhase.readyToInstall);
      expect(installer.installed, hasLength(1));
      expect(installer.installed.single, endsWith('.apk'));
      expect(File(installer.installed.single).readAsBytesSync(), apk);
    });

    test('a file that does not match is deleted and never installed', () async {
      final apk = _bytes(5000);
      final installer = _FakeInstaller();
      final u = updater(_server(apk), installer);
      final t = _target(apk, sha: _sha(_bytes(5000, seed: 2)));
      await u.start(t);
      expect(u.phase, UpdatePhase.failed);
      expect(u.failure, UpdateFailure.checksum);
      expect(installer.installed, isEmpty);
      expect(File(await u.filePathFor(t)).existsSync(), isFalse);
      expect(File(await u.partPathFor(t)).existsSync(), isFalse);
    });

    test('without the install permission it asks once, then carries on when the member comes back', () async {
      final apk = _bytes(3000);
      final installer = _FakeInstaller()..allowed = false;
      final u = updater(_server(apk), installer);
      await u.start(_target(apk));
      expect(u.phase, UpdatePhase.needsPermission);
      expect(installer.installed, isEmpty);

      await u.openInstallSettings();
      expect(installer.settingsOpened, 1);
      // Back without allowing it: still waiting, nothing installed.
      await u.resumeAfterSettings();
      expect(u.phase, UpdatePhase.needsPermission);

      installer.allowed = true;
      await u.resumeAfterSettings();
      expect(u.phase, UpdatePhase.readyToInstall);
      expect(installer.installed, hasLength(1));
    });

    test('backing out of the install prompt offers it again', () async {
      final apk = _bytes(3000);
      final installer = _FakeInstaller();
      final u = updater(_server(apk), installer);
      await u.start(_target(apk));
      await u.installAgain();
      expect(installer.installed, hasLength(2));
    });

    test('a broken download keeps what it has and resumes with a Range request', () async {
      final apk = _bytes(6000);
      final ranges = <String>[];
      final installer = _FakeInstaller();
      final t = _target(apk);

      final first = updater(_server(apk, ranges: ranges, breakAfter: 2048), installer);
      await first.start(t);
      expect(first.phase, UpdatePhase.failed);
      expect(first.failure, UpdateFailure.network);
      final kept = File(await first.partPathFor(t)).lengthSync();
      expect(kept, greaterThan(0));

      final second = updater(_server(apk, ranges: ranges), installer);
      await second.start(t);
      expect(ranges.last, 'bytes=$kept-');
      expect(second.phase, UpdatePhase.readyToInstall);
      expect(File(installer.installed.single).readAsBytesSync(), apk);
    });

    test('a server that ignores Range sends the whole file again, and it still verifies', () async {
      final apk = _bytes(4000);
      final installer = _FakeInstaller();
      final t = _target(apk);
      final first = updater(_server(apk, breakAfter: 1024), installer);
      await first.start(t);
      final second = updater(_server(apk, honourRange: false), installer);
      await second.start(t);
      expect(second.phase, UpdatePhase.readyToInstall);
      expect(File(installer.installed.single).readAsBytesSync(), apk);
    });

    test('cancel stops the download and keeps the partial file for later', () async {
      final apk = _bytes(4096);
      final controller = StreamController<List<int>>();
      final client = MockClient.streaming((request, _) async =>
          http.StreamedResponse(controller.stream, 200, contentLength: apk.length));
      final installer = _FakeInstaller();
      final u = updater(client, installer);
      final t = _target(apk);
      final run = u.start(t);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.add(apk.sublist(0, 1000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(u.phase, UpdatePhase.downloading);
      await u.cancel();
      await run;
      expect(u.phase, UpdatePhase.idle);
      expect(installer.installed, isEmpty);
      expect(File(await u.partPathFor(t)).lengthSync(), 1000);
      await controller.close();
    });

    test('files of other releases are cleaned up', () async {
      final old = File('${cache.path}/updates/help24-000000000000.apk')..createSync(recursive: true);
      final apk = _bytes(2000);
      final u = updater(_server(apk), _FakeInstaller());
      await u.start(_target(apk));
      expect(old.existsSync(), isFalse);
      await u.cleanup();
      expect(Directory('${cache.path}/updates').listSync(), isEmpty);
    });
  });

  group('the update banner', () {
    tearDown(() {
      updateTargetFor = UpdateTarget.fromConfig;
      RemoteConfigService.instance.resetForTest();
    });

    Future<void> pumpBanner(WidgetTester tester, MinVersionConfig m) async {
      RemoteConfigService.instance.resetForTest(
        config: RemoteConfig.defaults.copyWith(minVersion: m),
        appVersion: '1.0.12',
      );
      await tester.pumpWidget(MaterialApp(theme: AppTheme.lightTheme, home: const Scaffold(body: OpsBanners())));
    }

    testWidgets('with no download fields, Update opens the page as before', (tester) async {
      updateTargetFor = (m) => UpdateTarget.fromConfig(m, android: true, enabled: true);
      await pumpBanner(
          tester, const MinVersionConfig(soft: '1.0.13', hard: '', message: '', storeUrl: 'https://help24.co.ke/download'));
      expect(find.text('Update'), findsOneWidget);
      expect(find.textContaining('MB'), findsNothing);
    });

    testWidgets('with them, the button names the size and opens the update', (tester) async {
      updateTargetFor = (m) => UpdateTarget.fromConfig(m, android: true, enabled: true);
      await pumpBanner(
        tester,
        const MinVersionConfig(
          soft: '1.0.13',
          hard: '',
          message: '',
          storeUrl: 'https://help24.co.ke/download',
          apkUrl: 'https://github.com/alphwan14/help24/releases/download/v1.0.13/app-release.apk',
          sha256: 'eae851787e4ddd249294f1cdbd1d738b598fd0d64eb8a0fac1740ae4fc1cdf9f',
          sizeBytes: 84986212,
        ),
      );
      expect(find.text('Update, 85 MB'), findsOneWidget);
      await tester.tap(find.text('Update, 85 MB'));
      await tester.pumpAndSettle();
      expect(find.text('Update Help24'), findsOneWidget);
      // The panel's own button, before anything is downloaded.
      expect(find.widgetWithText(FilledButton, 'Update, 85 MB'), findsOneWidget);
    });
  });
}
