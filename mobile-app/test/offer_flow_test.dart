import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/category_schema.dart';
import 'package:help24/models/offer_flow.dart';
import 'package:help24/models/post_model.dart' show Urgency;

/// Posting Redesign R-2: the offer-journey rules.
void main() {
  group('Availability (urgency column stays constant for offers)', () {
    test('offers never write urgent — the column is a constant flexible', () {
      expect(kOfferUrgency, Urgency.flexible);
    });

    test('wire values are stable', () {
      expect(OfferAvailability.availableNow.wireValue, 'available_now');
      expect(OfferAvailability.thisWeek.wireValue, 'this_week');
      expect(OfferAvailability.byAppointment.wireValue, 'by_appointment');
    });

    test('every option has a label and subtitle', () {
      for (final a in OfferAvailability.values) {
        expect(a.label, isNotEmpty);
        expect(a.subtitle, isNotEmpty);
      }
    });
  });

  group('Step sequence', () {
    test('with questions: category → title → questions → price → availability → location → photos → description → preview', () {
      expect(offerSteps(includeQuestions: true), const [
        OfferStepId.category,
        OfferStepId.title,
        OfferStepId.questions,
        OfferStepId.price,
        OfferStepId.availability,
        OfferStepId.location,
        OfferStepId.photos,
        OfferStepId.description,
        OfferStepId.preview,
      ]);
    });

    test('without questions the flow simply skips that screen', () {
      final steps = offerSteps(includeQuestions: false);
      expect(steps, isNot(contains(OfferStepId.questions)));
      expect(steps.first, OfferStepId.category);
      expect(steps.last, OfferStepId.preview);
      expect(steps.length, offerSteps(includeQuestions: true).length - 1);
    });

    test('price is asked before availability (capability → price → logistics)', () {
      final steps = offerSteps(includeQuestions: true);
      expect(steps.indexOf(OfferStepId.price), lessThan(steps.indexOf(OfferStepId.availability)));
      expect(steps.indexOf(OfferStepId.category), lessThan(steps.indexOf(OfferStepId.questions)));
    });
  });

  group('Starting price (required for sellers)', () {
    test('valid amounts parse', () {
      expect(offerStartingPrice(' 500 '), 500);
      expect(offerStartingPrice('799.5'), 799.5);
    });

    test('empty, garbage, zero and negative are rejected (null)', () {
      expect(offerStartingPrice(''), isNull);
      expect(offerStartingPrice('abc'), isNull);
      expect(offerStartingPrice('0'), isNull);
      expect(offerStartingPrice('-100'), isNull);
    });
  });

  group('Attribute composition', () {
    final schema = QuestionSchema.tryParse({
      'steps': [
        {'key': 'services', 'question': 'What services do you offer?', 'type': 'multiselect',
         'applies_to': ['offer'],
         'options': [
           {'value': 'leak_repair', 'label': 'Leak repair'},
           {'value': 'installation', 'label': 'Installation'},
         ]},
        {'key': 'need', 'question': 'What do you need help with?', 'type': 'select', 'required': true,
         'applies_to': ['request', 'job'],
         'options': [
           {'value': 'leak', 'label': 'Leak'},
         ]},
      ],
    })!;

    test('offer answers merge with the reserved _availability key', () {
      final pruned = schema.prunedAnswers(
        answers: {'services': ['leak_repair']},
        postType: 'offer',
        emergency: false,
      );
      final attrs = composeOfferAttributes(
        prunedSchemaAnswers: pruned,
        availability: OfferAvailability.availableNow,
      );
      expect(attrs, {
        'services': ['leak_repair'],
        '_availability': 'available_now',
      });
    });

    test('requester-voiced answers never leak into an offer post', () {
      final pruned = schema.prunedAnswers(
        answers: {'need': 'leak', 'services': ['installation']},
        postType: 'offer',
        emergency: false,
      );
      expect(pruned.containsKey('need'), isFalse);
      expect(pruned['services'], ['installation']);
    });

    test('offer-voiced steps are invisible to requests (applies_to)', () {
      final visible = schema.visibleSteps(answers: {}, postType: 'request', emergency: false);
      expect(visible.map((s) => s.key), ['need']);
      final offerVisible = schema.visibleSteps(answers: {}, postType: 'offer', emergency: false);
      expect(offerVisible.map((s) => s.key), ['services']);
    });

    test('no availability chosen → no reserved key (defensive)', () {
      expect(composeOfferAttributes(prunedSchemaAnswers: const {}, availability: null), isEmpty);
    });

    test('reserved key cannot collide with schema keys', () {
      expect(kAvailabilityAttributeKey.startsWith('_'), isTrue);
    });
  });
}
