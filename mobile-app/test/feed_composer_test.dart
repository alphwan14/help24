import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/models/promotion_models.dart';
import 'package:help24/utils/feed_composer.dart';

PostModel post(String id) => PostModel(
      id: id,
      title: 'Post $id',
      description: 'desc',
      category: Category.fromName('Other'),
      location: 'Nairobi',
      price: 100,
      urgency: Urgency.flexible,
      type: PostType.offer,
    );

SponsoredSlot slot(String campaignId, String postId) => SponsoredSlot(
      campaignId: campaignId,
      placement: 'discover',
      distanceKm: null,
      post: post(postId),
    );

List<PostModel> organic(int n) => List.generate(n, (i) => post('org-$i'));

void main() {
  const config = ServingConfig(discoverFirstAfter: 7, discoverGap: 8);

  group('FeedComposer — cadence', () {
    test('first sponsored card appears after firstAfter organic cards', () {
      final entries = FeedComposer.compose(
        organic: organic(20),
        slots: [slot('c1', 's1')],
        config: config,
      );
      // Positions 0..6 organic, position 7 sponsored.
      for (var i = 0; i < 7; i++) {
        expect(entries[i].sponsored, isFalse);
      }
      expect(entries[7].sponsored, isTrue);
      expect(entries[7].campaignId, 'c1');
    });

    test('subsequent sponsored cards keep the configured gap', () {
      final entries = FeedComposer.compose(
        organic: organic(30),
        slots: [slot('c1', 's1'), slot('c2', 's2')],
        config: config,
      );
      final sponsoredIndexes =
          [for (var i = 0; i < entries.length; i++) if (entries[i].sponsored) i];
      expect(sponsoredIndexes, [7, 16]); // 7 organic, ad, 8 organic, ad
    });

    test('sponsored cards NEVER cluster — always ≥ gap organic cards between', () {
      final entries = FeedComposer.compose(
        organic: organic(50),
        slots: List.generate(6, (i) => slot('c$i', 's$i')),
        config: config,
      );
      var organicRun = 0;
      var lastWasSponsored = false;
      for (final e in entries) {
        if (e.sponsored) {
          expect(lastWasSponsored, isFalse, reason: 'two sponsored cards adjacent');
          expect(organicRun, greaterThanOrEqualTo(7));
          organicRun = 0;
          lastWasSponsored = true;
        } else {
          organicRun++;
          lastWasSponsored = false;
        }
      }
    });

    test('a short feed shows NO sponsored card (never feels like an ad board)', () {
      final entries = FeedComposer.compose(
        organic: organic(3),
        slots: [slot('c1', 's1')],
        config: config,
      );
      expect(entries.every((e) => !e.sponsored), isTrue);
      expect(entries, hasLength(3));
    });

    test('empty organic feed → empty result, even with slots available', () {
      final entries = FeedComposer.compose(
        organic: const [],
        slots: [slot('c1', 's1')],
        config: config,
      );
      expect(entries, isEmpty);
    });
  });

  group('FeedComposer — organic integrity', () {
    test('organic order is never changed and nothing is dropped', () {
      final posts = organic(25);
      final entries = FeedComposer.compose(
        organic: posts,
        slots: [slot('c1', 's1'), slot('c2', 's2')],
        config: config,
      );
      final organicOut =
          entries.where((e) => !e.sponsored).map((e) => e.post.id).toList();
      expect(organicOut, posts.map((p) => p.id).toList());
    });

    test('a post already in the organic list is not duplicated as sponsored', () {
      final posts = organic(20);
      final entries = FeedComposer.compose(
        organic: posts,
        slots: [slot('c1', 'org-3'), slot('c2', 's2')], // c1 duplicates org-3
        config: config,
      );
      final sponsoredIds =
          entries.where((e) => e.sponsored).map((e) => e.post.id).toList();
      expect(sponsoredIds, ['s2']); // duplicate slot dropped, next slot used
      expect(entries.where((e) => e.post.id == 'org-3'), hasLength(1));
    });

    test('no slots → pure organic passthrough', () {
      final posts = organic(10);
      final entries = FeedComposer.compose(
        organic: posts,
        slots: const [],
        config: config,
      );
      expect(entries, hasLength(10));
      expect(entries.every((e) => !e.sponsored), isTrue);
    });
  });

  group('FeedComposer — configurable spacing', () {
    test('respects a custom gap configuration', () {
      const tight = ServingConfig(discoverFirstAfter: 2, discoverGap: 3);
      final entries = FeedComposer.compose(
        organic: organic(12),
        slots: [slot('c1', 's1'), slot('c2', 's2'), slot('c3', 's3')],
        config: tight,
      );
      final sponsoredIndexes =
          [for (var i = 0; i < entries.length; i++) if (entries[i].sponsored) i];
      expect(sponsoredIndexes, [2, 6, 10]);
    });

    test('degenerate config values are clamped to sane minimums', () {
      const broken = ServingConfig(discoverFirstAfter: 0, discoverGap: 0);
      final entries = FeedComposer.compose(
        organic: organic(4),
        slots: [slot('c1', 's1'), slot('c2', 's2')],
        config: broken,
      );
      // Clamped to firstAfter=1, gap=1: still never clusters.
      var lastWasSponsored = false;
      for (final e in entries) {
        if (e.sponsored) {
          expect(lastWasSponsored, isFalse);
          lastWasSponsored = true;
        } else {
          lastWasSponsored = false;
        }
      }
    });
  });
}
