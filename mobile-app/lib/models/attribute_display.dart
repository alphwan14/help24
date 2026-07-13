import 'category_schema.dart';
import 'job_flow.dart';
import 'offer_flow.dart';
import 'post_model.dart';
import 'request_flow.dart';
import '../utils/format_utils.dart';

/// Posting Redesign R-4: pure read-side resolution — how stored posts speak
/// each intent's language on cards and detail sheets. No widgets here, so
/// every rule is unit-testable.

/// Money text for feed cards. Null → hide (legacy offers/jobs without a price).
/// Requests are the exception: price 0 is a real statement ("Open to offers").
String? cardMoneyLabel({
  required PostType type,
  required double price,
  required PricingType pricingType,
}) {
  switch (type) {
    case PostType.request:
      return price <= 0 ? 'Open to offers' : 'Budget ${formatPriceDisplay(price)}';
    case PostType.offer:
      return price <= 0 ? null : 'From ${formatPriceDisplay(price)}${pricingType.shortSuffix}';
    case PostType.job:
      return price <= 0 ? null : '${formatPriceDisplay(price)}${pricingType.shortSuffix}';
  }
}

/// Money row LABEL for detail sheets, per intent.
String detailMoneyLabel(PostType type) {
  switch (type) {
    case PostType.request:
      return 'Budget';
    case PostType.offer:
      return 'Starting price';
    case PostType.job:
      return 'Salary';
  }
}

/// Money row VALUE for detail sheets (always non-null).
String detailMoneyValue({
  required PostType type,
  required double price,
  required PricingType pricingType,
}) {
  switch (type) {
    case PostType.request:
      return price <= 0 ? 'Open to offers' : formatPriceDisplay(price);
    case PostType.offer:
      return price <= 0
          ? 'Ask for a quote'
          : 'From ${formatPriceDisplay(price)} · ${pricingType.displayLabel}';
    case PostType.job:
      return price <= 0
          ? 'Negotiable'
          : '${formatPriceDisplay(price)} · ${pricingType.displayLabel}';
  }
}

/// The intent's time-signal chip from reserved attributes: offers show
/// availability, jobs show the start date. Requests return null — their
/// urgency badge already carries the signal.
String? timeSignalChip({
  required PostType type,
  required Map<String, dynamic> attributes,
}) {
  switch (type) {
    case PostType.request:
      return null;
    case PostType.offer:
      return offerAvailabilityFromWire(attributes[kAvailabilityAttributeKey]?.toString())?.label;
    case PostType.job:
      final start = jobStartFromWire(attributes[kStartAttributeKey]?.toString());
      switch (start) {
        case JobStart.immediately:
          return 'Starts immediately';
        case JobStart.withinMonth:
          return 'Starts within a month';
        case JobStart.flexible:
          return 'Flexible start';
        case null:
          return null;
      }
  }
}

/// Chip labels for feed cards from `highlight: true` answers, in schema order,
/// capped at [max]. Missing schema (cache cold, custom category) → empty.
List<String> highlightChipLabels({
  required QuestionSchema? schema,
  required String postType,
  required Map<String, dynamic> attributes,
  int max = 2,
}) {
  if (schema == null || attributes.isEmpty) return const [];
  final out = <String>[];
  for (final step in schema.steps) {
    if (out.length >= max) break;
    if (!step.highlight) continue;
    if (step.appliesTo != null && !step.appliesTo!.contains(postType)) continue;
    final answer = attributes[step.key];
    if (answer == null) continue;
    switch (step.type) {
      case 'select':
        for (final o in step.options) {
          if (o.value == answer.toString()) {
            out.add(o.label);
            break;
          }
        }
        break;
      case 'multiselect':
        final values = (answer is List) ? answer.map((e) => e.toString()).toSet() : const <String>{};
        for (final o in step.options) {
          if (out.length >= max) break;
          if (values.contains(o.value)) out.add(o.label);
        }
        break;
      default:
        break; // booleans/text don't make good chips
    }
  }
  return out;
}

/// One labeled line of a detail sheet's Details section.
class AttributeRow {
  final String label;
  final String value;

  const AttributeRow({required this.label, required this.value});
}

/// Full Q/A list for detail sheets: the intent's reserved time signal first,
/// then every answered schema question in schema order. Works with a null
/// schema (reserved rows still resolve).
List<AttributeRow> attributeDetailRows({
  required QuestionSchema? schema,
  required String postType,
  required Map<String, dynamic> attributes,
}) {
  if (attributes.isEmpty) return const [];
  final rows = <AttributeRow>[];

  final when = requestWhenFromWire(attributes[kWhenAttributeKey]?.toString());
  if (when != null) rows.add(AttributeRow(label: 'Needed', value: when.label));
  final availability =
      offerAvailabilityFromWire(attributes[kAvailabilityAttributeKey]?.toString());
  if (availability != null) {
    rows.add(AttributeRow(label: 'Availability', value: availability.label));
  }
  final start = jobStartFromWire(attributes[kStartAttributeKey]?.toString());
  if (start != null) rows.add(AttributeRow(label: 'Start date', value: start.label));

  if (schema == null) return rows;
  for (final step in schema.steps) {
    if (step.appliesTo != null && !step.appliesTo!.contains(postType)) continue;
    final answer = attributes[step.key];
    if (answer == null) continue;
    String? value;
    switch (step.type) {
      case 'select':
        for (final o in step.options) {
          if (o.value == answer.toString()) {
            value = o.label;
            break;
          }
        }
        break;
      case 'multiselect':
        final values = (answer is List) ? answer.map((e) => e.toString()).toSet() : const <String>{};
        final labels = step.options.where((o) => values.contains(o.value)).map((o) => o.label);
        if (labels.isNotEmpty) value = labels.join(', ');
        break;
      case 'boolean':
        value = answer == true ? 'Yes' : 'No';
        break;
      default:
        final s = answer.toString().trim();
        if (s.isNotEmpty) value = s;
    }
    if (value != null) {
      rows.add(AttributeRow(label: _questionAsLabel(step.question), value: value));
    }
  }
  return rows;
}

/// "Is the water shut off?" → "Is the water shut off" — detail rows read
/// better without the question mark.
String _questionAsLabel(String question) =>
    question.endsWith('?') ? question.substring(0, question.length - 1) : question;
