import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import axios from 'axios';

/**
 * Google Routes API (v2 computeRoutes) proxy.
 *
 * WHY THIS LIVES ON THE SERVER
 * Routes is a *web service*. Unlike the Maps SDK for Android it does not honour
 * Android application restrictions (package + SHA-1), so the app's existing key
 * cannot call it, and a key that could would have to ship unrestricted inside
 * the APK — trivially extractable and billable by anyone who pulls it apart.
 * The key stays here; the app sends coordinates and gets back an ETA.
 *
 * COST CONTROL
 * Every Routes call is billable, so this endpoint is deliberately cheap:
 *   - responses are cached by *rounded* coordinates, so a traveller who has
 *     barely moved re-uses the previous answer instead of buying a new one;
 *   - the cache is shared across users, so two providers heading to the same
 *     job pay once;
 *   - the client throttles on top of this (distance + time thresholds).
 *
 * DEGRADATION
 * If GOOGLE_ROUTES_API_KEY is absent the module still boots and answers
 * `{ available: false }` with HTTP 200. That is not an error path: the app
 * falls back to Phase 2 behaviour (straight-line distance, no ETA) and nothing
 * regresses. The backend must never fail to start because a Phase 3 nicety is
 * unconfigured.
 */

export interface RouteResult {
  available: boolean;
  durationSeconds?: number;
  distanceMeters?: number;
  /** Google encoded polyline (overview quality). */
  polyline?: string;
  /** Why a route is unavailable — surfaced for logging, not for end users. */
  reason?: string;
  /** True when served from cache (observability; clients ignore it). */
  cached?: boolean;
}

interface CacheEntry {
  value: RouteResult;
  expiresAt: number;
}

@Injectable()
export class RoutesService {
  private readonly logger = new Logger(RoutesService.name);
  private readonly endpoint =
    'https://routes.googleapis.com/directions/v2:computeRoutes';

  /** Rounded-coordinate cache. ~11 m origin buckets, ~1 m destination. */
  private readonly cache = new Map<string, CacheEntry>();
  private static readonly CACHE_TTL_MS = 60_000;
  private static readonly MAX_CACHE_ENTRIES = 500;

  constructor(private readonly config: ConfigService) {}

  private get apiKey(): string | undefined {
    return this.config.get<string>('google.routesApiKey');
  }

  /**
   * Origin moves constantly, so it is bucketed to 4 dp (~11 m): a traveller
   * inching forward keeps hitting the same cache entry. The destination is
   * fixed, so it keeps 5 dp and stays precise.
   */
  private cacheKey(
    oLat: number,
    oLng: number,
    dLat: number,
    dLng: number,
  ): string {
    return [
      oLat.toFixed(4),
      oLng.toFixed(4),
      dLat.toFixed(5),
      dLng.toFixed(5),
    ].join(',');
  }

  private readCache(key: string): RouteResult | null {
    const hit = this.cache.get(key);
    if (!hit) return null;
    if (hit.expiresAt < Date.now()) {
      this.cache.delete(key);
      return null;
    }
    return { ...hit.value, cached: true };
  }

  private writeCache(key: string, value: RouteResult): void {
    // Bounded: evict oldest insertions once the map grows past the cap. Map
    // preserves insertion order, so the first key is the oldest.
    if (this.cache.size >= RoutesService.MAX_CACHE_ENTRIES) {
      const oldest = this.cache.keys().next();
      if (!oldest.done) this.cache.delete(oldest.value);
    }
    this.cache.set(key, {
      value,
      expiresAt: Date.now() + RoutesService.CACHE_TTL_MS,
    });
  }

  async computeRoute(
    originLat: number,
    originLng: number,
    destLat: number,
    destLng: number,
  ): Promise<RouteResult> {
    const key = this.apiKey;
    if (!key) {
      return { available: false, reason: 'not_configured' };
    }

    const cacheKey = this.cacheKey(originLat, originLng, destLat, destLng);
    const cached = this.readCache(cacheKey);
    if (cached) return cached;

    try {
      const response = await axios.post(
        this.endpoint,
        {
          origin: {
            location: {
              latLng: { latitude: originLat, longitude: originLng },
            },
          },
          destination: {
            location: { latLng: { latitude: destLat, longitude: destLng } },
          },
          travelMode: 'DRIVE',
          routingPreference: 'TRAFFIC_AWARE',
          // OVERVIEW keeps the payload small: this polyline is drawn as a
          // ~240 px thumbnail and a full-screen map, never turn-by-turn.
          polylineQuality: 'OVERVIEW',
          languageCode: 'en-US',
          units: 'METRIC',
        },
        {
          timeout: 6000,
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': key,
            // Field mask is REQUIRED by Routes and is also a billing lever:
            // asking only for what we render keeps us on the cheaper SKU.
            'X-Goog-FieldMask':
              'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
          },
        },
      );

      const route = response.data?.routes?.[0];
      if (!route) {
        const miss: RouteResult = { available: false, reason: 'no_route' };
        // Cache the negative too: an unroutable pair (across water, bad pin)
        // would otherwise be re-billed on every refresh.
        this.writeCache(cacheKey, miss);
        return miss;
      }

      // duration arrives as a protobuf duration string, e.g. "753s".
      const durationSeconds = this.parseDuration(route.duration);
      const result: RouteResult = {
        available: true,
        durationSeconds,
        distanceMeters:
          typeof route.distanceMeters === 'number'
            ? route.distanceMeters
            : undefined,
        polyline: route.polyline?.encodedPolyline,
      };
      this.writeCache(cacheKey, result);
      return result;
    } catch (error) {
      const status = axios.isAxiosError(error)
        ? error.response?.status
        : undefined;
      // Quota/billing/auth problems are the ones worth shouting about; a
      // timeout is routine and must not spam the logs.
      if (status === 403 || status === 429) {
        this.logger.error(
          `Routes API rejected request (status ${status}) — check key restrictions, billing and quota`,
        );
      } else {
        this.logger.warn(
          `Routes API unavailable: ${axios.isAxiosError(error) ? error.message : String(error)}`,
        );
      }
      // Never throw: an ETA is an enhancement. The client keeps its Phase 2
      // straight-line behaviour when this returns unavailable.
      return {
        available: false,
        reason: status ? `http_${status}` : 'unreachable',
      };
    }
  }

  private parseDuration(value: unknown): number | undefined {
    if (typeof value !== 'string') return undefined;
    const match = /^(\d+(?:\.\d+)?)s$/.exec(value.trim());
    if (!match) return undefined;
    return Math.round(parseFloat(match[1]));
  }
}
