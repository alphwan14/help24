import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/place_name_cache.dart';

/// Regression guard for the self-referential future deadlock.
///
/// PlaceNameCache de-duplicates concurrent lookups through an _inFlight map of
/// Futures. Clearing the entry with `whenComplete(() => _inFlight.remove(key))`
/// makes the callback return the stored value — the very future being composed
/// — and whenComplete awaits any Future its callback returns, so the future
/// waits on itself and never completes.
///
/// The symptom is silent: the lookup succeeds (or fails) internally, nothing
/// throws, and every caller's `await` simply hangs. On the journey confirm
/// screen that meant the destination area name never appeared and no error was
/// ever reported.
///
/// In a unit test the platform geocoder is unavailable, so the lookup takes its
/// failure path and resolves to null. That is fine — the point of the test is
/// that it RESOLVES AT ALL.
void main() {
  test('resolve() completes rather than hanging', () async {
    final name = await PlaceNameCache.resolve(-4.0061, 39.6813).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
          'PlaceNameCache.resolve never completed — the in-flight future is '
          'awaiting itself'),
    );
    expect(name, anyOf(isNull, isA<String>()));
  });

  test('concurrent lookups for the same coordinates all complete', () async {
    final futures = List.generate(
      3,
      (_) => PlaceNameCache.resolve(-4.0100, 39.6900),
    );
    final results = await Future.wait(futures).timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          throw StateError('shared in-flight future never completed'),
    );
    expect(results.length, 3);
  });
}
