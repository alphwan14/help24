import 'post_model.dart' show Urgency;

/// Posting Redesign R-2: pure logic for the Offer ("I provide a service")
/// journey. Same shape as request_flow.dart: every decision is here and
/// unit-tested; the UI is a thin renderer.
///
/// Offers are advertisements of capability — the flow optimizes for
/// credibility: capability questions, a REQUIRED starting price, availability,
/// portfolio photos, and an encouraged (not forced) pitch.

/// "When are you available?" — replaces the urgency chips for offers.
/// An offer is never "urgent"; the legacy urgency column is written as a
/// constant `flexible` (nothing reads urgency for offers — the urgent feed
/// filters type='request') and the real signal lives in attributes.
enum OfferAvailability { availableNow, thisWeek, byAppointment }

extension OfferAvailabilityX on OfferAvailability {
  String get label {
    switch (this) {
      case OfferAvailability.availableNow:
        return 'Available now';
      case OfferAvailability.thisWeek:
        return 'This week';
      case OfferAvailability.byAppointment:
        return 'By appointment';
    }
  }

  String get subtitle {
    switch (this) {
      case OfferAvailability.availableNow:
        return 'Ready to start immediately';
      case OfferAvailability.thisWeek:
        return 'Free in the next few days';
      case OfferAvailability.byAppointment:
        return 'Clients book a time with you';
    }
  }

  /// Stable value stored in attributes under [kAvailabilityAttributeKey].
  String get wireValue {
    switch (this) {
      case OfferAvailability.availableNow:
        return 'available_now';
      case OfferAvailability.thisWeek:
        return 'this_week';
      case OfferAvailability.byAppointment:
        return 'by_appointment';
    }
  }
}

/// Reverse lookup for values read back from posts.attributes.
OfferAvailability? offerAvailabilityFromWire(String? value) {
  for (final a in OfferAvailability.values) {
    if (a.wireValue == value) return a;
  }
  return null;
}

/// The legacy urgency column value for every offer.
const Urgency kOfferUrgency = Urgency.flexible;

/// Reserved attribute key (schema question keys must not start with '_').
const String kAvailabilityAttributeKey = '_availability';

/// The screens of the offer journey, in order. `questions` is included only
/// when the category has offer-applicable schema steps (snapshotted when the
/// user leaves the Title step — category and type are both known there, and
/// offers have no emergency mode to wait for).
enum OfferStepId { category, title, questions, price, availability, location, photos, description, preview }

List<OfferStepId> offerSteps({required bool includeQuestions}) => [
      OfferStepId.category,
      OfferStepId.title,
      if (includeQuestions) OfferStepId.questions,
      OfferStepId.price,
      OfferStepId.availability,
      OfferStepId.location,
      OfferStepId.photos,
      OfferStepId.description,
      OfferStepId.preview,
    ];

/// Starting price is REQUIRED for offers — a seller must price. Returns the
/// parsed amount, or null when the text is not a valid positive amount.
double? offerStartingPrice(String text) {
  final parsed = double.tryParse(text.trim());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

/// Final attributes payload: pruned schema answers merged with the reserved
/// `_availability` key (merged AFTER pruning — the pruner only keeps schema
/// question keys and would drop it).
Map<String, dynamic> composeOfferAttributes({
  required Map<String, dynamic> prunedSchemaAnswers,
  required OfferAvailability? availability,
}) {
  return {
    ...prunedSchemaAnswers,
    if (availability != null) kAvailabilityAttributeKey: availability.wireValue,
  };
}
