import '../models/post_model.dart';

/// Provider vetting (migration 135) as people read it on a listing.
///
/// Only OFFERS carry these: an offer is a provider advertising work. Requests
/// and jobs are posted by the people hiring.
///
///   'Certificate pending'  the provider's Care check rests on an eCitizen
///                          receipt; they cannot be hired for care work yet.
///   'Not yet verified'     the provider has not completed the check this kind
///                          of work needs (shown only on listings from before
///                          vetting, for 14 days).
///   'Care checked'         ID + Certificate of Good Conduct approved.
///   'ID verified'          ID approved.
enum VettingTone { caution, positive }

class VettingLabel {
  final String text;
  final VettingTone tone;
  const VettingLabel(this.text, this.tone);

  @override
  bool operator ==(Object other) => other is VettingLabel && other.text == text && other.tone == tone;
  @override
  int get hashCode => Object.hash(text, tone);
  @override
  String toString() => 'VettingLabel($text, $tone)';
}

VettingLabel? listingVettingLabel(PostModel post) {
  if (post.type != PostType.offer) return null;
  switch (post.vettingLabel) {
    case 'certificate_pending':
      return const VettingLabel('Certificate pending', VettingTone.caution);
    case 'not_verified':
      return const VettingLabel('Not yet verified', VettingTone.caution);
  }
  if (post.authorCareStatus == 'checked') return const VettingLabel('Care checked', VettingTone.positive);
  if (post.authorIdVerified) return const VettingLabel('ID verified', VettingTone.positive);
  return null;
}

/// The longer sentence for a listing's detail page, or null.
String? listingVettingExplanation(PostModel post) {
  if (post.type != PostType.offer) return null;
  return switch (post.vettingLabel) {
    'certificate_pending' =>
      'This provider\'s ID is verified and their Certificate of Good Conduct is on its way. You can message them, but they cannot be hired for care work until Help24 has the certificate.',
    'not_verified' =>
      'This provider has not yet verified their identity, which this kind of work needs on Help24.',
    _ => null,
  };
}
