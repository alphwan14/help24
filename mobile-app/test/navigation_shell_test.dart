import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE BOTTOM BAR HOLDS PLACES YOU CAN BE, AND NOTHING ELSE.
///
/// WHAT WENT WRONG
/// ---------------
/// The bar had five slots but the app had four tabs. The centre slot was
/// "Post", which is an ACTION: tapping it set a boolean that swapped the body
/// and hid the bar. Because a nav index no longer matched a stack index,
/// `HomeScreen` carried translation in both directions —
/// `_currentIndex = index > 2 ? index - 1 : index` on the way in and
/// `_getNavIndex() => _currentIndex >= 2 ? _currentIndex + 1 : _currentIndex`
/// on the way out. Two mappings, kept in sync by hand, for a slot that was
/// never a destination.
///
/// The fourth tab was Jobs, which was a *filter over the corpus Discover
/// already serves* (`FeedScope.jobs` — one wire value, one request) holding one
/// listing, while the work the user was actually doing had no home at all.
///
/// These are source guards rather than widget tests on purpose: what they pin
/// is the SHAPE of the shell, and a widget test of `HomeScreen` would need
/// Firebase, Supabase, presence polling and the launch sequence to build at
/// all. The contract is cheap to state and expensive to rediscover.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('the bar holds four destinations', () {
    test('Post is not one of them', () {
      final nav = read('lib/widgets/custom_bottom_nav.dart');
      // Matches the DECLARATION, not any mention — the comment explaining why
      // it went is allowed to name it.
      expect(nav.contains('class _CenterButton'), isFalse,
          reason: 'the centre slot was an action wearing a tab\'s clothes');
      // The four that remain.
      for (final label in const [
        "label: 'Discover'",
        "label: 'Activity'",
        "label: 'Messages'",
        "label: 'Profile'",
      ]) {
        expect(nav.contains(label), isTrue, reason: 'missing $label');
      }
      expect(nav.contains("label: 'Jobs'"), isFalse,
          reason: 'Jobs is a scope in Discover, not a destination');
    });

    test('nav index and stack index are the same number', () {
      final home = read('lib/screens/home_screen.dart');
      expect(home.contains('int _getNavIndex()'), isFalse,
          reason: 'the two index spaces collapsed into one');
      expect(home.contains('_currentIndex = index > 2'), isFalse);
      expect(home.contains('currentIndex: _currentIndex'), isTrue);
    });

    test('the four tabs are stacked in nav order', () {
      final home = read('lib/screens/home_screen.dart');
      final order = ['DiscoverScreen()', 'ActivityScreen()', 'MessagesScreen()', 'ProfileScreen()'];
      var cursor = -1;
      for (final screen in order) {
        final at = home.indexOf(screen);
        expect(at, greaterThan(cursor),
            reason: '$screen is out of order in the IndexedStack; the bar '
                'indexes into this list directly now');
        cursor = at;
      }
      expect(home.contains('JobsScreen()'), isFalse);
    });
  });

  group('posting is an action', () {
    test('it floats, and only over the surfaces you browse', () {
      final home = read('lib/screens/home_screen.dart');
      expect(home.contains('floatingActionButton'), isTrue);
      // Hidden on Messages and Profile, where a compose button has nothing to
      // do with what is on screen.
      expect(home.contains('_currentIndex > 1'), isTrue);
    });

    test('every surface it floats over leaves room for it', () {
      // A FAB covers the last row of a list unless the list says otherwise.
      // These are the scrolling surfaces it can float over.
      for (final path in const [
        'lib/screens/discover_screen.dart',
        'lib/screens/my_posts_screen.dart',
        'lib/screens/saved_screen.dart',
        'lib/screens/my_applications_screen.dart',
      ]) {
        expect(read(path).contains('AppSpace.fabClearance'), isTrue,
            reason: '$path scrolls under the compose FAB');
      }
    });
  });

  group('the composer is a route, not a body swap', () {
    // ── WHAT THIS REPLACES ────────────────────────────────────────────────
    // `HomeScreen` held `bool _showPostScreen` and rendered the composer in
    // place of the tab stack. Three things followed from that, and all three
    // are what these tests pin shut:
    //
    //   * back ABANDONED the form from any step, while the header's own back
    //     arrow went back ONE step — two controls, one gesture apart, doing
    //     opposite things to a half-filled post with photos attached;
    //   * the composer had no navigator of its own to push into;
    //   * the FAB, the bottom bar and the shell's PopScope each carried a
    //     `_showPostScreen` term, because the shell had to keep pretending the
    //     screen on top of it was not there.

    test('the shell pushes it instead of rendering it', () {
      final home = read('lib/screens/home_screen.dart');
      expect(home.contains('MaterialPageRoute(builder: (_) => const PostScreen())'),
          isTrue,
          reason: 'the composer is pushed, so it owns its own back stack');
      // The boolean is gone as a FIELD. The comments explaining why are free
      // to name it.
      expect(home.contains('bool _showPostScreen'), isFalse);
    });

    test('the shell chrome no longer knows the composer exists', () {
      final home = read('lib/screens/home_screen.dart');
      // A route covers the Scaffold, so nothing has to be hidden by hand.
      expect(home.contains('bottomNavigationBar: _showPostScreen'), isFalse);
      expect(home.contains('canPop: !_showPostScreen'), isFalse);
      expect(home.contains('canPop: _currentIndex == 0'), isTrue,
          reason: "the shell's back rule is about tabs and nothing else");
    });

    test('where you land depends on whether you actually posted', () {
      final home = read('lib/screens/home_screen.dart');
      final post = read('lib/screens/post_screen.dart');
      expect(post.contains('Navigator.of(context).pop(true)'), isTrue,
          reason: 'a created listing pops with true');
      expect(home.contains('if (posted == true) _currentIndex = 0'), isTrue,
          reason: 'posting sends the author to Discover to watch it arrive; '
              'cancelling returns them to the tab they came from, which the '
              'body swap could not do because it never knew which that was');
    });

    test('system back walks the steps; the cross closes', () {
      final post = read('lib/screens/post_screen.dart');
      expect(post.contains('canPop: _currentStep == 0'), isTrue,
          reason: 'back must mean what the visible back arrow means');
      expect(post.contains('setState(() => _currentStep--)'), isTrue);
      // An imperative pop is NOT intercepted by PopScope, which is the whole
      // reason the cross can still mean "I am done here".
      expect(post.contains('onTap: () => Navigator.of(context).pop()'), isTrue);
      expect(post.contains('onComplete'), isFalse,
          reason: 'the callback the body swap needed is gone; a route pops');
    });

    test('Discover is told it is covered while the composer is up', () {
      // A ranking that lands behind a full-screen route must be installed
      // quietly, not spliced into a feed nobody can see.
      final home = read('lib/screens/home_screen.dart');
      expect(home.contains('setDiscoverVisible(!_composerOpen && _currentIndex == 0)'),
          isTrue);
      expect(home.contains('setState(() => _composerOpen = true)'), isTrue);
    });
  });

  group('Activity hosts existing screens rather than reimplementing them', () {
    test('it embeds them without a second app bar', () {
      final activity = read('lib/screens/activity_screen.dart');
      expect(activity.contains('embedded: true'), isTrue);
      for (final path in const [
        'lib/screens/my_posts_screen.dart',
        'lib/screens/saved_screen.dart',
        'lib/screens/my_applications_screen.dart',
      ]) {
        expect(read(path).contains('if (widget.embedded) return body'), isTrue,
            reason: '$path must be able to render without its Scaffold');
      }
    });

    test('the three scopes are one question asked from either side', () {
      // My posts is work you are PAYING for, Applied is work you are asking to
      // be PAID for, Saved is neither yet. Help24 has no buyer/seller mode, so
      // they belong on one tab — and "what have I applied to" was the one of
      // the three that had no screen anywhere in the product.
      final activity = read('lib/screens/activity_screen.dart');
      for (final label in const [
        "label: 'My posts'",
        "label: 'Applied'",
        "label: 'Saved'",
      ]) {
        expect(activity.contains(label), isTrue, reason: 'missing $label');
      }
      expect(activity.contains('MyApplicationsScreen('), isTrue);
    });

    test('there is no second notification bell', () {
      // Discover's header owns it. Two bells on two tabs is one control with
      // two homes and two unread counts to keep agreeing — the same repetition
      // the "My Activity" block in Profile turned out to be.
      final activity = read('lib/screens/activity_screen.dart');
      expect(activity.contains('NotificationBadge('), isFalse);
      expect(read('lib/screens/discover_screen.dart').contains('NotificationBadge('),
          isTrue,
          reason: 'it has to live somewhere, and Discover is where it was');
    });
  });
}
