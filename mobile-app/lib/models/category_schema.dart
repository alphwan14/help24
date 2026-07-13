/// Smart Posting (SP-1/SP-2): the category question-schema engine.
///
/// Parses `categories.question_schema` JSONB from the server and resolves
/// which questions are visible for a given (answers, post type, emergency)
/// state — the progressive-disclosure core. Pure Dart, no Flutter imports,
/// so every rule here is unit-testable.
///
/// Forward-compatibility contract: anything malformed or unknown degrades
/// gracefully (a bad schema → null → generic form; an unknown field type →
/// that step is skipped). The schema layer must NEVER block posting.
library;

/// One selectable choice of a select/multiselect question.
class QuestionOption {
  final String value; // stable key stored in posts.attributes
  final String label; // what the user sees

  const QuestionOption({required this.value, required this.label});

  static QuestionOption? tryParse(dynamic j) {
    if (j is! Map) return null;
    final value = j['value'];
    final label = j['label'];
    if (value is! String || value.isEmpty) return null;
    return QuestionOption(
      value: value,
      label: label is String && label.isNotEmpty ? label : value,
    );
  }
}

/// Progressive-disclosure condition: show a step only when a previously
/// answered field matches one of `anyOf`. Booleans match "true"/"false".
class ShowIf {
  final String field;
  final List<String> anyOf;

  const ShowIf({required this.field, required this.anyOf});

  static ShowIf? tryParse(dynamic j) {
    if (j is! Map) return null;
    final field = j['field'];
    final raw = j['any_of'];
    if (field is! String || field.isEmpty || raw is! List) return null;
    final anyOf = raw.whereType<Object>().map((e) => e.toString()).toList();
    if (anyOf.isEmpty) return null;
    return ShowIf(field: field, anyOf: anyOf);
  }

  bool matches(Map<String, dynamic> answers) {
    final answer = answers[field];
    if (answer == null) return false;
    if (answer is List) {
      // multiselect parent: visible if ANY selected value matches
      return answer.map((e) => e.toString()).any(anyOf.contains);
    }
    return anyOf.contains(answer.toString());
  }
}

/// One question in the guided flow.
class QuestionStep {
  static const supportedTypes = {'select', 'multiselect', 'boolean', 'text', 'number'};

  final String key;
  final String question;
  final String type;
  final List<QuestionOption> options;
  final bool required;
  final bool highlight;
  final List<String>? appliesTo; // post types; null = all
  final bool skipInEmergency;
  final ShowIf? showIf;
  final String? hint;

  const QuestionStep({
    required this.key,
    required this.question,
    required this.type,
    this.options = const [],
    this.required = false,
    this.highlight = false,
    this.appliesTo,
    this.skipInEmergency = false,
    this.showIf,
    this.hint,
  });

  bool get isSupported => supportedTypes.contains(type);
  bool get needsOptions => type == 'select' || type == 'multiselect';

  static QuestionStep? tryParse(dynamic j) {
    if (j is! Map) return null;
    final key = j['key'];
    final question = j['question'];
    final type = j['type'];
    if (key is! String || key.isEmpty) return null;
    if (question is! String || question.isEmpty) return null;
    if (type is! String || type.isEmpty) return null;

    final options = (j['options'] is List)
        ? (j['options'] as List).map(QuestionOption.tryParse).whereType<QuestionOption>().toList()
        : <QuestionOption>[];

    List<String>? appliesTo;
    if (j['applies_to'] is List) {
      appliesTo = (j['applies_to'] as List).whereType<Object>().map((e) => e.toString()).toList();
      if (appliesTo.isEmpty) appliesTo = null;
    }

    final step = QuestionStep(
      key: key,
      question: question,
      type: type,
      options: options,
      required: j['required'] == true,
      highlight: j['highlight'] == true,
      appliesTo: appliesTo,
      skipInEmergency: j['skip_in_emergency'] == true,
      showIf: ShowIf.tryParse(j['show_if']),
      hint: j['hint'] is String ? j['hint'] as String : null,
    );
    // A choice question without valid choices can never be answered — drop it.
    if (step.needsOptions && step.options.isEmpty) return null;
    return step;
  }
}

/// A category's full question schema.
class QuestionSchema {
  final int version;
  final List<QuestionStep> steps;

  const QuestionSchema({required this.version, required this.steps});

  /// Parses server JSON. Returns null for anything unusable (→ generic form).
  /// Steps with unknown types are dropped individually, not fatally.
  static QuestionSchema? tryParse(dynamic j) {
    if (j is! Map) return null;
    final rawSteps = j['steps'];
    if (rawSteps is! List) return null;
    final steps = rawSteps
        .map(QuestionStep.tryParse)
        .whereType<QuestionStep>()
        .where((s) => s.isSupported)
        .toList();
    if (steps.isEmpty) return null;
    final version = j['version'] is int ? j['version'] as int : 1;
    return QuestionSchema(version: version, steps: steps);
  }

  /// The progressive-disclosure resolver: which steps are visible right now.
  ///
  /// - `appliesTo` filters by post type (request/offer/job).
  /// - Emergency mode (urgency = urgent) hides `skip_in_emergency` steps so an
  ///   urgent post finishes in seconds.
  /// - `showIf` steps appear only once their parent answer matches — evaluated
  ///   in schema order, so chained conditions (A reveals B reveals C) work.
  List<QuestionStep> visibleSteps({
    required Map<String, dynamic> answers,
    required String postType,
    required bool emergency,
  }) {
    final visible = <QuestionStep>[];
    final visibleKeys = <String>{};
    for (final s in steps) {
      if (s.appliesTo != null && !s.appliesTo!.contains(postType)) continue;
      if (emergency && s.skipInEmergency) continue;
      if (s.showIf != null) {
        // The parent must itself be visible AND match — hiding a parent hides
        // its whole conditional chain even if a stale answer lingers.
        if (!visibleKeys.contains(s.showIf!.field)) continue;
        if (!s.showIf!.matches(answers)) continue;
      }
      visible.add(s);
      visibleKeys.add(s.key);
    }
    return visible;
  }

  /// Drops answers whose question is no longer visible (e.g. the user changed
  /// "issue" from Screen to Battery — "Is it cracked?" must not be submitted).
  Map<String, dynamic> prunedAnswers({
    required Map<String, dynamic> answers,
    required String postType,
    required bool emergency,
  }) {
    final keys = visibleSteps(answers: answers, postType: postType, emergency: emergency)
        .map((s) => s.key)
        .toSet();
    return {
      for (final e in answers.entries)
        if (keys.contains(e.key) && !_isEmptyAnswer(e.value)) e.key: e.value,
    };
  }

  /// True when every visible required question has a non-empty answer.
  bool isComplete({
    required Map<String, dynamic> answers,
    required String postType,
    required bool emergency,
  }) {
    return visibleSteps(answers: answers, postType: postType, emergency: emergency)
        .where((s) => s.required)
        .every((s) => !_isEmptyAnswer(answers[s.key]));
  }

  static bool _isEmptyAnswer(dynamic v) {
    if (v == null) return true;
    if (v is String) return v.trim().isEmpty;
    if (v is List) return v.isEmpty;
    return false; // bool/num are always meaningful
  }
}
