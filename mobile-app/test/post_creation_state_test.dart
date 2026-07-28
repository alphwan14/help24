import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/post_service.dart';
import 'package:help24/utils/post_ownership.dart';

/// Regression suite: A CREATED POST MUST BE INDISTINGUISHABLE FROM A FETCHED ONE.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// `PostService.createPost` inserted with a bare `.select()` — no author join —
/// discarded the returned row except for its `id`, and handed back the CALLER'S
/// DRAFT with that id stapled on. `PostScreen` never sets any author field, so
/// what reached Discover carried the constructor defaults:
///
///   authorUserId : ''      authorName : '?'      authorAvatar : ''
///
/// Everything the user reported follows from that one object:
///
///   * the card showed a literal `?` for the poster's name;
///   * no avatar, no rating, no reviews — `ReputationCompact` short-circuits on
///     an empty providerId and renders nothing;
///   * `isListingOwner` correctly refused to match an empty author id, so the
///     poster's own post offered them "Offer Service" instead of the owner CTA;
///   * `PostCard`'s "show my own name instead of '?'" fallback was gated on
///     `isCurrentUser`, which could never be true — the safety net was wired to
///     the thing that had broken;
///   * `AppProvider.createPost` then wrote that object to the offline cache, so
///     the `?` survived an app restart.
///
/// A pull-to-refresh "fixed" it only because a refresh was the FIRST time real
/// author data ever entered the app.
///
/// The fix is structural: one `feedRowSelect` shared by every read AND by both
/// writes, so the insert returns a feed-shaped row in the same round-trip and
/// `PostModel.fromJson` builds the created post exactly as the feed builds
/// every other one. These tests pin the shape and the rules that read it.

/// The row PostgREST returns for `insert(...).select(PostService.feedRowSelect)`
/// — a real posts row plus the author join. `post_images` and `applications`
/// are empty because images are written after the insert and nobody has applied
/// to a post that is one millisecond old.
Map<String, dynamic> insertReturningRow({
  String authorUserId = 'author-1',
  String? authorName = 'Grace Wanjiru',
  String? avatarUrl = 'https://cdn.help24.co.ke/a/grace.jpg',
  String? phoneNumber = '+254700000001',
  Map<String, dynamic>? attributes,
}) =>
    {
      'id': 'post-new-1',
      'title': 'Fix a leaking kitchen tap',
      'description': 'Dripping since Tuesday',
      'category': 'Plumbing',
      'location': 'Kilimani, Nairobi',
      'price': 1500,
      'urgency': 'soon',
      'type': 'request',
      'pricing_type': 'task',
      'difficulty': 'medium',
      'status': 'open',
      'author_user_id': authorUserId,
      'author_temp_id': '',
      'created_at': '2026-07-27T09:15:00Z',
      'is_urgent': false,
      'latitude': -1.2921,
      'longitude': 36.8219,
      'post_images': const <dynamic>[],
      'applications': const <dynamic>[],
      'users': {
        'name': authorName,
        'email': 'grace@example.com',
        'profile_image': null,
        'avatar_url': avatarUrl,
        'phone_number': phoneNumber,
      },
      if (attributes != null) 'attributes': attributes,
      if (attributes != null) 'attributes_schema_version': 3,
    };

void main() {
  group('feedRowSelect is the one shape', () {
    test('joins the author, images and applications', () {
      expect(PostService.feedRowSelect, contains('users!author_user_id'));
      expect(PostService.feedRowSelect, contains('post_images(image_url)'));
      expect(PostService.feedRowSelect, contains('applications('));
    });

    test('requests every field a card needs from the author', () {
      // Name and avatar answer the '?'; phone_number drives the M-Pesa tag.
      for (final column in ['name', 'avatar_url', 'profile_image', 'phone_number']) {
        expect(PostService.feedRowSelect, contains(column),
            reason: 'a card reads $column from the author join');
      }
    });
  });

  group('a post parsed from the insert-returning row is complete', () {
    test('carries the author identity — the whole bug in one assertion', () {
      final post = PostModel.fromJson(insertReturningRow());

      expect(post.authorUserId, 'author-1');
      expect(post.authorName, 'Grace Wanjiru');
      expect(post.authorName, isNot('?'));
      expect(post.authorAvatar, isNotEmpty);
      expect(post.authorHasPhone, isTrue);
    });

    test('the poster is recognised as the owner immediately', () {
      final post = PostModel.fromJson(insertReturningRow());

      expect(
        isListingOwner(
          authorUserId: post.authorUserId,
          viewerUserId: 'author-1',
        ),
        isTrue,
      );
    });

    test('the poster is offered MANAGE, never "Offer Service"', () {
      final post = PostModel.fromJson(insertReturningRow());

      expect(
        listingCtaFor(
          type: post.type,
          authorUserId: post.authorUserId,
          viewerUserId: 'author-1',
          status: post.status,
          hasApplied: false,
        ),
        ListingCta.manage,
      );
    });

    test('someone else still gets APPLY on the same post', () {
      final post = PostModel.fromJson(insertReturningRow());

      expect(
        listingCtaFor(
          type: post.type,
          authorUserId: post.authorUserId,
          viewerUserId: 'someone-else',
          status: post.status,
          hasApplied: false,
        ),
        ListingCta.apply,
      );
    });

    test('a non-empty author id means reputation is actually requested', () {
      // ReputationService.getReputation short-circuits to null on an empty id,
      // which is why a freshly posted card showed no rating and no tier.
      final post = PostModel.fromJson(insertReturningRow());
      expect(post.authorUserId, isNotEmpty);
    });

    test('server timestamp and status come from the row, not the draft', () {
      final post = PostModel.fromJson(insertReturningRow());
      expect(post.createdAt.toUtc().hour, 9);
      expect(post.status, 'open');
    });
  });

  group('the old bug, restated as the shape it produced', () {
    test('a draft with no author id is never its own owner', () {
      final draft = PostModel(
        id: 'post-new-1',
        title: 'Fix a leaking kitchen tap',
        description: '',
        category: Category.fromName('Plumbing'),
        location: 'Kilimani, Nairobi',
        price: 1500,
        urgency: Urgency.soon,
        type: PostType.request,
      );

      // Exactly what the UI was handed before the fix.
      expect(draft.authorUserId, isEmpty);
      expect(draft.authorName, '?');
      expect(
        isListingOwner(authorUserId: draft.authorUserId, viewerUserId: 'author-1'),
        isFalse,
      );
      expect(
        listingCtaFor(
          type: draft.type,
          authorUserId: draft.authorUserId,
          viewerUserId: 'author-1',
          status: draft.status,
          hasApplied: false,
        ),
        ListingCta.apply, // "Offer Service" on your own request
      );
    });
  });

  group('copyWith preserves Smart Posting answers', () {
    test('attributes survive a copyWith that does not mention them', () {
      // createPost merges the uploaded image URLs with copyWith. Because
      // `attributes` was missing from the parameter list AND from the forwarded
      // constructor call, every copy silently reset them to {} — so the new card
      // rendered without its time-signal or highlight chips.
      final post = PostModel.fromJson(insertReturningRow(
        attributes: {'_when': 'this_week', 'fixture': 'Kitchen sink'},
      ));
      expect(post.attributes, isNotEmpty);

      final copied = post.copyWith(images: ['https://cdn/img1.jpg']);

      expect(copied.attributes, post.attributes);
      expect(copied.attributesSchemaVersion, post.attributesSchemaVersion);
      expect(copied.images, ['https://cdn/img1.jpg']);
    });

    test('attributes can still be replaced explicitly', () {
      final post = PostModel.fromJson(insertReturningRow(attributes: {'a': 1}));
      final copied = post.copyWith(attributes: {'b': 2}, attributesSchemaVersion: 9);

      expect(copied.attributes, {'b': 2});
      expect(copied.attributesSchemaVersion, 9);
    });

    test('the author identity survives an images-only copy', () {
      final post = PostModel.fromJson(insertReturningRow());
      final copied = post.copyWith(images: ['https://cdn/img1.jpg']);

      expect(copied.authorUserId, 'author-1');
      expect(copied.authorName, 'Grace Wanjiru');
      expect(copied.authorHasPhone, isTrue);
    });
  });

  group('the offline cache round-trip stays truthful', () {
    test('author identity, status and answers survive save → load', () {
      final post = PostModel.fromJson(insertReturningRow(
        attributes: {'_when': 'this_week', 'fixture': 'Kitchen sink'},
      ));

      final restored = PostModel.fromJson(post.toCacheMap());

      expect(restored.authorUserId, post.authorUserId);
      expect(restored.authorName, post.authorName);
      expect(restored.authorAvatar, post.authorAvatar);
      expect(restored.authorHasPhone, isTrue);
      expect(restored.status, post.status);
      // toCacheMap omitted attributes entirely, so an offline relaunch dropped
      // every intent chip the online feed had shown.
      expect(restored.attributes, post.attributes);
      expect(restored.attributesSchemaVersion, post.attributesSchemaVersion);
    });

    test('a cached post is still recognised as the viewer\'s own', () {
      final post = PostModel.fromJson(insertReturningRow());
      final restored = PostModel.fromJson(post.toCacheMap());

      expect(
        listingCtaFor(
          type: restored.type,
          authorUserId: restored.authorUserId,
          viewerUserId: 'author-1',
          status: restored.status,
          hasApplied: false,
        ),
        ListingCta.manage,
      );
    });
  });

  group('jobs take the identical path', () {
    test('a job parsed from its insert-returning row knows its author', () {
      final row = insertReturningRow()
        ..['type'] = 'job'
        ..['employment_type'] = 'full_time';

      final job = JobModel.fromJson(row);

      expect(job.authorUserId, 'author-1');
      expect(job.authorName, 'Grace Wanjiru');
      expect(job.authorAvatarUrl, isNotEmpty);
      expect(
        isListingOwner(authorUserId: job.authorUserId, viewerUserId: 'author-1'),
        isTrue,
      );
    });

    test('the job cache round-trip keeps ownership intact', () {
      final row = insertReturningRow()..['type'] = 'job';
      final restored = JobModel.fromJson(JobModel.fromJson(row).toCacheMap());

      expect(restored.authorUserId, 'author-1');
      expect(restored.authorName, 'Grace Wanjiru');
    });
  });
}
