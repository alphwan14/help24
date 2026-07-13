import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/category_schema.dart';
import 'package:help24/models/post_model.dart' show Urgency;
import 'package:help24/models/request_flow.dart';

/// Posting Redesign R-1: the request-journey rules.
void main() {
  group('When mapping (legacy urgency column stays truthful)', () {
    test('Right now → urgent + emergency mode', () {
      expect(RequestWhen.rightNow.urgency, Urgency.urgent);
      expect(RequestWhen.rightNow.isEmergency, isTrue);
      expect(RequestWhen.rightNow.wireValue, 'right_now');
    });

    test('Today → soon, not emergency', () {
      expect(RequestWhen.today.urgency, Urgency.soon);
      expect(RequestWhen.today.isEmergency, isFalse);
    });

    test('This week and Flexible both map to flexible (precision kept in _when)', () {
      expect(RequestWhen.thisWeek.urgency, Urgency.flexible);
      expect(RequestWhen.flexible.urgency, Urgency.flexible);
      expect(RequestWhen.thisWeek.wireValue, 'this_week');
      expect(RequestWhen.flexible.wireValue, 'flexible');
    });

    test('only Right now is an emergency', () {
      final emergencies = RequestWhen.values.where((w) => w.isEmergency);
      expect(emergencies, [RequestWhen.rightNow]);
    });
  });

  group('Step sequence', () {
    test('with questions: category → title → when → questions → budget → location → photos → details → preview', () {
      expect(requestSteps(includeQuestions: true), const [
        RequestStepId.category,
        RequestStepId.title,
        RequestStepId.when,
        RequestStepId.questions,
        RequestStepId.budget,
        RequestStepId.location,
        RequestStepId.photos,
        RequestStepId.details,
        RequestStepId.preview,
      ]);
    });

    test('without questions the flow simply skips that screen', () {
      final steps = requestSteps(includeQuestions: false);
      expect(steps, isNot(contains(RequestStepId.questions)));
      expect(steps.first, RequestStepId.category);
      expect(steps.last, RequestStepId.preview);
      expect(steps.length, requestSteps(includeQuestions: true).length - 1);
    });

    test('category comes before questions; when comes before questions (emergency trimming depends on it)', () {
      final steps = requestSteps(includeQuestions: true);
      expect(steps.indexOf(RequestStepId.category), lessThan(steps.indexOf(RequestStepId.questions)));
      expect(steps.indexOf(RequestStepId.when), lessThan(steps.indexOf(RequestStepId.questions)));
    });
  });

  group('Budget semantics', () {
    test('open to offers → price 0 regardless of text', () {
      expect(requestPrice(openToOffers: true, budgetText: '5000'), 0);
    });

    test('my budget parses the amount', () {
      expect(requestPrice(openToOffers: false, budgetText: ' 1500 '), 1500);
    });

    test('garbage or negative input degrades to 0 (open to offers), never throws', () {
      expect(requestPrice(openToOffers: false, budgetText: 'abc'), 0);
      expect(requestPrice(openToOffers: false, budgetText: ''), 0);
      expect(requestPrice(openToOffers: false, budgetText: '-200'), 0);
    });
  });

  group('Attribute composition (_when survives schema pruning)', () {
    final schema = QuestionSchema.tryParse({
      'steps': [
        {'key': 'need', 'question': 'What do you need?', 'type': 'select', 'required': true,
         'options': [
           {'value': 'leak', 'label': 'Leak'},
           {'value': 'burst_pipe', 'label': 'Burst pipe'},
         ]},
        {'key': 'setting', 'question': 'Indoor or outdoor?', 'type': 'select', 'skip_in_emergency': true,
         'options': [
           {'value': 'indoor', 'label': 'Indoor'},
           {'value': 'outdoor', 'label': 'Outdoor'},
         ]},
      ],
    })!;

    test('merges pruned schema answers with the reserved _when key', () {
      final pruned = schema.prunedAnswers(
        answers: {'need': 'leak', 'setting': 'indoor'},
        postType: 'request',
        emergency: false,
      );
      final attrs = composeRequestAttributes(prunedSchemaAnswers: pruned, when: RequestWhen.today);
      expect(attrs, {'need': 'leak', 'setting': 'indoor', '_when': 'today'});
    });

    test('emergency: trimmed answers pruned, _when still recorded', () {
      final pruned = schema.prunedAnswers(
        answers: {'need': 'burst_pipe', 'setting': 'indoor'},
        postType: 'request',
        emergency: RequestWhen.rightNow.isEmergency,
      );
      final attrs = composeRequestAttributes(prunedSchemaAnswers: pruned, when: RequestWhen.rightNow);
      expect(attrs, {'need': 'burst_pipe', '_when': 'right_now'});
    });

    test('no when chosen → no reserved key (defensive)', () {
      final attrs = composeRequestAttributes(prunedSchemaAnswers: const {}, when: null);
      expect(attrs, isEmpty);
    });

    test('reserved key can never collide with schema keys (schemas cannot start with _)', () {
      expect(kWhenAttributeKey.startsWith('_'), isTrue);
    });
  });
}
