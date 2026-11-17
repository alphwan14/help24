import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/screens/my_posts_screen.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/utils/post_ownership.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Fixing a listing posted as the wrong kind, after the fact.
///
/// The database (migration 145) is the authority on whether the author may
/// switch; these pin the app's side of it: when the control is offered, what
/// the refusals say, and that the change shows everywhere at once.
PostModel _post(String id, {PostType type = PostType.request}) => PostModel(
      id: id,
      title: 'Edger here anyone in need of plumber',
      description: '',
      category: Category.fromName('Plumbing'),
      location: 'Muhoroni',
      price: 0,
      urgency: Urgency.flexible,
      type: type,
    );

void main() {
  group('when the author is offered the switch', () {
    test('a request becomes an offer, and an offer a request', () {
      expect(
        ownerTypeSwitchTarget(type: PostType.request, status: 'open', applicationCount: 0),
        PostType.offer,
      );
      expect(
        ownerTypeSwitchTarget(type: PostType.offer, status: 'open', applicationCount: 0),
        PostType.request,
      );
    });

    test('never for a job: it has its own form', () {
      expect(
        ownerTypeSwitchTarget(type: PostType.job, status: 'open', applicationCount: 0),
        isNull,
      );
    });

    test('not once someone has responded, been chosen, or it closed', () {
      expect(
        ownerTypeSwitchTarget(type: PostType.request, status: 'open', applicationCount: 1),
        isNull,
      );
      expect(
        ownerTypeSwitchTarget(
          type: PostType.request,
          status: 'open',
          selectedProviderId: 'provider-1',
          applicationCount: 0,
        ),
        isNull,
      );
      for (final status in ['assigned', 'completed', 'disputed', 'cancelled']) {
        expect(
          ownerTypeSwitchTarget(type: PostType.request, status: status, applicationCount: 0),
          isNull,
          reason: status,
        );
      }
    });
  });

  group('the author is offered a CORRECTION, never a free switch', () {
    PostType? correction(PostType type, String title, {int applications = 0}) =>
        ownerTypeCorrection(
          type: type,
          status: 'open',
          applicationCount: applications,
          title: title,
        );

    test('a clear offer is not offered "Change to a request"', () {
      // The owner turned this into a request on 1.0.13 Patch 1; it is an offer.
      expect(correction(PostType.offer, 'Am an experienced welder based in Mombasa'), isNull);
    });

    test('a mislabelled post is offered the kind its words say', () {
      expect(correction(PostType.request, 'Edger here anyone in need of plumber'), PostType.offer);
      // ...which is how the owner's test switch is undone.
      expect(correction(PostType.request, 'Am an experienced welder based in Mombasa'), PostType.offer);
      expect(correction(PostType.offer, 'Looking for a plumber in Westlands'), PostType.request);
    });

    test('neutral words are offered nothing (an admin can still reclassify)', () {
      expect(correction(PostType.request, 'Plumbing'), isNull);
      expect(correction(PostType.offer, 'Kitchen sink repair'), isNull);
    });

    test('the listing rules still come first', () {
      expect(
        correction(PostType.request, 'Edger here anyone in need of plumber', applications: 1),
        isNull,
      );
    });

    test('the description counts too', () {
      expect(
        ownerTypeCorrection(
          type: PostType.request,
          status: 'open',
          applicationCount: 0,
          title: 'Plumbing',
          description: 'We offer repairs, call us',
        ),
        PostType.offer,
      );
    });
  });

  group('the words for each kind', () {
    test('say who needs what', () {
      expect(PostType.request.kindLabel, 'Needs help');
      expect(PostType.offer.kindLabel, 'Offering');
      expect(PostType.job.kindLabel, 'Hiring');
      expect(_post('a', type: PostType.offer).typeDisplayLabel, 'Offering');
    });
  });

  group('the refusals read as sentences', () {
    String say(String raw) => ErrorMapper.toMessage(
          PostgrestException(message: raw, code: '42501'),
          context: ErrorContext.save,
        );

    test('someone already responded', () {
      final m = say('HELP24_TYPE_CHANGE_REFUSED: people have already responded to it');
      expect(m, contains('already responded'));
      expect(m, contains('delete it and post again'));
    });

    test('a provider was chosen: a type rule, not a hiring problem', () {
      final m = say('HELP24_TYPE_CHANGE_REFUSED: this listing already has a provider');
      expect(m, 'It already has a provider, so its type stays.');
      expect(m, isNot(contains('chosen provider')));
    });

    test('closed, and a job', () {
      expect(say('HELP24_TYPE_CHANGE_REFUSED: this listing is closed'),
          'It is closed, so its type stays.');
      expect(say('HELP24_TYPE_CHANGE_REFUSED: only a request and an offer can be switched'),
          contains('A job keeps its type'));
    });

    test('an unverified care offer still reads as the vetting rule', () {
      final m = say('HELP24_VERIFICATION_REQUIRED: offering this work needs a Care check');
      expect(m, contains('Care check'));
    });
  });

  group('My Posts shows the edit', () {
    test('the edited row replaces the loaded one, in place', () {
      final loaded = [_post('a'), _post('b'), _post('c')];
      final edited = {'b': _post('b', type: PostType.offer)};
      final shown = withEdited(loaded, edited);
      expect(shown.map((p) => p.id), ['a', 'b', 'c']);
      expect(shown[1].type, PostType.offer);
    });

    test('nothing edited here returns the same list', () {
      final loaded = [_post('a')];
      expect(identical(withEdited(loaded, const {}), loaded), isTrue);
      expect(identical(withEdited(loaded, {'z': _post('z')}), loaded), isTrue);
    });

    test('the screen merges the edits, and the provider publishes them', () {
      final screen = File('lib/screens/my_posts_screen.dart').readAsStringSync();
      expect(screen.contains('p.editedPosts'), isTrue);
      expect(RegExp(r'withEdited\(\s*withoutArchived\(').hasMatch(screen), isTrue);
      final provider = File('lib/providers/app_provider.dart').readAsStringSync();
      expect(provider.contains('_editedPosts = {..._editedPosts, updated.id: updated};'), isTrue,
          reason: 'applyPostEdit must publish by replacing the map');
      expect(provider.contains('_editedPosts = const {};'), isTrue,
          reason: "sign-out must not carry one account's edits into the next");
    });
  });

  group('the composer puts the keyboard away when the step changes', () {
    // Seen on the S20+ with 1.0.13 Patch 1: "Post as an offer" jumped from the
    // title to the next question and the title's keyboard stayed up over it.
    final composer = File('lib/screens/post_screen.dart').readAsStringSync();

    test('the step setter unfocuses', () {
      expect(
        RegExp(r'set _currentStep\(int value\) \{\s*if \(value != _step\) FocusManager\.instance\.primaryFocus\?\.unfocus\(\);')
            .hasMatch(composer),
        isTrue,
      );
    });

    test('nothing writes the step around the setter', () {
      // The declaration and the setter's own write, and nothing else.
      expect(RegExp(r'\b_step\s*(=|\+\+|--|\+=|-=)').allMatches(composer).length, 2);
    });
  });

  group('the request being posted', () {
    final composer = File('lib/screens/post_screen.dart').readAsStringSync();
    final submit = composer.substring(composer.indexOf('Future<void> _submitPost() async {'));

    test('swaps the form for the finding-help view at the tap, not after the server', () {
      expect(composer.contains('FindingHelpView('), isTrue);
      final starts = submit.indexOf('_findingHelp = true;');
      final saves = submit.indexOf('await AuthService.ensureCurrentUserInSupabase()');
      expect(starts, greaterThan(-1));
      expect(saves, greaterThan(starts), reason: 'the mark must start before the work does');
    });

    test('turns "live" the moment the server confirms, with nothing added', () {
      expect(submit.contains('setState(() => _postedRequest = request)'), isTrue);
      expect(RegExp(r'Future\.delayed|Timer\(').hasMatch(submit), isFalse);
    });

    test('a failure brings the form back', () {
      final failure = submit.substring(submit.indexOf('} catch (e) {'));
      expect(failure.contains('_findingHelp = false;'), isTrue);
    });

    test('the shell still learns that a listing was created', () {
      expect(RegExp(r'void _closeAfterPosting\(\) \{[\s\S]{0,300}pop\(true\)').hasMatch(composer), isTrue);
      expect(RegExp(r'pushReplacement\([\s\S]{0,200}result: true').hasMatch(composer), isTrue);
    });

    test('the upload reports its start, so "photo 1 of n" is true while it goes up', () {
      final service = File('lib/services/post_service.dart').readAsStringSync();
      expect(service.contains('onImageUploadProgress?.call(0, imageFiles.length);'), isTrue);
    });
  });
}
