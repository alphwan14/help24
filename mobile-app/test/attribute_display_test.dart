import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/attribute_display.dart';
import 'package:help24/models/category_schema.dart';
import 'package:help24/models/post_model.dart';

/// Posting Redesign R-4: read-side display rules.
void main() {
  group('cardMoneyLabel (per-intent money language)', () {
    test('request: price 0 is a statement, not a missing value', () {
      expect(
        cardMoneyLabel(type: PostType.request, price: 0, pricingType: PricingType.task),
        'Open to offers',
      );
      expect(
        cardMoneyLabel(type: PostType.request, price: 1500, pricingType: PricingType.task),
        'Budget KES 1,500',
      );
    });

    test('offer: From-price with compact rate suffix', () {
      expect(
        cardMoneyLabel(type: PostType.offer, price: 800, pricingType: PricingType.hour),
        'From KES 800/hr',
      );
      expect(
        cardMoneyLabel(type: PostType.offer, price: 500, pricingType: PricingType.task),
        'From KES 500',
      );
    });

    test('job: salary with period suffix', () {
      expect(
        cardMoneyLabel(type: PostType.job, price: 25000, pricingType: PricingType.month),
        'KES 25,000/mo',
      );
    });

    test('legacy zero-price offers/jobs stay hidden (null)', () {
      expect(cardMoneyLabel(type: PostType.offer, price: 0, pricingType: PricingType.task), isNull);
      expect(cardMoneyLabel(type: PostType.job, price: 0, pricingType: PricingType.task), isNull);
    });
  });

  group('detail sheet money', () {
    test('labels differentiate Budget / Starting price / Salary', () {
      expect(detailMoneyLabel(PostType.request), 'Budget');
      expect(detailMoneyLabel(PostType.offer), 'Starting price');
      expect(detailMoneyLabel(PostType.job), 'Salary');
    });

    test('values speak each intent', () {
      expect(
        detailMoneyValue(type: PostType.request, price: 0, pricingType: PricingType.task),
        'Open to offers',
      );
      expect(
        detailMoneyValue(type: PostType.offer, price: 800, pricingType: PricingType.hour),
        'From KES 800 · Per hour',
      );
      expect(
        detailMoneyValue(type: PostType.job, price: 25000, pricingType: PricingType.month),
        'KES 25,000 · Per month',
      );
    });
  });

  group('timeSignalChip (reserved keys)', () {
    test('offer availability resolves from wire value', () {
      expect(
        timeSignalChip(type: PostType.offer, attributes: {'_availability': 'available_now'}),
        'Available now',
      );
    });

    test('job start resolves with recruiting language', () {
      expect(
        timeSignalChip(type: PostType.job, attributes: {'_start': 'immediately'}),
        'Starts immediately',
      );
      expect(
        timeSignalChip(type: PostType.job, attributes: {'_start': 'flexible'}),
        'Flexible start',
      );
    });

    test('requests return null (urgency badge already carries it)', () {
      expect(
        timeSignalChip(type: PostType.request, attributes: {'_when': 'right_now'}),
        isNull,
      );
    });

    test('unknown or missing wire values degrade to null, never throw', () {
      expect(timeSignalChip(type: PostType.offer, attributes: {'_availability': '???'}), isNull);
      expect(timeSignalChip(type: PostType.job, attributes: const {}), isNull);
    });
  });

  final schema = QuestionSchema.tryParse({
    'steps': [
      {'key': 'need', 'question': 'What do you need help with?', 'type': 'select', 'highlight': true,
       'applies_to': ['request'],
       'options': [
         {'value': 'leak', 'label': 'Leak'},
         {'value': 'burst_pipe', 'label': 'Burst pipe'},
       ]},
      {'key': 'water_off', 'question': 'Is the water shut off?', 'type': 'boolean',
       'applies_to': ['request']},
      {'key': 'services', 'question': 'What services do you offer?', 'type': 'multiselect', 'highlight': true,
       'applies_to': ['offer'],
       'options': [
         {'value': 'leak_repair', 'label': 'Leak repairs'},
         {'value': 'drains', 'label': 'Drain unblocking'},
         {'value': 'general', 'label': 'General plumbing'},
       ]},
      {'key': 'notes', 'question': 'Notes?', 'type': 'text', 'highlight': true,
       'applies_to': ['request']},
    ],
  })!;

  group('highlightChipLabels', () {
    test('resolves highlight select answers to labels', () {
      expect(
        highlightChipLabels(schema: schema, postType: 'request', attributes: {'need': 'burst_pipe'}),
        ['Burst pipe'],
      );
    });

    test('multiselect expands but respects the cap', () {
      expect(
        highlightChipLabels(
          schema: schema,
          postType: 'offer',
          attributes: {'services': ['leak_repair', 'drains', 'general']},
          max: 2,
        ),
        ['Leak repairs', 'Drain unblocking'],
      );
    });

    test('applies_to filters by post type; text answers never become chips', () {
      expect(
        highlightChipLabels(
          schema: schema,
          postType: 'offer',
          attributes: {'need': 'leak', 'notes': 'hello'},
        ),
        isEmpty,
      );
    });

    test('null schema or empty attributes → empty, never throws', () {
      expect(highlightChipLabels(schema: null, postType: 'request', attributes: {'need': 'leak'}), isEmpty);
      expect(highlightChipLabels(schema: schema, postType: 'request', attributes: const {}), isEmpty);
    });
  });

  group('attributeDetailRows', () {
    test('reserved time signal first, then Q/A in schema order', () {
      final rows = attributeDetailRows(
        schema: schema,
        postType: 'request',
        attributes: {'_when': 'today', 'need': 'leak', 'water_off': true},
      );
      expect(rows.map((r) => '${r.label}: ${r.value}'), [
        'Needed: Today',
        'What do you need help with: Leak',
        'Is the water shut off: Yes',
      ]);
    });

    test('offer availability row + multiselect joined labels', () {
      final rows = attributeDetailRows(
        schema: schema,
        postType: 'offer',
        attributes: {'_availability': 'by_appointment', 'services': ['leak_repair', 'general']},
      );
      expect(rows.map((r) => '${r.label}: ${r.value}'), [
        'Availability: By appointment',
        'What services do you offer: Leak repairs, General plumbing',
      ]);
    });

    test('null schema still resolves reserved rows (job start)', () {
      final rows = attributeDetailRows(
        schema: null,
        postType: 'job',
        attributes: {'_start': 'within_month', 'work_type': ['repairs']},
      );
      expect(rows.map((r) => '${r.label}: ${r.value}'), ['Start date: Within a month']);
    });

    test('empty attributes → no rows; unanswered steps skipped', () {
      expect(attributeDetailRows(schema: schema, postType: 'request', attributes: const {}), isEmpty);
      final rows = attributeDetailRows(
        schema: schema,
        postType: 'request',
        attributes: {'need': 'leak'},
      );
      expect(rows.length, 1);
    });
  });

  group('PricingType.shortSuffix', () {
    test('task has no suffix; periods are compact', () {
      expect(PricingType.task.shortSuffix, '');
      expect(PricingType.hour.shortSuffix, '/hr');
      expect(PricingType.month.shortSuffix, '/mo');
    });
  });
}
