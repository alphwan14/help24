import 'post_model.dart' show Urgency;

/// Posting Redesign R-1: pure logic for the Request ("I need help") journey.
///
/// Everything decision-shaped about the request flow lives here — step
/// sequence, "When do you need it?" mapping, budget semantics, and the
/// reserved-attribute composition — so it is unit-testable without widgets.
/// The UI in post_screen.dart is a thin renderer over this.

/// The user-facing answer to "When do you need it?".
///
/// Replaces the abstract Urgent/Soon/Flexible chips for requests. The precise
/// choice is preserved in `attributes._when`; the legacy `urgency` column gets
/// the closest mapping so every existing feed/filter/sort keeps working.
enum RequestWhen { rightNow, today, thisWeek, flexible }

extension RequestWhenX on RequestWhen {
  String get label {
    switch (this) {
      case RequestWhen.rightNow:
        return 'Right now';
      case RequestWhen.today:
        return 'Today';
      case RequestWhen.thisWeek:
        return 'This week';
      case RequestWhen.flexible:
        return 'Flexible';
    }
  }

  String get subtitle {
    switch (this) {
      case RequestWhen.rightNow:
        return 'Emergency — providers see it first';
      case RequestWhen.today:
        return 'Sometime today';
      case RequestWhen.thisWeek:
        return 'In the next few days';
      case RequestWhen.flexible:
        return 'Whenever works';
    }
  }

  /// Closest value for the legacy posts.urgency column (CHECK-constrained).
  Urgency get urgency {
    switch (this) {
      case RequestWhen.rightNow:
        return Urgency.urgent;
      case RequestWhen.today:
        return Urgency.soon;
      case RequestWhen.thisWeek:
      case RequestWhen.flexible:
        return Urgency.flexible;
    }
  }

  /// Emergency mode: trims schema questions (skip_in_emergency) and keeps the
  /// existing urgent behavior (badge + 1h urgent window).
  bool get isEmergency => this == RequestWhen.rightNow;

  /// Stable value stored in attributes under [kWhenAttributeKey].
  String get wireValue {
    switch (this) {
      case RequestWhen.rightNow:
        return 'right_now';
      case RequestWhen.today:
        return 'today';
      case RequestWhen.thisWeek:
        return 'this_week';
      case RequestWhen.flexible:
        return 'flexible';
    }
  }
}

/// Reverse lookup for values read back from posts.attributes.
RequestWhen? requestWhenFromWire(String? value) {
  for (final w in RequestWhen.values) {
    if (w.wireValue == value) return w;
  }
  return null;
}

/// Reserved attribute keys — written by the app itself, never by category
/// schemas (schema question keys must not start with '_').
const String kWhenAttributeKey = '_when';

/// The screens of the request journey, in order. `questions` is included only
/// when the chosen category has visible schema questions (snapshotted when the
/// user leaves the `when` step, so a late schema fetch can never reshuffle
/// steps mid-flow).
enum RequestStepId { category, title, when, questions, budget, location, photos, details, preview }

List<RequestStepId> requestSteps({required bool includeQuestions}) => [
      RequestStepId.category,
      RequestStepId.title,
      RequestStepId.when,
      if (includeQuestions) RequestStepId.questions,
      RequestStepId.budget,
      RequestStepId.location,
      RequestStepId.photos,
      RequestStepId.details,
      RequestStepId.preview,
    ];

/// Budget semantics: requesters may not know a fair price — "Open to offers"
/// is a first-class answer, stored as the existing price=0 convention.
double requestPrice({required bool openToOffers, required String budgetText}) {
  if (openToOffers) return 0;
  final parsed = double.tryParse(budgetText.trim());
  return (parsed == null || parsed < 0) ? 0 : parsed;
}

/// Final attributes payload: schema answers (ALREADY pruned by the schema —
/// hidden conditionals removed) merged with the reserved `_when` key. Merged
/// AFTER pruning because the pruner only keeps schema-question keys and would
/// otherwise drop `_when`.
Map<String, dynamic> composeRequestAttributes({
  required Map<String, dynamic> prunedSchemaAnswers,
  required RequestWhen? when,
}) {
  return {
    ...prunedSchemaAnswers,
    if (when != null) kWhenAttributeKey: when.wireValue,
  };
}
