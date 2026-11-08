/// The steps that turn a new member into a provider who can be hired and paid,
/// shown on Profile as one "Get ready to work" row.
///
/// Order is the order the work depends on: fill in the professional profile
/// (photo, name, phone, profession, about), offer services (a confirmed
/// profession and a phone, see ProviderReadiness), prove who you are, then
/// say where earnings go. Tapping the row opens the first step that is not
/// done. While the row is showing, Profile hides the separate rows for these
/// steps so nothing is listed twice.
enum SetupStep { completeProfile, offerServices, verifyIdentity, addPayout }

class ProfileSetup {
  /// The steps that apply to this member, in order.
  final List<SetupStep> steps;

  /// The steps already done.
  final Set<SetupStep> done;

  const ProfileSetup._(this.steps, this.done);

  int get total => steps.length;
  int get completed => steps.where(done.contains).length;
  bool get isComplete => completed == total;
  double get fraction => total == 0 ? 1 : completed / total;

  /// The first step that is not done, or null when every step is.
  SetupStep? get next {
    for (final step in steps) {
      if (!done.contains(step)) return step;
    }
    return null;
  }

  /// Builds the setup state, or returns null when it cannot be told truthfully.
  ///
  /// [idVerified] and [hasPayout] are null when their read failed. A count
  /// built on a guess would be wrong in one direction or the other, so the row
  /// is hidden instead (and Profile falls back to listing the separate rows).
  ///
  /// [payoutAvailable] is false while payout numbers are switched off on the
  /// server. A step nobody can finish is left out rather than counted as
  /// missing.
  static ProfileSetup? evaluate({
    required bool profileComplete,
    required bool isProvider,
    required bool? idVerified,
    required bool? hasPayout,
    required bool payoutAvailable,
  }) {
    if (idVerified == null) return null;
    if (payoutAvailable && hasPayout == null) return null;
    final steps = <SetupStep>[
      SetupStep.completeProfile,
      SetupStep.offerServices,
      SetupStep.verifyIdentity,
      if (payoutAvailable) SetupStep.addPayout,
    ];
    final done = <SetupStep>{
      if (profileComplete) SetupStep.completeProfile,
      if (isProvider) SetupStep.offerServices,
      if (idVerified) SetupStep.verifyIdentity,
      if (payoutAvailable && hasPayout == true) SetupStep.addPayout,
    };
    return ProfileSetup._(steps, done);
  }
}
