import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/provider_reputation.dart';
import 'package:help24/providers/connectivity_provider.dart' show NetworkHealth;
import 'package:help24/services/reputation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reputation cache contract.
///
/// WHAT THIS EXISTS TO PREVENT
/// ---------------------------
/// An applicant list is N strangers being compared at once, and it used to
/// fetch each one's trust record separately, from memory that did not survive a
/// restart, reporting every failure as the same four words: "Reputation
/// unavailable". Three things had to become true, and each is pinned below:
///
///   1. A value survives a restart, so a reopened app does not re-earn what it
///      already knows (persistence round-trip).
///   2. A value past its freshness window is still SHOWN, not hidden, while a
///      refresh runs behind it (stale-while-revalidate).
///   3. A missing value says WHY. "Offline" is a statement about the phone;
///      "unavailable" is a statement about the provider, and the two must never
///      be printed for each other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReputationService.resetForTest();
    NetworkHealth.resetForTest();
  });

  ProviderReputation rep(String id, {String tier = 'top_rated'}) =>
      ProviderReputation.fromJson({
        'provider_id': id,
        'average_rating': 4.8,
        'bayesian_rating': 4.6,
        'total_reviews': 12,
        'completed_jobs': 30,
        'disputed_jobs': 1,
        'open_disputes': 0,
        'completion_rate': 0.96,
        'dispute_rate': 0.03,
        'repeat_clients': 4,
        'tier': tier,
        'member_since': '2025-02-01T10:00:00Z',
        'last_active_at': '2026-07-01T08:00:00Z',
      });

  /// Write the on-disk shape directly, which is what a PREVIOUS run of the app
  /// left behind. Going through seedAll would test the writer against itself.
  Future<void> seedDisk(String id, {required DateTime at, String tier = 'top_rated'}) async {
    SharedPreferences.setMockInitialValues({
      'help24_cache_reputation': jsonEncode({
        id: {
          'at': at.millisecondsSinceEpoch,
          'row': rep(id, tier: tier).toCacheMap(),
        },
      }),
    });
  }

  group('a value survives a restart', () {
    test('toCacheMap round-trips through fromJson without losing a field', () {
      final original = rep('prov-1');
      final restored = ProviderReputation.fromJson(original.toCacheMap());

      expect(restored.providerId, original.providerId);
      expect(restored.averageRating, original.averageRating);
      expect(restored.bayesianRating, original.bayesianRating);
      expect(restored.totalReviews, original.totalReviews);
      expect(restored.completedJobs, original.completedJobs);
      expect(restored.disputedJobs, original.disputedJobs);
      expect(restored.openDisputes, original.openDisputes);
      expect(restored.completionRate, original.completionRate);
      expect(restored.disputeRate, original.disputeRate);
      expect(restored.repeatClients, original.repeatClients);
      expect(restored.tier, original.tier);
      expect(restored.memberSince, original.memberSince);
      expect(restored.lastActiveAt, original.lastActiveAt);
    });

    test('restore() makes a previous run\'s value readable before any request',
        () async {
      await seedDisk('prov-1', at: DateTime.now(), tier: 'highly_recommended');

      await ReputationService.restore();

      // Synchronously readable — which is what lets a card paint its trust line
      // in the same frame as the name above it, with no network at all.
      final cached = ReputationService.getCachedSync('prov-1');
      expect(cached, isNotNull);
      expect(cached!.tier, 'highly_recommended');
      expect(cached.completedJobs, 30);
    });

    test('an entry older than the stale window is dropped, not shown', () async {
      await seedDisk('prov-old', at: DateTime.now().subtract(const Duration(days: 30)));

      await ReputationService.restore();

      expect(ReputationService.peek('prov-old').hasValue, isFalse);
    });

    test('restore is idempotent and never overwrites a value fetched this run',
        () async {
      await seedDisk('prov-1', at: DateTime.now(), tier: 'new_provider');
      // Something newer landed first — a batch warm, a single read.
      ReputationService.seedAll([rep('prov-1', tier: 'trusted_professional').toCacheMap()]);

      await ReputationService.restore();
      await ReputationService.restore();

      expect(ReputationService.getCachedSync('prov-1')!.tier, 'trusted_professional');
    });
  });

  group('a stale value is shown, not hidden', () {
    test('past the freshness window peek still returns it, flagged stale', () async {
      await seedDisk('prov-1', at: DateTime.now().subtract(const Duration(hours: 6)));
      await ReputationService.restore();

      // Not fresh...
      expect(ReputationService.getCachedSync('prov-1'), isNull);
      // ...but still true, and still the right thing to put on screen.
      final peeked = ReputationService.peek('prov-1');
      expect(peeked.hasValue, isTrue);
      expect(peeked.stale, isTrue);
      expect(peeked.outcome, ReputationOutcome.ok);
      expect(peeked.rep!.tier, 'top_rated');
    });

    test('inside the freshness window it is not flagged stale', () async {
      ReputationService.seedAll([rep('prov-1').toCacheMap()]);

      final peeked = ReputationService.peek('prov-1');
      expect(peeked.hasValue, isTrue);
      expect(peeked.stale, isFalse);
    });
  });

  group('a missing value says why', () {
    test('offline is reported as offline, and no request is attempted',
        () async {
      NetworkHealth.publish(offline: true);

      final outcome = await ReputationService.warmAll(['prov-1', 'prov-2']);

      expect(outcome, ReputationOutcome.offline);
      // The card asks the same question and gets the same answer, so it can say
      // "you're offline" rather than blaming the provider.
      expect(ReputationService.peek('prov-1').outcome, ReputationOutcome.offline);
      expect(ReputationService.peek('prov-1').hasValue, isFalse);
    });

    test('a cached value wins over being offline — offline is not "unknown"',
        () async {
      await seedDisk('prov-1', at: DateTime.now().subtract(const Duration(hours: 6)));
      await ReputationService.restore();
      NetworkHealth.publish(offline: true);

      final outcome = await ReputationService.warmAll(['prov-1']);
      // Nothing to fetch: what we hold already answers for this provider.
      expect(outcome, ReputationOutcome.ok);
      expect(ReputationService.peek('prov-1').hasValue, isTrue);
    });

    test('an id with nothing known and no failure is not an error state', () {
      final peeked = ReputationService.peek('never-heard-of');
      expect(peeked.hasValue, isFalse);
      expect(peeked.outcome, ReputationOutcome.ok);
    });

    test('a successful seed clears a previous offline verdict', () async {
      NetworkHealth.publish(offline: true);
      await ReputationService.warmAll(['prov-1']);
      expect(ReputationService.peek('prov-1').outcome, ReputationOutcome.offline);

      // Reconnected; the batch came back.
      ReputationService.seedAll([rep('prov-1').toCacheMap()]);

      final peeked = ReputationService.peek('prov-1');
      expect(peeked.outcome, ReputationOutcome.ok);
      expect(peeked.hasValue, isTrue);
    });
  });

  group('the batch is one request, for everyone', () {
    test('providers already fresh are not re-requested', () async {
      ReputationService.seedAll([
        rep('prov-1').toCacheMap(),
        rep('prov-2').toCacheMap(),
      ]);
      NetworkHealth.publish(offline: true);

      // Offline, yet OK: every id asked for is already known, so there was
      // nothing for the network to fail at.
      expect(await ReputationService.warmAll(['prov-1', 'prov-2']), ReputationOutcome.ok);
    });

    test('an empty list is a no-op, not a request', () async {
      NetworkHealth.publish(offline: true);
      expect(await ReputationService.warmAll(const []), ReputationOutcome.ok);
      expect(await ReputationService.warmAll(['', '']), ReputationOutcome.ok);
    });
  });
}
