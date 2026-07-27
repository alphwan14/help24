import { FeedSignal, TimeOfDayWindow } from '../types';

/**
 * Is `hour` inside `[start, end)`? Windows may wrap midnight, e.g. `[21, 6]`
 * meaning 21:00–05:59 — the night window has to be expressible, and it is the
 * one that matters most (emergency, towing, security).
 */
export function isHourInWindow(hour: number, window: TimeOfDayWindow): boolean {
  const [start, end] = window.hours;
  if (!Number.isFinite(start) || !Number.isFinite(end)) return false;
  if (start === end) return false;
  return start < end ? hour >= start && hour < end : hour >= start || hour < end;
}

/**
 * Signal 11 — Time of day. "Use sensible weighting."
 *
 * Morning brings cleaning, plumbing and electrical work; midday brings food and
 * delivery; evening brings tutors and security; night brings the emergencies.
 * A category in the current window scores 1.0.
 *
 * Everything else scores `baseline` (0.35) rather than 0. That floor is
 * deliberate and it is why this is the lightest weight in the engine: the hour
 * of the day is a weak prior, and a hard zero would mean a tutoring request
 * 300 m away is unfindable at 9am because of a table someone typed. Time of day
 * should tilt a feed, never gate it.
 *
 * `localHour` is the VIEWER's local hour (their device offset, forwarded by the
 * client), not the server's. A Nairobi user at 07:00 must not be ranked as if
 * it were 04:00 UTC.
 */
export const timeOfDaySignal: FeedSignal = {
  key: 'timeOfDay',
  label: 'Time of day',

  weight: (config) => config.weights.timeOfDay,

  score: (candidate, viewer, config) => {
    const cfg = config.timeOfDay;
    const hour = Number.isFinite(viewer.localHour) ? Math.floor(viewer.localHour) % 24 : 0;
    const category = (candidate.category ?? '').trim().toLowerCase();
    if (!category) return cfg.baseline;

    for (const window of cfg.windows) {
      if (!isHourInWindow(hour, window)) continue;
      if (window.categories.some((c) => c.trim().toLowerCase() === category)) return 1;
    }
    return cfg.baseline;
  },

  detail: (_candidate, viewer) => ({ localHour: viewer.localHour }),
};
