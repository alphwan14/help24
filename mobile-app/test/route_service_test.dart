import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/route_service.dart';
import 'package:help24/widgets/location_experience.dart';

/// Phase 3 routing primitives. These are the pure functions the ETA experience
/// rests on, so they are worth pinning: a silent regression here would surface
/// as a wrong ETA or a mangled route line on a real journey.
void main() {
  group('decodePolyline', () {
    test('decodes Google\'s reference polyline', () {
      // The example from Google's encoded-polyline specification.
      final points = RouteService.decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(points.length, 3);
      expect(points[0].lat, closeTo(38.5, 0.00001));
      expect(points[0].lng, closeTo(-120.2, 0.00001));
      expect(points[1].lat, closeTo(40.7, 0.00001));
      expect(points[1].lng, closeTo(-120.95, 0.00001));
      expect(points[2].lat, closeTo(43.252, 0.00001));
      expect(points[2].lng, closeTo(-126.453, 0.00001));
    });

    test('empty and null input yield no points, never throw', () {
      expect(RouteService.decodePolyline(null), isEmpty);
      expect(RouteService.decodePolyline(''), isEmpty);
    });

    test('truncated input does not hang or throw', () {
      // A payload cut short mid-varint must terminate, not loop forever.
      expect(() => RouteService.decodePolyline('_p~iF~ps|U_ulL'), returnsNormally);
    });
  });

  group('shouldRefresh (Routes cost control)', () {
    JourneyRoute routeAgedSeconds(int seconds) => JourneyRoute(
          durationSeconds: 600,
          distanceMeters: 4800,
          path: const [],
          computedAt: DateTime.now().subtract(Duration(seconds: seconds)),
        );

    test('fetches when there is no route yet', () {
      expect(
        RouteService.shouldRefresh(
          current: null,
          lastFetchLat: null,
          lastFetchLng: null,
          nowLat: -3.97,
          nowLng: 39.72,
          straightLineToDestM: 5000,
        ),
        isTrue,
      );
    });

    test('does not refetch when parked and the route is fresh', () {
      expect(
        RouteService.shouldRefresh(
          current: routeAgedSeconds(10),
          lastFetchLat: -3.97,
          lastFetchLng: 39.72,
          nowLat: -3.97,
          nowLng: 39.72,
          straightLineToDestM: 5000,
        ),
        isFalse,
      );
    });

    test('refetches after meaningful movement', () {
      // ~0.005 deg latitude is ~550 m — past the 250 m threshold.
      expect(
        RouteService.shouldRefresh(
          current: routeAgedSeconds(5),
          lastFetchLat: -3.97,
          lastFetchLng: 39.72,
          nowLat: -3.975,
          nowLng: 39.72,
          straightLineToDestM: 5000,
        ),
        isTrue,
      );
    });

    test('refetches sooner when close to the destination', () {
      final aged = routeAgedSeconds(50);
      // Far away: 50s is inside the 90s interval → no refetch.
      expect(
        RouteService.shouldRefresh(
          current: aged,
          lastFetchLat: -3.97,
          lastFetchLng: 39.72,
          nowLat: -3.97,
          nowLng: 39.72,
          straightLineToDestM: 8000,
        ),
        isFalse,
      );
      // Close in: the 45s interval applies → refetch.
      expect(
        RouteService.shouldRefresh(
          current: aged,
          lastFetchLat: -3.97,
          lastFetchLng: 39.72,
          nowLat: -3.97,
          nowLng: 39.72,
          straightLineToDestM: 800,
        ),
        isTrue,
      );
    });
  });

  group('JourneyRoute liveness', () {
    test('ETA counts down with elapsed time and never goes negative', () {
      final route = JourneyRoute(
        durationSeconds: 100,
        distanceMeters: 1000,
        path: const [],
        computedAt: DateTime.now().subtract(const Duration(seconds: 40)),
      );
      expect(route.liveDurationSeconds, inInclusiveRange(58, 61));

      final overdue = JourneyRoute(
        durationSeconds: 10,
        distanceMeters: 100,
        path: const [],
        computedAt: DateTime.now().subtract(const Duration(seconds: 300)),
      );
      expect(overdue.liveDurationSeconds, 0);
    });

    test('goes stale after five minutes so no ETA is shown', () {
      final fresh = JourneyRoute(
        durationSeconds: 100,
        distanceMeters: 1000,
        path: const [],
        computedAt: DateTime.now(),
      );
      final old = JourneyRoute(
        durationSeconds: 100,
        distanceMeters: 1000,
        path: const [],
        computedAt: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      expect(fresh.isStale, isFalse);
      expect(old.isStale, isTrue);
    });
  });

  group('presentation copy', () {
    test('etaText reads naturally across the range', () {
      expect(etaText(null), isNull);
      expect(etaText(45), 'Arriving shortly');
      expect(etaText(89), 'Arriving shortly');
      expect(etaText(12 * 60), '12 min away');
      expect(etaText(60 * 60), '1 h away');
      expect(etaText(65 * 60), '1 h 5 min away');
    });

    test('remainingText switches units sensibly', () {
      expect(remainingText(null), isNull);
      expect(remainingText(320), '320 m remaining');
      expect(remainingText(4800), '4.8 km remaining');
    });
  });
}
