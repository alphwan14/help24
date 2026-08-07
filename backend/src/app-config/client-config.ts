/**
 * The client-facing configuration contract, and its compiled defaults.
 *
 * WHAT THIS IS
 * ------------
 * Every value here is something the mobile app previously compiled in and
 * could only change by shipping an APK through Play review. Serving it makes
 * the value an operational decision instead of a release.
 *
 * WHAT THIS IS NOT
 * ----------------
 * Not a dumping ground. A key earns its place only when a real operational
 * lever needs it — a kill switch someone would actually pull, a threshold
 * someone would actually tune. Server-only tuning (feed ranking, promotion
 * serving) stays in `feed_settings` / `promotion_settings`; this file is the
 * surface CLIENTS read.
 *
 * THE DEFAULTS ARE THE FLOOR ON BOTH SIDES
 * ----------------------------------------
 * The backend merges `app_settings` rows over these defaults; the Flutter app
 * compiles its own byte-equivalent copy (lib/models/remote_config.dart) and
 * falls back to it whenever `/config` is unreachable. Changing a default here
 * therefore requires changing the Dart defaults too — the pair is asserted by
 * the golden values in app-config.service.spec.ts and remote_config_test.dart.
 *
 * SEMANTICS THAT MUST NOT DRIFT
 * -----------------------------
 * • Kill switches are TRUE = enabled, and an ABSENT switch means enabled.
 *   Config unavailability must never disable commerce (fail-open).
 * • Maintenance is the one deliberate exception: it activates only on an
 *   explicit fetched `active: true` (fail-closed against accidents, because
 *   the accident of NOT showing a maintenance banner is harmless).
 * • min_version values are plain "major.minor.patch" strings; empty string
 *   means "no gate". The client compares numerically segment by segment.
 * • Wire shape is snake_case, like every other Help24 payload.
 */

export interface KillSwitches {
  /** Escrow payment initiation (PaymentScreen submit). */
  payments: boolean;
  /** Campaign creation + payment (promote flow checkout). */
  promotions: boolean;
  /** Creating listings of any type. */
  posting: boolean;
  /** Applying / offering services on a listing. */
  applications: boolean;
}

export interface MaintenanceConfig {
  active: boolean;
  /** Shown verbatim in the in-app banner when active. */
  message: string;
}

export interface MinVersionConfig {
  /** Below this: dismissible "update available" banner. '' = no gate. */
  soft: string;
  /** Below this: blocking update screen at next cold start. '' = no gate. */
  hard: string;
  message: string;
  /** Play Store listing; '' falls back to the client's compiled URL. */
  store_url: string;
}

export interface AnnouncementConfig {
  /** Dismissal is remembered per id — reusing an id keeps it dismissed. */
  id: string;
  active: boolean;
  message: string;
  /** Optional "learn more" link; '' = plain banner. */
  url: string;
}

export interface PaymentsTuning {
  /** Seconds between payment-status polls (both escrow and promotion loops). */
  poll_interval_seconds: number;
  /** Polls before the client declares the STK window expired. */
  poll_budget: number;
}

export interface ListingsTuning {
  /** How long a request stays "urgent" after posting. */
  urgent_window_minutes: number;
}

export interface ClientConfig {
  ops: {
    kill_switches: KillSwitches;
    maintenance: MaintenanceConfig;
    min_version: MinVersionConfig;
    announcement: AnnouncementConfig;
  };
  tuning: {
    payments: PaymentsTuning;
    listings: ListingsTuning;
  };
}

/**
 * Compiled defaults = the app's behaviour today, exactly. A fresh deploy with
 * an empty (or absent) `app_settings` table serves these and nothing changes
 * for anyone — that property is what makes this module safe to ship ahead of
 * its migration.
 */
export const DEFAULT_CLIENT_CONFIG: ClientConfig = {
  ops: {
    kill_switches: {
      payments: true,
      promotions: true,
      posting: true,
      applications: true,
    },
    maintenance: { active: false, message: '' },
    min_version: { soft: '', hard: '', message: '', store_url: '' },
    announcement: { id: '', active: false, message: '', url: '' },
  },
  tuning: {
    // payment_screen.dart / promote_listing_flow_screen.dart: 24 × 5 s ≈ 2 min,
    // matched to the STK prompt's own expiry on Safaricom's side.
    payments: { poll_interval_seconds: 5, poll_budget: 24 },
    // post_service.dart: urgent_expires_at = now + 1 h.
    listings: { urgent_window_minutes: 60 },
  },
};

/**
 * The `app_settings` keys this module reads. Anything else in the table is
 * ignored by construction — the response is BUILT from the contract, never
 * from the table, so a server-only row can never leak to clients.
 */
export const CLIENT_CONFIG_KEYS = [
  'ops.kill_switches',
  'ops.maintenance',
  'ops.min_version',
  'ops.announcement',
  'tuning.payments',
  'tuning.listings',
] as const;

export type ClientConfigKey = (typeof CLIENT_CONFIG_KEYS)[number];
