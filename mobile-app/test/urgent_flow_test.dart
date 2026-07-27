import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/utils/post_ownership.dart';
import 'package:help24/utils/proximity.dart';
import 'package:help24/utils/urgent_window.dart';

/// Regression suite: URGENT IS THE SAME MARKETPLACE, FILTERED TO EMERGENCIES.
///
/// THE BUGS THIS LOCKS DOWN
/// ------------------------
/// `UrgentRequestsScreen` was the only listing surface never migrated to the
/// shared modules, and it disagreed with the rest of the app on all three:
///
///   1. A hand-rolled card showing title, distance and age — no author, no
///      avatar, no reputation, no price. You could not see who was asking.
///   2. A bottom sheet in place of the detail screen, showing LESS than a
///      Discover card shows at a glance.
///   3. "Offer Help Now" opened a private CHAT. Urgent posts are requests, and
///      `listingTakesApplications(request)` is true everywhere else in the app.
///
/// (3) was the expensive one. The request lifecycle — select provider → assign
/// → escrow → complete → review — runs entirely on the `applications` table, so
/// a chat-only response never reached the author's applicants list and never
/// entered payment protection. It also skipped every guard the shared flow
/// performs: ownership (the author tapping their own urgent post got a SILENT
/// no-op), closed listings (an assigned request still invited responses),
/// duplicates, and the provider-ready gate that ensures whoever answers can be
/// paid.
///
/// Plus two state bugs of the same class as the offline-messaging one:
///   * going offline assigned `_urgentPosts = const []`, blanking the screen
///     and zeroing the Discover badge;
///   * the badge counted a PAGE SIZE — Discover loaded 5, the screen loaded 20,
///     both wrote the same list, so the number changed with navigation.

PostModel urgentRequest({
  String id = 'urgent-1',
  String authorUserId = 'author-1',
  String status = 'open',
  DateTime? expiresAt,
  double? latitude = -1.2921,
  double? longitude = 36.8219,
}) =>
    PostModel(
      id: id,
      title: 'Burst pipe flooding the kitchen',
      description: 'Water everywhere, need someone now',
      category: Category.fromName('Plumbing'),
      location: 'Kilimani, Nairobi',
      price: 3000,
      urgency: Urgency.urgent,
      type: PostType.request,
      isUrgent: true,
      urgentExpiresAt: expiresAt,
      authorUserId: authorUserId,
      authorName: 'Grace Wanjiru',
      status: status,
      latitude: latitude,
      longitude: longitude,
    );

void main() {
  final now = DateTime.utc(2026, 7, 27, 12, 0);

  group('an urgent post answers exactly as it would in Discover', () {
    test('a request takes applications — never a chat', () {
      // The whole divergence in one assertion. The screen used to answer this
      // question differently from every other surface.
      final post = urgentRequest();
      expect(listingTakesApplications(post.type), isTrue);
    });

    test('a stranger is offered APPLY, so the response reaches the author', () {
      expect(
        listingCtaFor(
          type: PostType.request,
          authorUserId: 'author-1',
          viewerUserId: 'provider-9',
          status: 'open',
          hasApplied: false,
        ),
        ListingCta.apply,
      );
    });

    test('the author gets MANAGE, not a silent dead tap', () {
      // _openPrivateChat returned early on `authorId == currentUserId`, with no
      // message and no navigation: the author tapped their own urgent post and
      // absolutely nothing happened.
      expect(
        listingCtaFor(
          type: PostType.request,
          authorUserId: 'author-1',
          viewerUserId: 'author-1',
          status: 'open',
          hasApplied: false,
        ),
        ListingCta.manage,
      );
    });

    test('an assigned urgent request stops inviting responses', () {
      // "Offer Help Now" was rendered unconditionally — a request that already
      // had a provider still asked strangers to help.
      expect(
        listingCtaFor(
          type: PostType.request,
          authorUserId: 'author-1',
          viewerUserId: 'provider-9',
          status: 'assigned',
          hasApplied: false,
        ),
        ListingCta.unavailable,
      );
    });

    test('a second response is refused', () {
      expect(
        listingCtaFor(
          type: PostType.request,
          authorUserId: 'author-1',
          viewerUserId: 'provider-9',
          status: 'open',
          hasApplied: true,
        ),
        ListingCta.applied,
      );
    });
  });

  group('the urgent window is a property of the clock, not of the query', () {
    test('an open window reports the time left', () {
      final post = urgentRequest(expiresAt: now.add(const Duration(minutes: 42)));
      expect(urgentTimeRemaining(post, now), const Duration(minutes: 42));
      expect(isUrgentWindowOpen(post, now), isTrue);
    });

    test('a closed window reports zero, never negative', () {
      final post = urgentRequest(expiresAt: now.subtract(const Duration(minutes: 5)));
      expect(urgentTimeRemaining(post, now), Duration.zero);
      expect(isUrgentWindowOpen(post, now), isFalse);
    });

    test('a post with no window is kept, not silently hidden', () {
      // Legacy urgent rows predate urgent_expires_at. Filtering them out would
      // make real requests vanish.
      final post = urgentRequest(expiresAt: null);
      expect(isUrgentWindowOpen(post, now), isTrue);
      expect(urgentTimeRemaining(post, now), isNull);
      expect(urgentCountdownFor(post, now), isNull);
    });

    test('expiry is evaluated in UTC regardless of the stored zone', () {
      final post = urgentRequest(
        expiresAt: DateTime.utc(2026, 7, 27, 12, 30).toLocal(),
      );
      expect(isUrgentWindowOpen(post, now), isTrue);
      expect(urgentTimeRemaining(post, now), const Duration(minutes: 30));
    });

    test('a post whose window closes mid-session leaves the list', () {
      // The list is fetched once and held. Without this, a request whose hour
      // ran out while the screen was open stayed on it, still labelled URGENT.
      final posts = [
        urgentRequest(id: 'live', expiresAt: now.add(const Duration(minutes: 20))),
        urgentRequest(id: 'expired', expiresAt: now.subtract(const Duration(seconds: 1))),
        urgentRequest(id: 'legacy', expiresAt: null),
      ];

      final open = openUrgentPosts(posts, now);

      expect(open.map((p) => p.id), ['live', 'legacy']);
    });

    test('filtering preserves the proximity order it was given', () {
      final posts = [
        urgentRequest(id: 'a', expiresAt: now.add(const Duration(minutes: 5))),
        urgentRequest(id: 'gone', expiresAt: now.subtract(const Duration(minutes: 1))),
        urgentRequest(id: 'b', expiresAt: now.add(const Duration(minutes: 9))),
      ];

      expect(openUrgentPosts(posts, now).map((p) => p.id), ['a', 'b']);
    });
  });

  group('countdown labels', () {
    test('minutes above a minute', () {
      expect(formatUrgentCountdown(const Duration(minutes: 42)), '42 min left');
      expect(formatUrgentCountdown(const Duration(minutes: 1)), '1 min left');
      expect(
        formatUrgentCountdown(const Duration(minutes: 1, seconds: 59)),
        '1 min left',
      );
    });

    test('seconds below a minute', () {
      expect(formatUrgentCountdown(const Duration(seconds: 40)), '40s left');
      expect(formatUrgentCountdown(const Duration(seconds: 1)), '1s left');
    });

    test('a closed window says so instead of counting down from zero', () {
      expect(formatUrgentCountdown(Duration.zero), 'Expired');
      expect(formatUrgentCountdown(const Duration(seconds: -30)), 'Expired');
    });

    test('no window means no countdown, so the card shows its normal tag', () {
      expect(formatUrgentCountdown(null), isNull);
    });
  });

  group('proximity — one haversine, not two', () {
    test('a known distance is measured correctly', () {
      // Nairobi CBD → Westlands, ~4 km.
      final km = distanceKm(-1.2864, 36.8172, -1.2670, 36.8100);
      expect(km, greaterThan(1.5));
      expect(km, lessThan(3.5));
    });

    test('the same point is zero distance', () {
      expect(distanceKm(-1.2921, 36.8219, -1.2921, 36.8219), closeTo(0, 0.0001));
    });

    test('a missing coordinate on either side yields null, never a number', () {
      // "We do not know how far away this is" must not become "0 m away".
      expect(
        distanceBetween(
          viewerLatitude: null,
          viewerLongitude: 36.8,
          targetLatitude: -1.29,
          targetLongitude: 36.82,
        ),
        isNull,
      );
      expect(
        distanceBetween(
          viewerLatitude: -1.29,
          viewerLongitude: 36.8,
          targetLatitude: null,
          targetLongitude: null,
        ),
        isNull,
      );
      expect(formatDistanceLabelOrNull(null), isNull);
    });

    test('sub-kilometre reads in metres, rounded to 10 m', () {
      expect(formatDistanceLabel(0.417), '420 m away');
      expect(formatDistanceLabel(0.05), '50 m away');
    });

    test('one decimal under 10 km, whole kilometres beyond', () {
      expect(formatDistanceLabel(1.24), '1.2 km away');
      expect(formatDistanceLabel(9.96), '10.0 km away');
      expect(formatDistanceLabel(18.4), '18 km away');
    });
  });

  group('the badge counts emergencies, not page slots', () {
    test('every caller loads the same page size', () {
      // Discover's header used the default (5) and the Urgent screen asked for
      // 20; both wrote the same list, so the badge changed with navigation.
      expect(AppProvider.urgentPageSize, 20);
    });

    test('expired posts do not inflate the count', () {
      final posts = [
        urgentRequest(id: '1', expiresAt: now.add(const Duration(minutes: 30))),
        urgentRequest(id: '2', expiresAt: now.subtract(const Duration(minutes: 30))),
        urgentRequest(id: '3', expiresAt: now.subtract(const Duration(hours: 2))),
      ];

      expect(openUrgentPosts(posts, now).length, 1);
    });
  });
}
