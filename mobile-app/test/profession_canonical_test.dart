import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';

/// CANONICAL PROFESSION MATCHING, AGAINST THE REAL CORPUS.
///
/// THE DATA THIS IS BUILT ON
/// -------------------------
/// `SELECT category, count(*) FROM posts GROUP BY category` in production, on
/// 2026-09-05. Every stored value is Title Case, and two of them matter here:
///
///     Cleaning         2 posts
///     House Cleaning   1 post
///
/// So the four examples in the report are NOT one question:
///
///   * `Cleaning`, `cleaning`, `CLEANING` are three spellings of ONE profession
///     — the corpus holds exactly one of them, and the server matches
///     `category = ANY(...)` exactly, so the other two match zero rows unless
///     they are folded onto the stored spelling first. That is the bug.
///   * `House Cleaning` is a DIFFERENT profession that happens to contain the
///     word. Folding it into `Cleaning` would silently widen the filter and
///     return posts the user did not ask for. That is the bug the naive fix
///     ("just lower-case everything") introduces.
///
/// [Category.resolveFilterName] is therefore case-INSENSITIVE for matching and
/// case-PRESERVING for the answer: it returns the vocabulary's own spelling
/// when one matches, and the user's normalised text when none does — so a
/// genuinely new profession survives instead of being snapped onto a near-miss.
void main() {
  /// The corpus vocabulary, exactly as production spells it.
  const corpus = <String>[
    'Cleaning',
    'House Cleaning',
    'Plumbing',
    'Catering',
    'Nyama Choma',
    'Posho Mill Grinding',
    'IT',
  ];

  group('one profession, many spellings', () {
    test('every casing of "cleaning" resolves to the stored spelling', () {
      for (final typed in ['Cleaning', 'cleaning', 'CLEANING', '  cleaning  ']) {
        expect(
          Category.resolveFilterName(typed, corpus),
          'Cleaning',
          reason: '"$typed" must match the 2 posts stored as "Cleaning"',
        );
      }
    });

    test('an all-caps multi-word profession folds too', () {
      expect(Category.resolveFilterName('NYAMA CHOMA', corpus), 'Nyama Choma');
    });

    test('a two-letter profession cannot be TYPED, and is offered instead', () {
      // `normalizeCustomName` requires 3–40 characters, so 'IT' — a real
      // category with a post behind it — is not enterable as free text. That is
      // the length guard doing its job (two characters is far more often a
      // typo), and it is not a dead end: the suggestion list has no minimum, so
      // typing one letter offers the corpus spelling to tap.
      expect(Category.resolveFilterName('it', corpus), isNull);
      expect(Category.suggestFilterNames('i', corpus), contains('IT'));
    });
  });

  group('genuinely different professions stay different', () {
    test('"House Cleaning" is never folded into "Cleaning"', () {
      expect(Category.resolveFilterName('house cleaning', corpus),
          'House Cleaning');
      expect(Category.resolveFilterName('HOUSE CLEANING', corpus),
          'House Cleaning');
    });

    test('the two resolve to different filters, so they return different posts',
        () {
      final a = Category.resolveFilterName('cleaning', corpus);
      final b = Category.resolveFilterName('house cleaning', corpus);
      expect(a, isNot(b));
    });
  });

  group('a profession the corpus has never seen', () {
    test('survives as typed — not snapped onto a near-miss', () {
      // The real production example: this account's history holds "Charcoal
      // Seller", which is in no registry and on no post. It must come back as
      // the user wrote it, NOT folded onto 'Catering' or anything else that
      // merely shares letters. Casing is theirs to choose because there is no
      // stored spelling to agree with yet.
      expect(
        Category.resolveFilterName('charcoal seller', corpus),
        'charcoal seller',
      );
      expect(
        Category.resolveFilterName('Charcoal Seller', corpus),
        'Charcoal Seller',
      );
    });

    test('whitespace is collapsed even when nothing matches', () {
      // Trimmed and internally collapsed; case is left alone, because folding
      // it would invent a spelling the corpus never agreed to.
      expect(Category.resolveFilterName('   welding   ', corpus), 'welding');
      expect(
        Category.resolveFilterName('  charcoal    seller ', corpus),
        'charcoal seller',
      );
    });

    test('a too-short or letterless entry is refused', () {
      expect(Category.resolveFilterName('ab', corpus), isNull);
      expect(Category.resolveFilterName('123', corpus), isNull);
    });

    test('nothing usable resolves to nothing', () {
      expect(Category.resolveFilterName('', corpus), isNull);
      expect(Category.resolveFilterName('   ', corpus), isNull);
    });
  });

  group('suggestions offer the spellings that can actually match', () {
    test('"clea" offers both real professions, not a guess', () {
      final suggestions = Category.suggestFilterNames('clea', corpus);
      expect(suggestions, contains('Cleaning'));
      expect(suggestions, contains('House Cleaning'));
    });

    test('a prefix match is offered before a mere substring match', () {
      final suggestions = Category.suggestFilterNames('clea', corpus);
      // 'Cleaning' starts with the query; 'House Cleaning' only contains it.
      expect(suggestions.indexOf('Cleaning'),
          lessThan(suggestions.indexOf('House Cleaning')));
    });

    test('an empty query suggests nothing', () {
      expect(Category.suggestFilterNames('', corpus), isEmpty);
    });
  });
}
