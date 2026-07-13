import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/category_schema.dart';

/// Smart Posting SP-1/SP-2: the schema engine rules.
/// These mirror the contract documented in migration 072.
void main() {
  final laptopRepair = {
    'version': 1,
    'steps': [
      {
        'key': 'issue',
        'question': 'What needs fixing?',
        'type': 'select',
        'required': true,
        'highlight': true,
        'options': [
          {'value': 'screen', 'label': 'Screen'},
          {'value': 'software', 'label': 'Slow / Software'},
          {'value': 'other', 'label': 'Other'},
        ],
      },
      {
        'key': 'screen_cracked',
        'question': 'Is the screen cracked?',
        'type': 'boolean',
        'show_if': {'field': 'issue', 'any_of': ['screen']},
        'skip_in_emergency': true,
      },
      {
        'key': 'boots',
        'question': 'Can it still boot?',
        'type': 'boolean',
        'show_if': {'field': 'issue', 'any_of': ['software']},
        'skip_in_emergency': true,
      },
      {
        'key': 'warranty',
        'question': 'Under warranty?',
        'type': 'boolean',
        'skip_in_emergency': true,
      },
      {
        'key': 'job_only',
        'question': 'Job-only question?',
        'type': 'boolean',
        'applies_to': ['job'],
      },
    ],
  };

  group('parsing', () {
    test('parses a valid schema', () {
      final s = QuestionSchema.tryParse(laptopRepair);
      expect(s, isNotNull);
      expect(s!.version, 1);
      expect(s.steps.length, 5);
      expect(s.steps.first.required, isTrue);
      expect(s.steps.first.options.length, 3);
    });

    test('garbage inputs return null (generic form), never throw', () {
      expect(QuestionSchema.tryParse(null), isNull);
      expect(QuestionSchema.tryParse('not a map'), isNull);
      expect(QuestionSchema.tryParse({}), isNull);
      expect(QuestionSchema.tryParse({'steps': 'nope'}), isNull);
      expect(QuestionSchema.tryParse({'steps': []}), isNull);
    });

    test('unknown field types are skipped, not fatal (forward compat)', () {
      final s = QuestionSchema.tryParse({
        'version': 2,
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'hologram'},
          {'key': 'b', 'question': 'B?', 'type': 'boolean'},
        ],
      });
      expect(s, isNotNull);
      expect(s!.steps.length, 1);
      expect(s.steps.single.key, 'b');
    });

    test('select without valid options is dropped', () {
      final s = QuestionSchema.tryParse({
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'select', 'options': []},
          {'key': 'b', 'question': 'B?', 'type': 'select', 'options': [
            {'label': 'missing value'},
          ]},
          {'key': 'c', 'question': 'C?', 'type': 'text'},
        ],
      });
      expect(s!.steps.map((e) => e.key), ['c']);
    });

    test('option label falls back to value', () {
      final s = QuestionSchema.tryParse({
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'select', 'options': [
            {'value': 'raw'},
          ]},
        ],
      });
      expect(s!.steps.single.options.single.label, 'raw');
    });
  });

  group('progressive disclosure (visibleSteps)', () {
    final s = QuestionSchema.tryParse(laptopRepair)!;

    test('conditionals hidden until parent answer matches', () {
      final visible = s.visibleSteps(answers: {}, postType: 'request', emergency: false);
      expect(visible.map((e) => e.key), ['issue', 'warranty']);
    });

    test('answering the parent reveals only the matching follow-up', () {
      final visible = s.visibleSteps(
        answers: {'issue': 'screen'},
        postType: 'request',
        emergency: false,
      );
      expect(visible.map((e) => e.key), ['issue', 'screen_cracked', 'warranty']);
    });

    test('changing the parent switches the follow-up', () {
      final visible = s.visibleSteps(
        answers: {'issue': 'software'},
        postType: 'request',
        emergency: false,
      );
      expect(visible.map((e) => e.key), ['issue', 'boots', 'warranty']);
    });

    test('applies_to filters by post type', () {
      final visible = s.visibleSteps(answers: {}, postType: 'job', emergency: false);
      expect(visible.map((e) => e.key), contains('job_only'));
      final request = s.visibleSteps(answers: {}, postType: 'request', emergency: false);
      expect(request.map((e) => e.key), isNot(contains('job_only')));
    });

    test('boolean parent chains (two-level disclosure)', () {
      final mech = QuestionSchema.tryParse({
        'steps': [
          {'key': 'drivable', 'question': 'Can it be driven?', 'type': 'boolean'},
          {'key': 'towing', 'question': 'Need towing?', 'type': 'boolean',
           'show_if': {'field': 'drivable', 'any_of': ['false']}},
        ],
      })!;
      expect(
        mech.visibleSteps(answers: {'drivable': true}, postType: 'request', emergency: false)
            .map((e) => e.key),
        ['drivable'],
      );
      expect(
        mech.visibleSteps(answers: {'drivable': false}, postType: 'request', emergency: false)
            .map((e) => e.key),
        ['drivable', 'towing'],
      );
    });

    test('hiding a parent hides its whole conditional chain', () {
      final chained = QuestionSchema.tryParse({
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'boolean', 'skip_in_emergency': true},
          {'key': 'b', 'question': 'B?', 'type': 'boolean',
           'show_if': {'field': 'a', 'any_of': ['true']}},
        ],
      })!;
      // 'a' hidden by emergency → 'b' must not appear even with a stale answer.
      final visible = chained.visibleSteps(
        answers: {'a': true},
        postType: 'request',
        emergency: true,
      );
      expect(visible, isEmpty);
    });
  });

  group('emergency mode', () {
    final s = QuestionSchema.tryParse(laptopRepair)!;

    test('skip_in_emergency steps are hidden — urgent posts stay short', () {
      final visible = s.visibleSteps(
        answers: {'issue': 'screen'},
        postType: 'request',
        emergency: true,
      );
      expect(visible.map((e) => e.key), ['issue']);
    });
  });

  group('pruning (answers never leak)', () {
    final s = QuestionSchema.tryParse(laptopRepair)!;

    test('stale conditional answers are dropped when the parent changes', () {
      final pruned = s.prunedAnswers(
        answers: {'issue': 'software', 'screen_cracked': true},
        postType: 'request',
        emergency: false,
      );
      expect(pruned.containsKey('screen_cracked'), isFalse);
      expect(pruned['issue'], 'software');
    });

    test('emergency prunes skip_in_emergency answers at submit', () {
      final pruned = s.prunedAnswers(
        answers: {'issue': 'screen', 'warranty': true},
        postType: 'request',
        emergency: true,
      );
      expect(pruned.keys, ['issue']);
    });

    test('empty strings and empty lists are dropped', () {
      final t = QuestionSchema.tryParse({
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'text'},
          {'key': 'b', 'question': 'B?', 'type': 'multiselect', 'options': [
            {'value': 'x', 'label': 'X'},
          ]},
        ],
      })!;
      final pruned = t.prunedAnswers(
        answers: {'a': '   ', 'b': <String>[]},
        postType: 'request',
        emergency: false,
      );
      expect(pruned, isEmpty);
    });
  });

  group('completion gating', () {
    final s = QuestionSchema.tryParse(laptopRepair)!;

    test('incomplete while a visible required question is unanswered', () {
      expect(
        s.isComplete(answers: {}, postType: 'request', emergency: false),
        isFalse,
      );
    });

    test('complete once required questions are answered (optionals may be skipped)', () {
      expect(
        s.isComplete(answers: {'issue': 'other'}, postType: 'request', emergency: false),
        isTrue,
      );
    });

    test('boolean false counts as answered', () {
      final t = QuestionSchema.tryParse({
        'steps': [
          {'key': 'a', 'question': 'A?', 'type': 'boolean', 'required': true},
        ],
      })!;
      expect(t.isComplete(answers: {'a': false}, postType: 'request', emergency: false), isTrue);
      expect(t.isComplete(answers: {}, postType: 'request', emergency: false), isFalse);
    });
  });

  group('multiselect parents', () {
    test('show_if matches when ANY selected value matches', () {
      final t = QuestionSchema.tryParse({
        'steps': [
          {'key': 'services', 'question': 'Which services?', 'type': 'multiselect', 'options': [
            {'value': 'wash', 'label': 'Wash'},
            {'value': 'wax', 'label': 'Wax'},
          ]},
          {'key': 'wax_type', 'question': 'Wax type?', 'type': 'text',
           'show_if': {'field': 'services', 'any_of': ['wax']}},
        ],
      })!;
      expect(
        t.visibleSteps(answers: {'services': ['wash']}, postType: 'request', emergency: false)
            .map((e) => e.key),
        ['services'],
      );
      expect(
        t.visibleSteps(answers: {'services': ['wash', 'wax']}, postType: 'request', emergency: false)
            .map((e) => e.key),
        ['services', 'wax_type'],
      );
    });
  });
}
