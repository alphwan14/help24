import { FeedSignal } from '../types';
import { clamp, saturate } from '../curves';

/**
 * Signal 6 — Engagement quality.
 *
 * The spec is explicit: *"Not popularity. Quality."* Two design choices follow.
 *
 * **1. Intent beats attention.** Applications, saves and messages are people
 * committing something. Views are not, so raw `view_count` contributes ZERO —
 * it is carried in `post_engagement` for analytics and future signals only. A
 * post cannot climb the feed by being looked at.
 *
 * **2. Crowding is a negative.** Past `crowdThreshold` applications the score
 * is scaled by `threshold / applications`. This looks counter-intuitive next to
 * "posts with applications receive ranking adjustments" until you read the
 * product principle the brief closes on:
 *
 *     "The recommendation engine should optimize for successful matches,
 *      not just clicks or views."
 *
 * Being applicant #31 on a request is not a successful match, it is a wasted
 * evening — for the applicant AND for the poster, who now has to read 31
 * messages. Some engagement proves a listing is real and worth answering;
 * runaway engagement means the opportunity is effectively gone. Only requests
 * and jobs crowd this way; an `offer` is a provider advertising capacity, where
 * interest is pure positive evidence.
 *
 * Both the threshold and every curve constant live in `feed_settings`, so this
 * judgement is tunable with a SQL update if the data disagrees.
 */
export const engagementSignal: FeedSignal = {
  key: 'engagement',
  label: 'Engagement',

  weight: (config) => config.weights.engagement,

  score: (candidate, _viewer, config) => {
    const cfg = config.engagement;

    const intent =
      cfg.applicationsWeight * saturate(candidate.applicationCount, cfg.applicationsK) +
      cfg.savesWeight * saturate(candidate.saveCount, cfg.savesK) +
      cfg.messagesWeight * saturate(candidate.messageCount, cfg.messagesK);

    const crowds = candidate.type === 'request' || candidate.type === 'job';
    if (!crowds || candidate.applicationCount <= cfg.crowdThreshold) {
      return clamp(intent);
    }

    const crowdingFactor = cfg.crowdThreshold / candidate.applicationCount;
    return clamp(intent * crowdingFactor);
  },

  detail: (candidate, _viewer, config) => ({
    applications: candidate.applicationCount,
    saves: candidate.saveCount,
    messages: candidate.messageCount,
    views: candidate.viewCount,
    crowded:
      (candidate.type === 'request' || candidate.type === 'job') &&
      candidate.applicationCount > config.engagement.crowdThreshold,
  }),
};
