import 'post_model.dart' show Urgency;

/// Posting Redesign R-3: pure logic for the Job ("I'm hiring") journey.
/// Same shape as request_flow.dart / offer_flow.dart: decisions here,
/// unit-tested; the UI is a thin renderer.
///
/// Jobs are recruitment — the flow optimizes for role clarity: employment
/// type, a stated salary, a start date, recruitment questions, and a REQUIRED
/// role description.

/// "When do they start?" — replaces urgency for jobs. The legacy urgency
/// column is a constant `flexible` (nothing reads urgency for jobs — the
/// urgent feed filters type='request'); the real signal lives in attributes.
enum JobStart { immediately, withinMonth, flexible }

extension JobStartX on JobStart {
  String get label {
    switch (this) {
      case JobStart.immediately:
        return 'Immediately';
      case JobStart.withinMonth:
        return 'Within a month';
      case JobStart.flexible:
        return 'Flexible';
    }
  }

  String get subtitle {
    switch (this) {
      case JobStart.immediately:
        return 'They start as soon as possible';
      case JobStart.withinMonth:
        return 'Hiring in the next few weeks';
      case JobStart.flexible:
        return 'Start date to be agreed';
    }
  }

  /// Stable value stored in attributes under [kStartAttributeKey].
  String get wireValue {
    switch (this) {
      case JobStart.immediately:
        return 'immediately';
      case JobStart.withinMonth:
        return 'within_month';
      case JobStart.flexible:
        return 'flexible';
    }
  }
}

/// Reverse lookup for values read back from posts.attributes.
JobStart? jobStartFromWire(String? value) {
  for (final s in JobStart.values) {
    if (s.wireValue == value) return s;
  }
  return null;
}

/// The legacy urgency column value for every job.
const Urgency kJobUrgency = Urgency.flexible;

/// Reserved attribute key (schema question keys must not start with '_').
const String kStartAttributeKey = '_start';

/// The screens of the job journey, in order (per the approved journey — note:
/// no photos step; job ads are recruitment, and the description carries the
/// role). `questions` is included only when the category has job-applicable
/// schema steps (snapshotted when leaving the Title step).
enum JobStepId { category, title, employment, salary, start, questions, description, location, preview }

List<JobStepId> jobSteps({required bool includeQuestions}) => [
      JobStepId.category,
      JobStepId.title,
      JobStepId.employment,
      JobStepId.salary,
      JobStepId.start,
      if (includeQuestions) JobStepId.questions,
      JobStepId.description,
      JobStepId.location,
      JobStepId.preview,
    ];

/// Salary is REQUIRED — pay transparency attracts serious applicants. Returns
/// the parsed amount, or null when not a valid positive amount.
double? jobSalary(String text) {
  final parsed = double.tryParse(text.trim());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

/// Final attributes payload: pruned schema answers merged with the reserved
/// `_start` key (merged AFTER pruning — the pruner only keeps schema question
/// keys and would drop it).
Map<String, dynamic> composeJobAttributes({
  required Map<String, dynamic> prunedSchemaAnswers,
  required JobStart? start,
}) {
  return {
    ...prunedSchemaAnswers,
    if (start != null) kStartAttributeKey: start.wireValue,
  };
}
