import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/provider_reputation.dart';
import 'package:help24/services/reputation_service.dart';

/// Batched feed reputation (migration 079): the public_provider_reputation
/// view mirrors the GET /reputation/:id response shape, and PostService seeds
/// ReputationService's cache from its rows so cards paint complete. These
/// tests pin the view→model contract and the seeding behavior.
void main() {
  group('ProviderReputation.fromJson parses a view-shaped row', () {
    test('all display fields map from the 079 column names', () {
      final rep = ProviderReputation.fromJson({
        'provider_id': 'prov-1',
        'average_rating': 4.8,
        'bayesian_rating': 4.6,
        'total_reviews': 12,
        'completed_jobs': 30,
        'disputed_jobs': 1,
        'open_disputes': 0,
        'completion_rate': 0.96,
        'dispute_rate': 0.03,
        'repeat_clients': 4,
        'tier': 'top_rated',
        'member_since': '2025-02-01T10:00:00Z',
        'last_active_at': '2026-07-01T08:00:00Z',
      });
      expect(rep.providerId, 'prov-1');
      expect(rep.averageRating, 4.8);
      expect(rep.totalReviews, 12);
      expect(rep.hasReviews, isTrue);
      expect(rep.tier, 'top_rated');
      expect(rep.tierLabel, 'Top Rated');
      expect(rep.memberSinceYear, '2025');
    });

    test('integer-typed numerics from PostgREST parse as doubles', () {
      final rep = ProviderReputation.fromJson({
        'provider_id': 'prov-2',
        'average_rating': 5, // whole numbers arrive as int in JSON
        'bayesian_rating': 4,
        'total_reviews': 1,
        'tier': 'rising_provider',
      });
      expect(rep.averageRating, 5.0);
      expect(rep.bayesianRating, 4.0);
    });
  });

  group('ReputationService.seedAll', () {
    test('seeded rows become synchronously readable (cards paint complete)', () {
      ReputationService.seedAll([
        {
          'provider_id': 'seed-a',
          'average_rating': 4.9,
          'total_reviews': 7,
          'tier': 'top_rated',
        },
      ]);
      final cached = ReputationService.getCachedSync('seed-a');
      expect(cached, isNotNull);
      expect(cached!.averageRating, 4.9);
      expect(cached.totalReviews, 7);
    });

    test('rows without a provider_id are skipped, valid siblings still seed', () {
      ReputationService.seedAll([
        {'average_rating': 3.0},
        {'provider_id': '', 'average_rating': 2.0},
        {'provider_id': 'seed-b', 'average_rating': 4.0, 'tier': 'rising_provider'},
      ]);
      expect(ReputationService.getCachedSync(''), isNull);
      expect(ReputationService.getCachedSync('seed-b'), isNotNull);
    });

    test('invalidate drops a seeded entry', () {
      ReputationService.seedAll([
        {'provider_id': 'seed-c', 'average_rating': 4.0, 'tier': 'new_provider'},
      ]);
      expect(ReputationService.getCachedSync('seed-c'), isNotNull);
      ReputationService.invalidate('seed-c');
      expect(ReputationService.getCachedSync('seed-c'), isNull);
    });
  });
}
