import { alert } from './alert-email.fixtures';
import {
  AlertSeen,
  CONSOLE_URL,
  DEFAULT_ALERT_EMAIL_SETTINGS,
  alertEmail,
  consoleLink,
  digestDue,
  forAdmin,
  newAlerts,
  plainTitle,
  readSettings,
  testEmail,
} from './alert-email-rules';


const seen = (rows: AlertSeen[]) => new Map(rows.map((r) => [r.alert_id, r]));

describe('alert email rules', () => {
  it('an alert is new when it first appears, when a newer record joins, or when more records join; never just for still being there', () => {
    const a = alert();
    expect(newAlerts([a], seen([]))).toEqual([a]);
    expect(newAlerts([a], seen([{ alert_id: a.id, latest_at: a.latest_at, item_count: 1 }]))).toEqual([]);

    const newer = alert({ latest_at: '2026-11-11T07:00:00.000Z', count: 1 });
    expect(newAlerts([newer], seen([{ alert_id: a.id, latest_at: a.latest_at, item_count: 1 }]))).toEqual([newer]);

    // An older record crossing a threshold: the newest time does not move, the count does.
    const more = alert({ count: 2 });
    expect(newAlerts([more], seen([{ alert_id: a.id, latest_at: a.latest_at, item_count: 1 }]))).toEqual([more]);

    // One record resolved: fewer, not new.
    const fewer = alert({ count: 1, latest_at: '2026-11-11T05:00:00.000Z' });
    expect(newAlerts([fewer], seen([{ alert_id: a.id, latest_at: a.latest_at, item_count: 2 }]))).toEqual([]);
  });

  it('reviewed alerts and low-priority marketplace health are never emailed right away', () => {
    const reviewed = alert({ review: { note: 'Known', admin_email: 'x@y.z', admin_role: 'super_admin', at: '2026-11-11T06:00:00Z' } });
    const low = alert({ id: 'requests_unanswered', category: 'marketplace', priority: 'low' });
    expect(newAlerts([reviewed, low], seen([]))).toEqual([]);
  });

  it('each admin hears only about the kinds they chose', () => {
    const money = alert({ id: 'payout_failed', category: 'financial', priority: 'high' });
    const support = alert();
    expect(forAdmin([money, support], { frequency: 'instant', categories: ['support'] })).toEqual([support]);
    expect(forAdmin([money, support], DEFAULT_ALERT_EMAIL_SETTINGS)).toEqual([money, support]);
  });

  it('the morning summary is due once a day, from 08:00 Nairobi (05:00 UTC)', () => {
    expect(digestDue(new Date('2026-11-11T04:59:00Z'), null)).toBe(false); // 07:59 Nairobi
    expect(digestDue(new Date('2026-11-11T05:00:00Z'), null)).toBe(true);
    expect(digestDue(new Date('2026-11-11T05:00:00Z'), '2026-11-10')).toBe(true);
    expect(digestDue(new Date('2026-11-11T18:00:00Z'), '2026-11-11')).toBe(false);
    expect(digestDue(new Date('2026-11-11T22:00:00Z'), '2026-11-11')).toBe(false); // 01:00 on the 12th: not yet
    expect(digestDue(new Date('2026-11-12T05:30:00Z'), '2026-11-11')).toBe(true); // 08:30 on the 12th
  });

  it('settings as stored are cleaned: unknown kinds dropped, no row = right away for everything', () => {
    expect(readSettings(null)).toEqual(DEFAULT_ALERT_EMAIL_SETTINGS);
    expect(readSettings({ frequency: 'daily', categories: ['support', 'bogus'] })).toEqual({ frequency: 'daily', categories: ['support'] });
    expect(readSettings({ frequency: 'hourly', categories: null })).toEqual(DEFAULT_ALERT_EMAIL_SETTINGS);
  });

  it('an email names the kind of alert, how many, and where to look; never a member, a message or an amount', () => {
    const mail = alertEmail('new', [alert(), alert({ id: 'payout_failed', category: 'financial', priority: 'high', title: '2 payouts failed — provider not paid', action: 'Call the provider', href: '/dashboard/payments/escrow' })]);
    const all = `${mail.subject}\n${mail.text}\n${mail.html}`;
    for (const secret of ['Mary', 'Wanjiku', '0712345678', 'Payout not received', '2500', '2,500']) expect(all).not.toContain(secret);
    expect(all).not.toMatch(/[—–]/);
    expect(mail.subject).toBe('Help24: 2 things need attention');
    expect(mail.text).toContain('2 payouts failed: provider not paid');
    expect(mail.text).toContain(`Reply from the Inbox: ${CONSOLE_URL}/dashboard/inbox`);
    expect(mail.html).toContain(`href="${CONSOLE_URL}/dashboard/payments/escrow"`);
    expect(mail.text).toContain('/dashboard/settings');
  });

  it('one alert puts its title in the subject; the morning summary says so', () => {
    expect(alertEmail('new', [alert()]).subject).toBe('Help24: 1 support conversation is waiting for a reply');
    expect(alertEmail('digest', [alert()]).subject).toBe('Help24 morning summary: 1 thing needs attention');
    expect(testEmail().subject).toBe('Help24: test alert email');
  });

  it('links only ever lead into the console, filters and anchors kept', () => {
    expect(consoleLink('/dashboard/disputes?status=escalated')).toBe(`${CONSOLE_URL}/dashboard/disputes?status=escalated`);
    expect(consoleLink('/dashboard/users/admins#unlinked-logins')).toBe(`${CONSOLE_URL}/dashboard/users/admins#unlinked-logins`);
    expect(consoleLink('https://evil.example/x')).toBe(`${CONSOLE_URL}/dashboard`);
    expect(consoleLink('/dashboard/"><script>')).toBe(`${CONSOLE_URL}/dashboard`);
    expect(plainTitle('Review — cleanup is designed')).toBe('Review: cleanup is designed');
  });
});
