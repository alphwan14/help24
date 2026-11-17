import 'package:flutter_test/flutter_test.dart';
import 'package:help24/config/post_intent_phrases.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/utils/post_intent.dart';

/// The composer's "this sounds like the other kind" check.
///
/// It only ever SUGGESTS, so the cost of a wrong answer is one dismissible
/// line; the cost of a missing answer is the mislabelled feed this exists to
/// fix. These cases are real phrasing, in English, Kiswahili and Sheng.
/// Add one for every phrase that fixes a real post.
void main() {
  group('the post that started it', () {
    test('"Edger here anyone in need of plumber" reads as an offer', () {
      expect(
        readPostIntent('Edger here anyone in need of plumber').leaning,
        PostType.offer,
      );
      expect(
        suggestedPostType(
          chosen: PostType.request,
          title: 'Edger here anyone in need of plumber',
        ),
        PostType.offer,
      );
    });
  });

  group('"Help24 test I am a plumber please ignore" (the 2026-11-17 phone test)', () {
    const title = 'Help24 test I am a plumber please ignore';

    test('reads as an offer, from "i am a" in the middle of the title', () {
      final reading = readPostIntent(title);
      expect(reading.offerPhrases, ['i am a']);
      expect(reading.requestPhrases, isEmpty);
      expect(reading.leaning, PostType.offer);
      expect(suggestedPostType(chosen: PostType.request, title: title), PostType.offer);
    });

    test('anywhere: the same words in the description count the same', () {
      expect(
        suggestedPostType(chosen: PostType.request, title: 'Help24 test', description: 'I am a plumber, please ignore'),
        PostType.offer,
      );
    });

    test('in any case and with any punctuation', () {
      for (final text in [
        'HELP24 TEST I AM A PLUMBER PLEASE IGNORE',
        'help24 test i am a plumber please ignore',
        'Help24 test: I am a plumber!! Please ignore.',
        'Help24 test (I am a plumber) please ignore',
        'Help24 test Iam a plumber please ignore',
      ]) {
        expect(suggestedPostType(chosen: PostType.request, title: text), PostType.offer, reason: text);
      }
    });

    test('whole words, so it never fires inside another word', () {
      expect(readPostIntent('Drama class for kids').offerPhrases, isEmpty, reason: '"am a" inside "drama a"');
      expect(readPostIntent('Kama sink imevuja').offerPhrases, isEmpty, reason: '"am a" inside "kama"');
      expect(readPostIntent('Needle work repair').requestPhrases, isEmpty, reason: '"need" inside "needle"');
    });
  });

  group('offers', () {
    for (final text in [
      'I am a plumber in Kisumu',
      "I'm an electrician, call me",
      'Im a fundi, available weekends',
      'We offer house cleaning',
      'Fundi wa stima, niko na experience',
      'Tunatoa huduma za usafi',
      'Mimi ni fundi wa magari',
      'Natafuta kazi ya plumbing',
      'Looking for work as a driver',
      'Kama unahitaji fundi nipigie',
      'Do you need a cleaner? Contact me',
      // A provider looking for CLIENTS is not asking for help.
      'Mechanic looking for clients in Thika',
      'Natafuta wateja wa kushona nguo',
      // A real listing, switched to a request by its owner as a test.
      'Am an experienced welder based in Mombasa',
    ]) {
      test(text, () => expect(readPostIntent(text).leaning, PostType.offer));
    }
  });

  group('requests', () {
    for (final text in [
      'Looking for a plumber in Westlands',
      'Need someone to fix my sink',
      'Natafuta fundi wa fridge',
      'Nahitaji cleaner kesho',
      'I need a mechanic urgently',
      'Can someone help me move on Saturday',
      'Fridge imeharibika, kuna fundi?',
      'Plumber wanted in Kilimani',
      'Fundi wa stima anahitajika',
      'I am in need of a tutor',
    ]) {
      test(text, () => expect(readPostIntent(text).leaning, PostType.request));
    }
  });

  group('says nothing when it cannot tell', () {
    for (final text in [
      'Plumbing',
      'Kitchen sink repair',
      // A stray offer word in a request is a tie, and a tie is silent.
      'I am a mum looking for a nanny',
      'Need an experienced plumber available today',
      '',
      '!!!',
    ]) {
      test('"$text"', () => expect(readPostIntent(text).leaning, isNull));
    }
  });

  group('matching', () {
    test('ignores case and punctuation, and reads curly apostrophes', () {
      expect(readPostIntent('I’M A PLUMBER!!!').offerPhrases, ["i'm a"]);
      expect(readPostIntent('anyone,in-need of: plumber').offerPhrases, ['anyone in need of']);
    });

    test('matches whole words only', () {
      // "natafuta" must not be found inside "tunatafuta" or "anatafuta".
      expect(readPostIntent('anatafuta').requestPhrases, isEmpty);
      // "available" is a word, not a substring of "unavailable".
      expect(readPostIntent('unavailable').offerPhrases, isEmpty);
    });

    test('the longer phrase claims its words', () {
      final reading = readPostIntent('anyone in need of a plumber');
      expect(reading.offerPhrases, ['anyone in need of']);
      expect(reading.requestPhrases, isEmpty, reason: '"in need of" is inside the offer phrase');
      expect(readPostIntent('natafuta kazi').requestPhrases, isEmpty);
    });
  });

  group('suggestions', () {
    test('only for the OTHER kind', () {
      expect(suggestedPostType(chosen: PostType.offer, title: 'I am a plumber'), isNull);
      expect(suggestedPostType(chosen: PostType.offer, title: 'Looking for a plumber'),
          PostType.request);
    });

    test('read the description as well as the title', () {
      expect(
        suggestedPostType(
          chosen: PostType.request,
          title: 'Plumbing',
          description: 'We offer repairs, call us',
        ),
        PostType.offer,
      );
    });

    test('carry the words they rest on', () {
      final s = suggestPostType(
        chosen: PostType.request,
        title: 'I am a plumber',
        description: 'We offer repairs, call us',
      )!;
      expect(s.type, PostType.offer);
      expect(s.evidence, {'i am a', 'we offer', 'call us'});
    });

    test('"Keep as a request" quiets those words, not the rest of the post', () {
      final kept = suggestPostType(chosen: PostType.request, title: 'I am a plumber')!;
      bool shows(String title, String description, {PostType chosen = PostType.request}) =>
          showPostIntentNudge(
            suggestion: suggestPostType(chosen: chosen, title: title, description: description),
            chosen: chosen,
            keptType: PostType.request,
            keptEvidence: kept.evidence,
          );
      // Before anything is kept, it shows.
      expect(
        showPostIntentNudge(suggestion: kept, chosen: PostType.request),
        isTrue,
      );
      // The same words, or the same words typed on: quiet.
      expect(shows('I am a plumber', ''), isFalse);
      expect(shows('I am a plumber in Kisumu', ''), isFalse);
      // New words that read as an offer, in the description: once more.
      expect(shows('I am a plumber', 'We offer repairs'), isTrue);
      // Nothing to suggest: nothing shows.
      expect(shows('Looking for a plumber', ''), isFalse);
    });

    test('never for a job, and never into one', () {
      expect(suggestedPostType(chosen: PostType.job, title: 'I am a plumber'), isNull);
      expect(suggestedPostType(chosen: PostType.job, title: 'Looking for a plumber'), isNull);
    });

    test('are worded as a question, without an em dash', () {
      expect(postIntentNudge(PostType.offer),
          "This sounds like you're offering a service. Post as an offer?");
      expect(postIntentNudge(PostType.request),
          'This sounds like you need help. Post as a request?');
      expect(postIntentSwitchLabel(PostType.offer), 'Post as an offer');
      expect(postIntentNudge(PostType.offer).contains('—'), isFalse);
    });
  });

  group('strength', () {
    test('a phrase outweighs a hint on the other side', () {
      // "fundi wa" names a trade, which requests do too.
      final reading = readPostIntent('Natafuta fundi wa fridge');
      expect(reading.requestScore, 2);
      expect(reading.offerScore, 1);
      expect(reading.leaning, PostType.request);
    });

    test('a phrase beats a hint for the same words', () {
      // "i need" (a phrase) and "need a" (a hint) overlap on "need".
      expect(readPostIntent('I need a mechanic').requestPhrases, ['i need']);
    });

    test('a request with a problem in it is still a request', () {
      expect(readPostIntent('Niko na shida ya maji, natafuta fundi').leaning, PostType.request);
    });
  });

  group('the phrase lists', () {
    final lists = {
      'kOfferPhrases': kOfferPhrases,
      'kOfferHints': kOfferHints,
      'kRequestPhrases': kRequestPhrases,
      'kRequestHints': kRequestHints,
    };

    test('are lower case, trimmed and not repeated', () {
      for (final entry in lists.entries) {
        for (final p in entry.value) {
          expect(p, p.toLowerCase(), reason: '${entry.key}: write "$p" in lower case');
          expect(p.trim(), p, reason: '${entry.key}: stray spaces in "$p"');
        }
        expect(entry.value.toSet().length, entry.value.length,
            reason: '${entry.key} lists a phrase twice');
      }
    });

    test('no phrase is on two lists', () {
      final seen = <String, String>{};
      for (final entry in lists.entries) {
        for (final p in entry.value) {
          expect(seen[p], isNull, reason: '"$p" is on ${seen[p]} and ${entry.key}');
          seen[p] = entry.key;
        }
      }
    });
  });
}
