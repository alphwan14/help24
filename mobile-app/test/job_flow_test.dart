import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/category_schema.dart';
import 'package:help24/models/job_flow.dart';
import 'package:help24/models/post_model.dart' show Urgency;

/// Posting Redesign R-3: the job-journey rules.
void main() {
  group('Start date (urgency column stays constant for jobs)', () {
    test('jobs never write urgent — the column is a constant flexible', () {
      expect(kJobUrgency, Urgency.flexible);
    });

    test('wire values are stable', () {
      expect(JobStart.immediately.wireValue, 'immediately');
      expect(JobStart.withinMonth.wireValue, 'within_month');
      expect(JobStart.flexible.wireValue, 'flexible');
    });

    test('every option has a label and subtitle', () {
      for (final s in JobStart.values) {
        expect(s.label, isNotEmpty);
        expect(s.subtitle, isNotEmpty);
      }
    });
  });

  group('Step sequence', () {
    test('with questions: category → title → employment → salary → start → questions → description → location → preview', () {
      expect(jobSteps(includeQuestions: true), const [
        JobStepId.category,
        JobStepId.title,
        JobStepId.employment,
        JobStepId.salary,
        JobStepId.start,
        JobStepId.questions,
        JobStepId.description,
        JobStepId.location,
        JobStepId.preview,
      ]);
    });

    test('without questions the flow simply skips that screen', () {
      final steps = jobSteps(includeQuestions: false);
      expect(steps, isNot(contains(JobStepId.questions)));
      expect(steps.first, JobStepId.category);
      expect(steps.last, JobStepId.preview);
      expect(steps.length, jobSteps(includeQuestions: true).length - 1);
    });

    test('there is deliberately NO photos step (jobs are recruitment)', () {
      expect(jobSteps(includeQuestions: true).map((s) => s.name), isNot(contains('photos')));
    });

    test('role definition before logistics: employment → salary → start; description before location', () {
      final steps = jobSteps(includeQuestions: true);
      expect(steps.indexOf(JobStepId.employment), lessThan(steps.indexOf(JobStepId.salary)));
      expect(steps.indexOf(JobStepId.salary), lessThan(steps.indexOf(JobStepId.start)));
      expect(steps.indexOf(JobStepId.description), lessThan(steps.indexOf(JobStepId.location)));
    });
  });

  group('Salary (required, pay transparency)', () {
    test('valid amounts parse', () {
      expect(jobSalary(' 25000 '), 25000);
      expect(jobSalary('1500.50'), 1500.50);
    });

    test('empty, garbage, zero and negative are rejected (null)', () {
      expect(jobSalary(''), isNull);
      expect(jobSalary('abc'), isNull);
      expect(jobSalary('0'), isNull);
      expect(jobSalary('-500'), isNull);
    });
  });

  group('Attribute composition', () {
    final schema = QuestionSchema.tryParse({
      'steps': [
        {'key': 'need', 'question': 'What do you need help with?', 'type': 'select',
         'applies_to': ['request'],
         'options': [
           {'value': 'leak', 'label': 'Leak'},
         ]},
        {'key': 'work_type', 'question': 'What will they mainly do?', 'type': 'multiselect',
         'applies_to': ['job'],
         'options': [
           {'value': 'repairs', 'label': 'Repairs'},
           {'value': 'installations', 'label': 'Installations'},
         ]},
        {'key': 'experience_required', 'question': 'Experience required?', 'type': 'select',
         'applies_to': ['job'],
         'options': [
           {'value': 'any', 'label': 'Any'},
           {'value': '3_plus', 'label': '3+ years'},
         ]},
      ],
    })!;

    test('job answers merge with the reserved _start key', () {
      final pruned = schema.prunedAnswers(
        answers: {'work_type': ['repairs'], 'experience_required': '3_plus'},
        postType: 'job',
        emergency: false,
      );
      final attrs = composeJobAttributes(
        prunedSchemaAnswers: pruned,
        start: JobStart.immediately,
      );
      expect(attrs, {
        'work_type': ['repairs'],
        'experience_required': '3_plus',
        '_start': 'immediately',
      });
    });

    test('requester-voiced answers never leak into a job post', () {
      final pruned = schema.prunedAnswers(
        answers: {'need': 'leak', 'work_type': ['installations']},
        postType: 'job',
        emergency: false,
      );
      expect(pruned.containsKey('need'), isFalse);
      expect(pruned['work_type'], ['installations']);
    });

    test('job-voiced steps are invisible to requests', () {
      final visible = schema.visibleSteps(answers: {}, postType: 'request', emergency: false);
      expect(visible.map((s) => s.key), ['need']);
      final jobVisible = schema.visibleSteps(answers: {}, postType: 'job', emergency: false);
      expect(jobVisible.map((s) => s.key), ['work_type', 'experience_required']);
    });

    test('no start chosen → no reserved key (defensive)', () {
      expect(composeJobAttributes(prunedSchemaAnswers: const {}, start: null), isEmpty);
    });

    test('reserved key cannot collide with schema keys', () {
      expect(kStartAttributeKey.startsWith('_'), isTrue);
    });
  });
}
