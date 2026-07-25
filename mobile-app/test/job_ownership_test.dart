import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/utils/post_ownership.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Regression suite for the Job ownership flow.
///
/// THE BUGS THIS LOCKS DOWN
/// ------------------------
/// One job post produced three different experiences depending on where it was
/// opened from:
///
///   1. Discover → detail screen: the author saw "You posted this job" and no
///      route to their applicants, because every owner affordance was gated on
///      `type == PostType.request`.
///   2. Jobs tab: the author's own job still showed an "Apply" button.
///   3. Pressing it submitted, and the database's self-application trigger
///      rejected the insert as a generic "We couldn't send your response."
///
/// The rules below are now the single definition all three surfaces read.

PostModel makeJob({
  String authorUserId = 'author-1',
  String status = 'open',
}) =>
    PostModel(
      id: 'j1',
      title: 'Delivery rider needed',
      description: 'Full-time rider',
      category: Category.fromName('Other'),
      location: 'Nairobi',
      price: 25000,
      urgency: Urgency.flexible,
      type: PostType.job,
      authorUserId: authorUserId,
      status: status,
    );

void main() {
  group('isListingOwner', () {
    test('matches when the viewer authored the listing', () {
      expect(isListingOwner(authorUserId: 'u1', viewerUserId: 'u1'), isTrue);
    });

    test('does not match a different user', () {
      expect(isListingOwner(authorUserId: 'u1', viewerUserId: 'u2'), isFalse);
    });

    test('empty ids never match — a legacy row must not hand over the owner screen', () {
      expect(isListingOwner(authorUserId: '', viewerUserId: ''), isFalse);
      expect(isListingOwner(authorUserId: '', viewerUserId: 'u1'), isFalse);
      expect(isListingOwner(authorUserId: 'u1', viewerUserId: ''), isFalse);
      expect(isListingOwner(authorUserId: null, viewerUserId: null), isFalse);
    });
  });

  group('listingTakesApplications', () {
    test('requests AND job posts take applications', () {
      expect(listingTakesApplications(PostType.request), isTrue);
      // The whole point: this used to be false everywhere it mattered.
      expect(listingTakesApplications(PostType.job), isTrue);
    });

    test('offers do not — they are enquired about in chat', () {
      expect(listingTakesApplications(PostType.offer), isFalse);
    });
  });

  group('listingCtaFor — the owner is never invited to apply', () {
    test('Issue 2: the author of a job gets management, not Apply', () {
      final job = makeJob(authorUserId: 'me');
      expect(
        listingCtaFor(
          type: job.type,
          authorUserId: job.authorUserId,
          viewerUserId: 'me',
          status: job.status,
          hasApplied: false,
        ),
        ListingCta.manage,
      );
    });

    test('ownership beats every other state', () {
      for (final status in ['open', 'assigned', 'completed', 'disputed', 'cancelled']) {
        for (final applied in [true, false]) {
          for (final type in PostType.values) {
            expect(
              listingCtaFor(
                type: type,
                authorUserId: 'me',
                viewerUserId: 'me',
                status: status,
                hasApplied: applied,
              ),
              ListingCta.manage,
              reason: 'type=$type status=$status applied=$applied',
            );
          }
        }
      }
    });

    test('a stranger may apply to an open job', () {
      expect(
        listingCtaFor(
          type: PostType.job,
          authorUserId: 'author-1',
          viewerUserId: 'someone-else',
          status: 'open',
          hasApplied: false,
        ),
        ListingCta.apply,
      );
    });

    test('having applied blocks a duplicate instead of re-inviting', () {
      expect(
        listingCtaFor(
          type: PostType.job,
          authorUserId: 'author-1',
          viewerUserId: 'someone-else',
          status: 'open',
          hasApplied: true,
        ),
        ListingCta.applied,
      );
    });

    test('a closed request/job stops accepting; an offer is a standing advert', () {
      expect(
        listingCtaFor(
          type: PostType.request,
          authorUserId: 'author-1',
          viewerUserId: 'someone-else',
          status: 'assigned',
          hasApplied: false,
        ),
        ListingCta.unavailable,
      );
      expect(
        listingCtaFor(
          type: PostType.offer,
          authorUserId: 'author-1',
          viewerUserId: 'someone-else',
          status: 'assigned',
          hasApplied: false,
        ),
        ListingCta.enquire,
      );
    });

    test('a signed-out viewer is not the owner of an author-less legacy row', () {
      expect(
        listingCtaFor(
          type: PostType.job,
          authorUserId: '',
          viewerUserId: '',
          status: 'open',
          hasApplied: false,
        ),
        ListingCta.apply,
      );
    });
  });

  group('Issue 3: applying to your own job never becomes a network error', () {
    test('the database trigger message maps to the rule, not to a failure', () {
      // What fn_block_self_application (migration 030) actually raises.
      final failure = ErrorMapper.toFailure(
        PostgrestException(
          message: 'You cannot apply to your own post.',
          code: '23514',
        ),
        context: ErrorContext.apply,
      );
      expect(failure.message, isNot(contains("couldn't send")));
      expect(failure.title, 'This is your post');
    });

    test('the local pre-flight guard maps to the same sentence', () {
      final trigger = ErrorMapper.toFailure(
        PostgrestException(message: 'You cannot apply to your own post.', code: '23514'),
        context: ErrorContext.apply,
      );
      final local = ErrorMapper.toFailure(
        Exception('SelfApplicationException: cannot apply to your own post'),
        context: ErrorContext.apply,
      );
      expect(local.message, trigger.message);
    });
  });

  group('JobModel.toPostModel — the Jobs tab can open the canonical screen', () {
    test('carries ownership, lifecycle and applicants across', () {
      final job = JobModel.fromJson({
        'id': 'j1',
        'title': 'Delivery rider needed',
        'description': 'Full-time rider',
        'category': 'Other',
        'location': 'Nairobi',
        'price': 25000,
        'type': 'job',
        'employment_type': 'full_time',
        'status': 'open',
        'author_user_id': 'author-1',
        'selected_provider_id': null,
        'users': {'name': 'Ada', 'phone_number': '+254700000000'},
        'applications': [
          {'id': 'a1', 'post_id': 'j1', 'applicant_user_id': 'u2'},
        ],
      });

      final post = job.toPostModel();

      expect(post.id, 'j1');
      expect(post.type, PostType.job);
      // Ownership must survive the projection — the owner check on the detail
      // screen reads authorUserId, and a dropped one reopens the whole bug.
      expect(post.authorUserId, 'author-1');
      expect(post.status, 'open');
      expect(post.price, 25000);
      expect(post.employmentType, EmploymentType.fullTime);
      expect(post.authorHasPhone, isTrue);
      expect(post.applications.length, 1);
      expect(
        isListingOwner(authorUserId: post.authorUserId, viewerUserId: 'author-1'),
        isTrue,
      );
    });

    test('offline cache round-trip keeps status, price and author', () {
      final job = JobModel.fromJson({
        'id': 'j1',
        'title': 'Rider',
        'price': 25000,
        'location': 'Nairobi',
        'status': 'assigned',
        'author_user_id': 'author-1',
        'selected_provider_id': 'u2',
        'users': {'name': 'Ada'},
      });

      final restored = JobModel.fromJson(job.toCacheMap());

      expect(restored.authorUserId, 'author-1');
      expect(restored.status, 'assigned');
      expect(restored.selectedProviderUserId, 'u2');
      expect(restored.price, 25000);
      // Regression: the cache map omitted 'price', so every cached job came
      // back as "KES 0" on relaunch.
      expect(restored.pay, contains('25000'));
    });
  });
}
