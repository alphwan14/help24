import { emailPage, escapeHtml, lead, rows } from '../../common/email/email-layout';
import { AdminAlert, AlertCategory } from '../alerts/alert-rules';

/**
 * EMAIL ALERTS FOR ADMINS — the rules, with no I/O.
 *
 * The console already derives what needs an admin (alert-rules.ts). This
 * decides which of those an admin hears about by email, and what the email
 * says. Three promises:
 *
 *   1. Only what is NEW. An alert is announced when it first appears, when a
 *      newer record joins it, or when more records join it; never again just
 *      because it is still there. Resolved and reviewed alerts are silent.
 *   2. Nothing private. An email names the kind of alert, how many, and where
 *      in the console to look. No member names, message text or amounts:
 *      emails get forwarded and phones get lost; the console is where details
 *      are read, behind a sign-in.
 *   3. Each admin chooses: which kinds, and right away, a morning summary, or
 *      nothing.
 */

export const ALERT_EMAIL_CATEGORIES: readonly AlertCategory[] = ['financial', 'trust_safety', 'support', 'marketplace'];
export type AlertEmailFrequency = 'instant' | 'daily' | 'off';
export const ALERT_EMAIL_FREQUENCIES: readonly AlertEmailFrequency[] = ['instant', 'daily', 'off'];

export interface AlertEmailSettings {
  frequency: AlertEmailFrequency;
  categories: AlertCategory[];
}

/** An admin who never opened the setting: right away, every kind. */
export const DEFAULT_ALERT_EMAIL_SETTINGS: AlertEmailSettings = {
  frequency: 'instant',
  categories: [...ALERT_EMAIL_CATEGORIES],
};

/** What was last seen of one alert (admin_alert_email_state, migration 141). */
export interface AlertSeen {
  alert_id: string;
  latest_at: string | null;
  item_count: number;
}

/** Links always point at the console's own address, whatever host serves it. */
export const CONSOLE_URL = 'https://admin.help24.co.ke';
export const ALERTS_FROM = 'Help24 Admin <alerts@help24.co.ke>';
/** Morning summaries go out from this hour, Nairobi time. */
export const DIGEST_HOUR = 8;

const time = (iso: string | null | undefined) => (iso ? Date.parse(iso) : NaN);

/**
 * The alerts worth an email now: open (no review covers them), not low
 * priority (marketplace health waits for the morning summary), and new since
 * they were last seen.
 */
export function newAlerts(alerts: AdminAlert[], seen: Map<string, AlertSeen>): AdminAlert[] {
  return alerts.filter((a) => {
    if (a.review || a.priority === 'low') return false;
    const before = seen.get(a.id);
    if (!before) return true;
    const latest = time(a.latest_at);
    const known = time(before.latest_at);
    const newerRecord = !Number.isNaN(latest) && (Number.isNaN(known) || latest > known);
    return newerRecord || a.count > before.item_count;
  });
}

/** The alerts in the kinds this admin chose. */
export function forAdmin(alerts: AdminAlert[], settings: AlertEmailSettings): AdminAlert[] {
  return alerts.filter((a) => settings.categories.includes(a.category));
}

/** Nairobi is UTC+3 all year: today's date there and the hour. */
export function nairobiClock(now: Date): { date: string; hour: number } {
  const t = new Date(now.getTime() + 3 * 3_600_000);
  return { date: t.toISOString().slice(0, 10), hour: t.getUTCHours() };
}

/** A morning summary is due once a day, from DIGEST_HOUR Nairobi time. */
export function digestDue(now: Date, lastDigestOn: string | null): boolean {
  const { date, hour } = nairobiClock(now);
  return hour >= DIGEST_HOUR && lastDigestOn !== date;
}

/** Settings as stored, cleaned: unknown kinds dropped, unknown frequency = default. */
export function readSettings(row: { frequency?: unknown; categories?: unknown } | null | undefined): AlertEmailSettings {
  if (!row) return { ...DEFAULT_ALERT_EMAIL_SETTINGS, categories: [...DEFAULT_ALERT_EMAIL_SETTINGS.categories] };
  const frequency = ALERT_EMAIL_FREQUENCIES.includes(row.frequency as AlertEmailFrequency)
    ? (row.frequency as AlertEmailFrequency)
    : DEFAULT_ALERT_EMAIL_SETTINGS.frequency;
  const categories = Array.isArray(row.categories)
    ? ALERT_EMAIL_CATEGORIES.filter((c) => (row.categories as unknown[]).includes(c))
    : [...ALERT_EMAIL_CATEGORIES];
  return { frequency, categories };
}

// ── The email ────────────────────────────────────────────────────────────────

export interface AlertEmailContent {
  subject: string;
  text: string;
  html: string;
}

/** Alert titles use a dash before their consequence; emails read plainer with a colon. */
export function plainTitle(title: string): string {
  return title.replace(/\s+[—–]\s+/g, ': ').replace(/[—–]/g, '-');
}

/** Where an alert opens in the console; only paths inside it. */
export function consoleLink(href: string | null | undefined): string {
  const inside = /^\/dashboard(\/[A-Za-z0-9/_-]*)?(\?[A-Za-z0-9=&_-]*)?(#[A-Za-z0-9_-]*)?$/;
  return typeof href === 'string' && inside.test(href) ? `${CONSOLE_URL}${href}` : `${CONSOLE_URL}/dashboard`;
}

const things = (n: number) => `${n} ${n === 1 ? 'thing needs' : 'things need'} attention`;

const FOOTER_TEXT =
  `You get these emails because of your alert settings in the console: ${CONSOLE_URL}/dashboard/settings\n` +
  'This address does not take replies.\n\nHelp24 Admin';

/**
 * The email for a set of alerts. 'new' = what just arrived; 'digest' = the
 * morning summary of everything still waiting. Only titles and links.
 */
export function alertEmail(kind: 'new' | 'digest', alerts: AdminAlert[]): AlertEmailContent {
  const lines = alerts.map((a) => ({ title: plainTitle(a.title), action: plainTitle(a.action), link: consoleLink(a.href) }));
  const subject =
    kind === 'digest'
      ? `Help24 morning summary: ${things(alerts.length)}`
      : alerts.length === 1
        ? `Help24: ${lines[0].title}`
        : `Help24: ${things(alerts.length)}`;
  const intro = kind === 'digest' ? 'Waiting in the Help24 console this morning:' : 'New in the Help24 console:';

  const text =
    `${intro}\n\n` +
    lines.map((l) => `- ${l.title}\n  ${l.action}: ${l.link}`).join('\n\n') +
    `\n\n${FOOTER_TEXT}`;

  // One alert: its title is the heading and its action the button. Several:
  // a count as the heading, each alert a row, and one way into the console.
  const one = lines.length === 1 ? lines[0] : null;
  const heading =
    kind === 'digest'
      ? `Good morning. ${things(alerts.length).replace(/^./, (c) => c.toUpperCase())}`
      : one
        ? one.title
        : things(alerts.length).replace(/^./, (c) => c.toUpperCase());
  const html = emailPage({
    title: subject,
    preheader: one ? `${one.action} in the Help24 console.` : intro,
    eyebrow: 'Admin alerts',
    heading: escapeHtml(heading),
    body: one && kind === 'new' ? lead(intro.replace(/:$/, '.')) : lead(intro) + rows(lines.map((l) => ({ title: l.title, action: l.action, url: l.link }))),
    action: one && kind === 'new' ? { label: one.action, url: one.link } : { label: 'Open the console', url: `${CONSOLE_URL}/dashboard` },
    footer: FOOTER_HTML,
  });
  return { subject, text, html };
}

/** The "send me a test" email: what an alert will look like, and that it works. */
export function testEmail(): AlertEmailContent {
  const intro = 'This is a test. When something needs you in the console, the email looks like this.';
  const sample = '1 support conversation is waiting for a reply';
  const link = `${CONSOLE_URL}/dashboard/inbox`;
  const subject = 'Help24: test alert email';
  return {
    subject,
    text: `${intro}\n\n- ${sample}\n  Reply from the Inbox: ${link}\n\n${FOOTER_TEXT}`,
    html: emailPage({
      title: subject,
      preheader: 'Alert emails are working.',
      eyebrow: 'Admin alerts',
      heading: escapeHtml(sample),
      body: lead(intro),
      action: { label: 'Reply from the Inbox', url: link },
      footer: FOOTER_HTML,
    }),
  };
}

const FOOTER_HTML =
  `You get these emails because of your <a href="${CONSOLE_URL}/dashboard/settings" target="_blank" style="color:#686F77;">alert settings</a> ` +
  'in the console. This address does not take replies.';
