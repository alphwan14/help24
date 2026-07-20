import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/providers/connectivity_provider.dart';

/// The expired-data-bundle case, reproduced deterministically.
///
/// This is the production bug these tests exist to prevent regressing: on
/// mobile data with an exhausted bundle the radio stays up and Android keeps
/// reporting a `mobile` connection, so interface-only detection concludes
/// "online", the app fires requests that never complete, and it shows skeleton
/// loaders forever instead of the cached content already on disk.
///
/// Port 9 (discard) on localhost refuses immediately, which is exactly the
/// shape of the real failure — a reachable-looking network that carries
/// nothing — without depending on the machine's actual connectivity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test installs an HttpOverrides that answers 400 to EVERY request,
  // so without this the probe always sees a response and concludes the network
  // is fine — the test would be measuring the harness, not the code. Clearing
  // it lets the refused connection below be a real refused connection.
  setUp(() => HttpOverrides.global = null);

  const deadProbe = 'http://127.0.0.1:9/health';

  test('starts optimistic so a healthy launch never flashes a banner', () {
    final provider = ConnectivityProvider(probeUrl: deadProbe, autoStart: false);
    addTearDown(provider.dispose);

    expect(provider.isOffline, isFalse);
    expect(provider.isConnectedButUnreachable, isFalse);
  });

  test('a failing probe marks the app offline even though an interface exists',
      () async {
    final provider = ConnectivityProvider(probeUrl: deadProbe, autoStart: false);
    addTearDown(provider.dispose);

    final reachable = await provider.checkNow();

    expect(reachable, isFalse);
    expect(provider.isOffline, isTrue,
        reason: 'interface is up but nothing gets through — the expired-bundle '
            'case the old interface-only check reported as online');
    // The distinction that lets the banner say "connected, but can't reach
    // Help24" instead of the misleading "you're offline" to someone whose
    // phone is plainly showing bars.
    expect(provider.isConnectedButUnreachable, isTrue);
  });

  test('a single request failure is suspicion, not proof', () {
    final provider = ConnectivityProvider(probeUrl: deadProbe, autoStart: false);
    addTearDown(provider.dispose);

    provider.reportFailure();

    // One dead endpoint must not black out the whole app.
    expect(provider.isOffline, isFalse);
  });

  test('a success restores online state and notifies listeners', () async {
    final provider = ConnectivityProvider(probeUrl: deadProbe, autoStart: false);
    addTearDown(provider.dispose);

    await provider.checkNow();
    expect(provider.isOffline, isTrue);

    var notified = false;
    provider.addListener(() => notified = true);

    // Real traffic succeeding is free proof the connection is back — this is
    // what drives automatic recovery without any polling.
    provider.reportSuccess();

    expect(provider.isOffline, isFalse);
    expect(notified, isTrue);
  });

  test('probes are throttled so failures cannot become a request storm',
      () async {
    final provider = ConnectivityProvider(probeUrl: deadProbe, autoStart: false);
    addTearDown(provider.dispose);

    final first = DateTime.now();
    await provider.checkNow();
    final elapsed = DateTime.now().difference(first);

    // The second call must short-circuit on the min-gap rather than issue
    // another request.
    final start = DateTime.now();
    await provider.checkNow();
    final secondElapsed = DateTime.now().difference(start);

    expect(secondElapsed.inMilliseconds, lessThan(elapsed.inMilliseconds + 50));
  });
}
