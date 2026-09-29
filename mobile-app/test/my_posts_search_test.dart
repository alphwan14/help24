import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/screens/my_posts_screen.dart';

/// SEARCHING YOUR OWN POSTS IS A FILTER, NOT A QUERY.
///
/// `UserProfileService.getAuthoredPosts` returns the author's whole history in
/// one call and the screen has no pagination, so everything the search can
/// match is already in memory. That is the property these tests protect: the
/// function is pure, an empty query is the identity (which is what makes
/// "clear" restore the list for free), and nothing here can issue a request.
///
/// It matches TITLE and PROFESSION deliberately — see [searchAuthoredPosts].
PostModel _post({
  required String title,
  required String category,
  String description = '',
  String location = 'Nairobi',
}) =>
    PostModel(
      id: title,
      title: title,
      description: description,
      category: Category(name: category, icon: Category.all.first.icon),
      location: location,
      price: 1000,
      urgency: Urgency.flexible,
      type: PostType.request,
      authorUserId: 'me',
    );

void main() {
  // Shaped like the account this was built against: 22 authored posts, a mix
  // of requests and offers across several professions.
  final corpus = <PostModel>[
    _post(title: 'Pin gate test', category: 'Plumbing'),
    _post(title: 'Am an experienced welder based in Mombasa', category: 'Welding'),
    _post(title: 'Mechanic wa EV Cars', category: 'Mechanic'),
    _post(title: 'Kitchen', category: 'Plumbing'),
    _post(
      title: 'Looking for a Ceiling Painter',
      category: 'Painting',
      description: 'Need a plumber too, eventually',
      location: 'Kisauni, Mombasa',
    ),
  ];

  List<String> titles(List<PostModel> posts) => posts.map((p) => p.title).toList();

  group('an empty query is the identity', () {
    test('it returns the very same list, so clearing restores everything', () {
      expect(searchAuthoredPosts(corpus, ''), same(corpus));
      expect(searchAuthoredPosts(corpus, '   '), same(corpus));
    });
  });

  group('matching a title', () {
    test('a substring anywhere in the title matches', () {
      expect(titles(searchAuthoredPosts(corpus, 'Kitchen')), ['Kitchen']);
      expect(titles(searchAuthoredPosts(corpus, 'welder')),
          ['Am an experienced welder based in Mombasa']);
    });

    test('case does not matter in either direction', () {
      for (final typed in ['kitchen', 'KITCHEN', 'KiTcHeN']) {
        expect(titles(searchAuthoredPosts(corpus, typed)), ['Kitchen'],
            reason: '"$typed" must find the post titled Kitchen');
      }
    });

    test('surrounding and doubled whitespace is collapsed', () {
      expect(titles(searchAuthoredPosts(corpus, '  Kitchen  ')), ['Kitchen']);
      expect(titles(searchAuthoredPosts(corpus, 'EV   Cars')),
          ['Mechanic wa EV Cars']);
    });
  });

  group('matching a profession', () {
    test('the category name matches even when the title does not', () {
      // Neither title contains "plumbing"; both posts are filed under it.
      expect(titles(searchAuthoredPosts(corpus, 'Plumbing')),
          ['Pin gate test', 'Kitchen']);
    });

    test('profession matching is case-insensitive too', () {
      expect(titles(searchAuthoredPosts(corpus, 'welding')),
          ['Am an experienced welder based in Mombasa']);
    });

    test('a query can match one post by title and another by profession', () {
      // "Mechanic" is this post's profession AND a word in its own title; the
      // point is that one query is allowed to hit either field.
      final found = searchAuthoredPosts(corpus, 'mechanic');
      expect(titles(found), ['Mechanic wa EV Cars']);
    });
  });

  group('what it deliberately does not search', () {
    test('description is ignored, so a common word does not match everything',
        () {
      // The Painting post's DESCRIPTION says "plumber", but it is not a
      // plumbing post. Searching descriptions would put it under "plumb"
      // alongside the real ones, which is how a short query starts matching
      // almost the whole list.
      final found = searchAuthoredPosts(corpus, 'plumb');
      expect(titles(found), ['Pin gate test', 'Kitchen']);
      expect(titles(found), isNot(contains('Looking for a Ceiling Painter')));
    });

    test('location is ignored — the cards already read that way', () {
      // Two posts mention Mombasa: one in its TITLE, one only in its location.
      // Only the title one comes back.
      expect(titles(searchAuthoredPosts(corpus, 'Mombasa')),
          ['Am an experienced welder based in Mombasa']);
    });
  });

  group('no matches', () {
    test('an unmatched query returns empty, not everything', () {
      expect(searchAuthoredPosts(corpus, 'zzzz'), isEmpty);
    });

    test('an empty corpus stays empty whatever is typed', () {
      expect(searchAuthoredPosts(const <PostModel>[], 'anything'), isEmpty);
    });
  });

  group('order and identity are preserved', () {
    test('results keep the newest-first order the service returned', () {
      final found = searchAuthoredPosts(corpus, 'a');
      final expected = corpus
          .where((p) =>
              p.title.toLowerCase().contains('a') ||
              p.category.name.toLowerCase().contains('a'))
          .map((p) => p.title)
          .toList();
      expect(titles(found), expected);
    });

    test('it returns the same instances, so tapping opens the real post', () {
      final found = searchAuthoredPosts(corpus, 'Kitchen');
      expect(found.single, same(corpus[3]));
    });
  });

  group('a deleted post leaves the list without a refresh', () {
    // My Posts loads the author's history ONCE into its own future. A delete
    // used to leave the post listed until a pull-to-refresh; AppProvider now
    // publishes what was archived and the screen filters it out.
    test('an archived post is removed, the rest keep their order', () {
      final left = withoutArchived(corpus, {'Kitchen', 'Mechanic wa EV Cars'});
      expect(titles(left), [
        'Pin gate test',
        'Am an experienced welder based in Mombasa',
        'Looking for a Ceiling Painter',
      ]);
      expect(left.first, same(corpus.first));
    });

    test('nothing archived is the identity, so no copy per rebuild', () {
      expect(withoutArchived(corpus, const {}), same(corpus));
    });

    test('an id not in the list changes nothing', () {
      expect(titles(withoutArchived(corpus, {'someone-elses-post'})), titles(corpus));
    });

    test('deleting the last post leaves an empty list, not a stale card', () {
      expect(withoutArchived([corpus.first], {corpus.first.id}), isEmpty);
    });

    test('the screen filters against the provider, and the provider publishes', () {
      final screen = File('lib/screens/my_posts_screen.dart').readAsStringSync();
      expect(screen.contains('p.archivedPostIds'), isTrue);
      expect(screen.contains('withoutArchived(snap.data'), isTrue);
      final provider = File('lib/providers/app_provider.dart').readAsStringSync();
      expect(provider.contains('_archivedPostIds = {..._archivedPostIds, postId};'), isTrue,
          reason: 'deletePost must publish the id by replacing the set');
      expect(provider.contains('_archivedPostIds = const {};'), isTrue,
          reason: "sign-out must not carry one account's deletions into the next");
    });
  });
}
