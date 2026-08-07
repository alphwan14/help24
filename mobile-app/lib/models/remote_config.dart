/// The client configuration contract — the Dart half of the pair.
///
/// WHY A COMPILED COPY EXISTS AT ALL
/// ---------------------------------
/// The backend is the authority, but it is not a dependency: this app must open
/// on a matatu with no signal, on a cold install, while Render is cold-starting.
/// So every value has a compiled default that is EXACTLY today's behaviour, and
/// the served document only ever overrides it. The worst possible outcome of the
/// whole configuration plane is the app behaving precisely as it does now — the
/// same contract `ReferenceRegistry` already keeps for locations and professions.
///
/// The defaults here are asserted byte-equivalent to
/// `backend/src/app-config/client-config.ts` by the golden test in
/// `test/remote_config_test.dart`. Change one, change both.
///
/// SEMANTICS THAT MUST NOT DRIFT
/// -----------------------------
///  • A kill switch is TRUE = enabled, and an ABSENT switch means enabled.
///    Configuration trouble must never disable commerce (fail-open).
///  • Maintenance is the deliberate exception: it shows only on an explicit
///    fetched `active: true` (fail-closed), because failing to show a
///    maintenance banner is harmless while wrongly showing one is not.
///  • Every field parses through a type guard. A wrong-typed value in the SQL
///    editor degrades exactly one field, never the document.
library;

/// Feature kill switches. Each gates one user action with friendly copy — never
/// a crash path, never a hidden screen.
class KillSwitches {
  const KillSwitches({
    required this.payments,
    required this.promotions,
    required this.posting,
    required this.applications,
  });

  final bool payments;
  final bool promotions;
  final bool posting;
  final bool applications;

  static const KillSwitches defaults = KillSwitches(
    payments: true,
    promotions: true,
    posting: true,
    applications: true,
  );

  factory KillSwitches.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return KillSwitches(
      payments: _boolOr(json['payments'], defaults.payments),
      promotions: _boolOr(json['promotions'], defaults.promotions),
      posting: _boolOr(json['posting'], defaults.posting),
      applications: _boolOr(json['applications'], defaults.applications),
    );
  }

  Map<String, dynamic> toJson() => {
        'payments': payments,
        'promotions': promotions,
        'posting': posting,
        'applications': applications,
      };
}

/// Planned-downtime notice. Advisory only in Phase 1: it informs, it does not
/// lock the app — the backend's own guards remain the real boundary.
class MaintenanceConfig {
  const MaintenanceConfig({required this.active, required this.message});

  final bool active;
  final String message;

  static const MaintenanceConfig defaults =
      MaintenanceConfig(active: false, message: '');

  factory MaintenanceConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return MaintenanceConfig(
      active: _boolOr(json['active'], defaults.active),
      message: _stringOr(json['message'], defaults.message),
    );
  }

  /// An active notice with nothing to say is not a notice.
  bool get shouldShow => active && message.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'active': active, 'message': message};
}

/// Minimum supported app version. Empty string = no gate.
class MinVersionConfig {
  const MinVersionConfig({
    required this.soft,
    required this.hard,
    required this.message,
    required this.storeUrl,
  });

  /// Below this: a dismissible "update available" banner.
  final String soft;

  /// Below this: a blocking screen, applied only at cold start.
  final String hard;
  final String message;
  final String storeUrl;

  static const MinVersionConfig defaults =
      MinVersionConfig(soft: '', hard: '', message: '', storeUrl: '');

  factory MinVersionConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return MinVersionConfig(
      soft: _stringOr(json['soft'], defaults.soft),
      hard: _stringOr(json['hard'], defaults.hard),
      message: _stringOr(json['message'], defaults.message),
      storeUrl: _stringOr(json['store_url'], defaults.storeUrl),
    );
  }

  Map<String, dynamic> toJson() =>
      {'soft': soft, 'hard': hard, 'message': message, 'store_url': storeUrl};
}

/// A product announcement. Dismissal is remembered per [id], so reusing an id
/// keeps it dismissed and a new id shows again.
class AnnouncementConfig {
  const AnnouncementConfig({
    required this.id,
    required this.active,
    required this.message,
    required this.url,
  });

  final String id;
  final bool active;
  final String message;
  final String url;

  static const AnnouncementConfig defaults =
      AnnouncementConfig(id: '', active: false, message: '', url: '');

  factory AnnouncementConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return AnnouncementConfig(
      id: _stringOr(json['id'], defaults.id),
      active: _boolOr(json['active'], defaults.active),
      message: _stringOr(json['message'], defaults.message),
      url: _stringOr(json['url'], defaults.url),
    );
  }

  /// An announcement with no id could never be dismissed, so it is not shown.
  bool get shouldShow =>
      active && id.trim().isNotEmpty && message.trim().isNotEmpty;

  Map<String, dynamic> toJson() =>
      {'id': id, 'active': active, 'message': message, 'url': url};
}

/// Payment polling budget. Both STK loops (escrow and promotion) read these.
///
/// These are wall-clock measurements of Safaricom's STK prompt lifetime, not
/// refresh intervals — see the note on PaymentScreen._startPolling. Tuning them
/// is exactly the kind of operational change that should not need a release.
class PaymentsTuning {
  const PaymentsTuning({
    required this.pollIntervalSeconds,
    required this.pollBudget,
  });

  final int pollIntervalSeconds;
  final int pollBudget;

  // 24 × 5s ≈ 2 minutes — today's compiled behaviour.
  static const PaymentsTuning defaults =
      PaymentsTuning(pollIntervalSeconds: 5, pollBudget: 24);

  factory PaymentsTuning.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return PaymentsTuning(
      // Clamped on both sides. The backend clamps too; this is the client's own
      // floor for the case where an older/newer server sends something else.
      pollIntervalSeconds: _intOr(
        json['poll_interval_seconds'],
        defaults.pollIntervalSeconds,
        min: 2,
        max: 60,
      ),
      pollBudget:
          _intOr(json['poll_budget'], defaults.pollBudget, min: 6, max: 120),
    );
  }

  Duration get pollInterval => Duration(seconds: pollIntervalSeconds);

  Map<String, dynamic> toJson() => {
        'poll_interval_seconds': pollIntervalSeconds,
        'poll_budget': pollBudget,
      };
}

/// Listing rules that are pure duration policy.
class ListingsTuning {
  const ListingsTuning({required this.urgentWindowMinutes});

  final int urgentWindowMinutes;

  // post_service.dart: urgent_expires_at = now + 1h.
  static const ListingsTuning defaults = ListingsTuning(urgentWindowMinutes: 60);

  factory ListingsTuning.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return ListingsTuning(
      urgentWindowMinutes: _intOr(
        json['urgent_window_minutes'],
        defaults.urgentWindowMinutes,
        min: 5,
        max: 24 * 60,
      ),
    );
  }

  Duration get urgentWindow => Duration(minutes: urgentWindowMinutes);

  Map<String, dynamic> toJson() =>
      {'urgent_window_minutes': urgentWindowMinutes};
}

/// The whole client configuration document.
class RemoteConfig {
  const RemoteConfig({
    required this.killSwitches,
    required this.maintenance,
    required this.minVersion,
    required this.announcement,
    required this.payments,
    required this.listings,
  });

  final KillSwitches killSwitches;
  final MaintenanceConfig maintenance;
  final MinVersionConfig minVersion;
  final AnnouncementConfig announcement;
  final PaymentsTuning payments;
  final ListingsTuning listings;

  /// Today's shipped behaviour, exactly. The floor under every failure mode.
  static const RemoteConfig defaults = RemoteConfig(
    killSwitches: KillSwitches.defaults,
    maintenance: MaintenanceConfig.defaults,
    minVersion: MinVersionConfig.defaults,
    announcement: AnnouncementConfig.defaults,
    payments: PaymentsTuning.defaults,
    listings: ListingsTuning.defaults,
  );

  /// Parse a `/config` response body's `config` object. Never throws: anything
  /// unrecognisable resolves to the defaults, field by field.
  factory RemoteConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final ops = _mapOr(json['ops']);
    final tuning = _mapOr(json['tuning']);
    return RemoteConfig(
      killSwitches: KillSwitches.fromJson(_mapOr(ops?['kill_switches'])),
      maintenance: MaintenanceConfig.fromJson(_mapOr(ops?['maintenance'])),
      minVersion: MinVersionConfig.fromJson(_mapOr(ops?['min_version'])),
      announcement: AnnouncementConfig.fromJson(_mapOr(ops?['announcement'])),
      payments: PaymentsTuning.fromJson(_mapOr(tuning?['payments'])),
      listings: ListingsTuning.fromJson(_mapOr(tuning?['listings'])),
    );
  }

  Map<String, dynamic> toJson() => {
        'ops': {
          'kill_switches': killSwitches.toJson(),
          'maintenance': maintenance.toJson(),
          'min_version': minVersion.toJson(),
          'announcement': announcement.toJson(),
        },
        'tuning': {
          'payments': payments.toJson(),
          'listings': listings.toJson(),
        },
      };
}

// ── guards ───────────────────────────────────────────────────────────────────
// Every one of these answers the same question: "is this the type I expected?"
// and returns the default when it is not. One bad value never spreads.

bool _boolOr(dynamic value, bool fallback) => value is bool ? value : fallback;

String _stringOr(dynamic value, String fallback) =>
    value is String ? value : fallback;

int _intOr(dynamic value, int fallback, {required int min, required int max}) {
  final num? n = value is num ? value : null;
  if (n == null || !n.isFinite) return fallback;
  return n.round().clamp(min, max);
}

Map<String, dynamic>? _mapOr(dynamic value) =>
    value is Map<String, dynamic> ? value : null;

/// Compare two "major.minor.patch" strings.
///
/// Returns &lt;0 when [a] is older than [b], 0 when equal, &gt;0 when newer.
/// Missing segments read as 0, so "1.2" == "1.2.0". A non-numeric or empty
/// segment reads as 0 rather than throwing — a malformed version must not be
/// able to lock anyone out of the app.
int compareVersions(String a, String b) {
  final left = _segments(a);
  final right = _segments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

List<int> _segments(String version) {
  // Tolerates build metadata ("1.2.3+45") and pre-release suffixes ("1.2.3-rc1")
  // by reading only the leading digits of each segment: package_info_plus
  // reports a version string, and a build suffix must not read as "older".
  return version.trim().split('.').map((part) {
    final match = RegExp(r'^\d+').firstMatch(part.trim());
    return match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0);
  }).toList();
}

/// Is [current] below [minimum]? An empty [minimum] is "no gate" and always
/// answers false — that is what makes an absent/failed config safe.
bool isBelowVersion(String current, String minimum) {
  if (minimum.trim().isEmpty) return false;
  if (current.trim().isEmpty) return false; // unknown version is never blocked
  return compareVersions(current, minimum) < 0;
}
