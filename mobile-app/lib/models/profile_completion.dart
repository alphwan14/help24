import '../services/profession_registry.dart';
import 'user_model.dart';

/// Where a field lives on the Professional Profile.
enum ProfileSection {
  personal('Personal Information'),
  professional('Professional Information');

  const ProfileSection(this.title);
  final String title;
}

/// Whether a field is live today or declared for a future milestone.
///
/// `comingSoon` fields are DECLARED but excluded from the percentage, so the
/// profile is completable to 100% right now while the roadmap stays visible.
/// Shipping one later is a one-line status flip — no redesign, no recompute,
/// no migration of anybody's percentage.
enum ProfileFieldStatus { active, comingSoon }

/// The facts completion is computed from.
///
/// A value object rather than a raw [UserModel] so the registry stays pure and
/// unit-testable, and so the ONE judgement that needs the profession registry
/// — "is this a confirmed trade or legacy free text?" — is made in exactly one
/// place ([ProfileFacts.from]).
class ProfileFacts {
  final bool hasPhoto;
  final bool hasName;
  final bool hasPhone;
  final bool hasConfirmedProfession;
  final bool hasBio;

  const ProfileFacts({
    this.hasPhoto = false,
    this.hasName = false,
    this.hasPhone = false,
    this.hasConfirmedProfession = false,
    this.hasBio = false,
  });

  /// Minimum bio length that counts as written. Two words and a full stop is
  /// not a bio; this is the same bar the editor shows as a counter.
  static const int minBioLength = 40;

  factory ProfileFacts.from(UserModel? profile, {String? fallbackPhone}) {
    if (profile == null) {
      return ProfileFacts(hasPhone: (fallbackPhone ?? '').trim().isNotEmpty);
    }
    final phone = (profile.phone ?? '').trim().isNotEmpty
        ? profile.phone!
        : (fallbackPhone ?? '');
    return ProfileFacts(
      hasPhoto: profile.profileImage.trim().isNotEmpty,
      hasName: profile.name.trim().isNotEmpty,
      hasPhone: phone.trim().isNotEmpty,
      // Legacy free text ("Electrical Works") deliberately does NOT count.
      // It still displays everywhere; it just leaves this box unticked, which
      // is what nudges the one-tap migration to the controlled vocabulary.
      hasConfirmedProfession:
          ProfessionRegistry.instance.isConfirmed(profile.profession),
      hasBio: profile.bio.trim().length >= minBioLength,
    );
  }
}

/// One completable item on the Professional Profile.
class ProfileFieldSpec {
  /// Stable key — used by analytics and deep links. Never rename.
  final String key;
  final String label;
  final ProfileSection section;

  /// Relative contribution to the percentage. Only `active` weights count.
  final int weight;
  final ProfileFieldStatus status;

  /// Shown when the item is incomplete ("Helps clients recognise you").
  final String hint;

  final bool Function(ProfileFacts) _satisfiedBy;

  const ProfileFieldSpec({
    required this.key,
    required this.label,
    required this.section,
    required this.weight,
    required this.hint,
    required bool Function(ProfileFacts) satisfiedBy,
    this.status = ProfileFieldStatus.active,
  }) : _satisfiedBy = satisfiedBy;

  bool isSatisfied(ProfileFacts facts) =>
      status == ProfileFieldStatus.active && _satisfiedBy(facts);

  bool get isActive => status == ProfileFieldStatus.active;
}

/// One evaluated item (spec + whether it is done).
class ProfileFieldState {
  final ProfileFieldSpec spec;
  final bool complete;

  const ProfileFieldState(this.spec, this.complete);
}

/// The declarative source of truth for what "a complete profile" means.
///
/// ADDING A FUTURE FIELD is a single entry in [fields]:
///   1. add the spec with `status: ProfileFieldStatus.comingSoon`,
///   2. when it ships, add its fact to [ProfileFacts] and flip the status.
/// Nothing else in the app changes — the hub screen, the ring, the checklist
/// and the become-a-provider gate all read this list.
class ProfileCompletion {
  ProfileCompletion._({
    required this.percent,
    required this.items,
    required this.nextStep,
  });

  /// 0–100, computed over ACTIVE fields only.
  final int percent;

  /// Every declared field with its current state, registry order.
  final List<ProfileFieldState> items;

  /// The highest-value thing the user could do next. Null at 100%.
  final ProfileFieldSpec? nextStep;

  bool get isComplete => percent >= 100;

  List<ProfileFieldState> get activeItems =>
      items.where((i) => i.spec.isActive).toList(growable: false);

  List<ProfileFieldSpec> get comingSoon => items
      .where((i) => !i.spec.isActive)
      .map((i) => i.spec)
      .toList(growable: false);

  List<ProfileFieldState> sectionItems(ProfileSection section) => items
      .where((i) => i.spec.isActive && i.spec.section == section)
      .toList(growable: false);

  static ProfileCompletion evaluate(ProfileFacts facts) {
    final items = fields.map((f) => ProfileFieldState(f, f.isSatisfied(facts))).toList();

    var earned = 0;
    var total = 0;
    for (final item in items) {
      if (!item.spec.isActive) continue;
      total += item.spec.weight;
      if (item.complete) earned += item.spec.weight;
    }
    final percent = total == 0 ? 100 : ((earned / total) * 100).round();

    ProfileFieldSpec? next;
    for (final item in items) {
      if (!item.spec.isActive || item.complete) continue;
      if (next == null || item.spec.weight > next.weight) next = item.spec;
    }

    return ProfileCompletion._(percent: percent, items: items, nextStep: next);
  }

  /// Convenience for callers that already hold the profile row.
  static ProfileCompletion of(UserModel? profile, {String? fallbackPhone}) =>
      evaluate(ProfileFacts.from(profile, fallbackPhone: fallbackPhone));

  // ── The registry ─────────────────────────────────────────────────────────
  // Active weights sum to 100 by construction; the maths does not depend on
  // that, but keeping it true makes each weight readable as "percentage
  // points" when reasoning about the ring.
  static final List<ProfileFieldSpec> fields = [
    // ── Personal ───────────────────────────────────────────────────────────
    ProfileFieldSpec(
      key: 'photo',
      label: 'Profile photo',
      section: ProfileSection.personal,
      weight: 20,
      hint: 'Clients hire faces they recognise',
      satisfiedBy: (f) => f.hasPhoto,
    ),
    ProfileFieldSpec(
      key: 'name',
      label: 'Full name',
      section: ProfileSection.personal,
      weight: 10,
      hint: 'Your real first and last name',
      satisfiedBy: (f) => f.hasName,
    ),
    ProfileFieldSpec(
      key: 'phone',
      label: 'Phone number',
      section: ProfileSection.personal,
      weight: 20,
      // Deliberately points at Account: the number is managed there, behind
      // device authentication, and must never gain a second editor.
      hint: 'Verified in Account · needed to get paid',
      satisfiedBy: (f) => f.hasPhone,
    ),

    // ── Professional ───────────────────────────────────────────────────────
    ProfileFieldSpec(
      key: 'profession',
      label: 'Profession',
      section: ProfileSection.professional,
      weight: 25,
      hint: 'How clients find and compare you',
      satisfiedBy: (f) => f.hasConfirmedProfession,
    ),
    ProfileFieldSpec(
      key: 'bio',
      label: 'About you',
      section: ProfileSection.professional,
      weight: 25,
      hint: 'A short intro — what you do and how long you have done it',
      satisfiedBy: (f) => f.hasBio,
    ),

    // ── Declared for later milestones ──────────────────────────────────────
    // Excluded from the percentage until their status flips to active. They
    // exist here TODAY so the architecture, the checklist UI and the section
    // model never have to be redesigned to accept them.
    ProfileFieldSpec(
      key: 'service_area',
      label: 'Service area',
      section: ProfileSection.professional,
      weight: 15,
      hint: 'Where you work',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'years_experience',
      label: 'Years of experience',
      section: ProfileSection.professional,
      weight: 10,
      hint: 'How long you have worked in your trade',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'skills',
      label: 'Skills',
      section: ProfileSection.professional,
      weight: 10,
      hint: 'What you specialise in',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'portfolio',
      label: 'Portfolio',
      section: ProfileSection.professional,
      weight: 15,
      hint: 'Photos of work you have completed',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'business_name',
      label: 'Business name',
      section: ProfileSection.professional,
      weight: 5,
      hint: 'If you trade under a business',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'certificates',
      label: 'Certificates',
      section: ProfileSection.professional,
      weight: 10,
      hint: 'Qualifications and licences',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
    ProfileFieldSpec(
      key: 'languages',
      label: 'Languages',
      section: ProfileSection.professional,
      weight: 5,
      hint: 'Languages you can work in',
      status: ProfileFieldStatus.comingSoon,
      satisfiedBy: (_) => false,
    ),
  ];
}
