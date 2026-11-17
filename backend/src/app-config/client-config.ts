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
  /**
   * Public photos load through img.help24.co.ke (workers/help24-img, cached at
   * Cloudflare's edge). Off: the app goes back to the direct Supabase Storage
   * URLs it stores. Stored URLs never change either way.
   */
  image_cdn: boolean;
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
  /** The download page; '' falls back to the client's compiled URL. */
  store_url: string;
  /**
   * The in-app updater (app 1.0.13+, sideloaded builds): the newest APK, its
   * SHA-256 and size. The app downloads it, refuses it unless the checksum
   * matches, and opens Android's install prompt. All three or none; with none,
   * the Update button opens [store_url] as before. See validateMinVersionDownload.
   */
  apk_url: string;
  sha256: string;
  size_bytes: number;
}

/** Where an APK may be downloaded from: this repo's GitHub releases, or help24.co.ke. */
const APK_HOSTS: Array<{ host: string; path: RegExp }> = [
  { host: 'github.com', path: /^\/alphwan14\/help24\/releases\/download\/[^/]+\/[^/]+\.apk$/ },
  { host: 'help24.co.ke', path: /^\/.+/ },
];

/**
 * Why an in-app update's download fields cannot be saved, or null when they
 * can. They travel together: a URL without its checksum would be installed
 * unverified (the app refuses that), and a checksum without its size cannot
 * be shown before downloading.
 */
export function validateMinVersionDownload(v: { apk_url?: unknown; sha256?: unknown; size_bytes?: unknown }): string | null {
  if (v.apk_url !== undefined && typeof v.apk_url !== 'string') return 'min_version.apk_url must be text.';
  if (v.sha256 !== undefined && typeof v.sha256 !== 'string') return 'min_version.sha256 must be text.';
  if (v.size_bytes !== undefined && (typeof v.size_bytes !== 'number' || !Number.isInteger(v.size_bytes))) {
    return 'min_version.size_bytes must be a whole number of bytes.';
  }
  const url = typeof v.apk_url === 'string' ? v.apk_url.trim() : '';
  const sha = typeof v.sha256 === 'string' ? v.sha256.trim() : '';
  const size = typeof v.size_bytes === 'number' ? v.size_bytes : 0;
  if (!url && !sha && size === 0) return null;
  if (!url || !sha || !size) return 'min_version.apk_url, sha256 and size_bytes go together: fill all three, or none.';
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return 'min_version.apk_url must be a full https:// link.';
  }
  if (parsed.protocol !== 'https:' || !APK_HOSTS.some((h) => parsed.hostname === h.host && h.path.test(parsed.pathname))) {
    return 'min_version.apk_url must be a GitHub release asset of alphwan14/help24 or a help24.co.ke link.';
  }
  if (!/^[0-9a-fA-F]{64}$/.test(sha)) return 'min_version.sha256 must be the 64-character SHA-256 of the APK.';
  if (size < 1_000_000 || size > 500_000_000) return 'min_version.size_bytes must be the APK size in bytes (1 MB to 500 MB).';
  return null;
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
      image_cdn: true,
    },
    maintenance: { active: false, message: '' },
    min_version: { soft: '', hard: '', message: '', store_url: '', apk_url: '', sha256: '', size_bytes: 0 },
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
