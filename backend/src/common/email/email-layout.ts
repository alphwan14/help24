/**
 * The one frame every Help24 email is built in.
 *
 * Modern and quiet, like the console: a warm paper page, the Help24 tile and
 * name above a white card, one heading, the words, at most one button, and a
 * small footer. It mirrors the admin dashboard's Supabase Auth emails
 * (admin-dashboard/supabase-auth-emails), so an alert, a support reply and a
 * password reset all look like the same company.
 *
 * Built for email clients, not browsers: tables for layout, every style inline,
 * no web fonts, no scripts, no tracking. The only image is the logo, with alt
 * text, so a client that blocks images still shows "Help24". The full link is
 * printed under every button for clients that strip them.
 */

/** Served by the admin dashboard (public/email-logo.png): the dark tile, which
 *  stays crisp on white and in dark-mode mail apps alike. */
export const EMAIL_LOGO_URL = 'https://admin.help24.co.ke/email-logo.png';
export const SITE_URL = 'https://help24.co.ke';

const C = {
  page: '#FAF9F7',
  card: '#FFFFFF',
  border: '#E3E0D9',
  ink: '#12161A',
  secondary: '#585F66',
  tertiary: '#686F77',
  link: '#96620A',
  divider: '#EFECE6',
};

const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

export const escapeHtml = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export interface EmailPage {
  /** The <title>, usually the subject. */
  title: string;
  /** The grey line mail apps show after the subject in the inbox list. */
  preheader?: string;
  /** Under the name in the header: "Admin alerts", "Support". */
  eyebrow: string;
  /** The card's heading, already escaped. Omitted for a personal reply. */
  heading?: string;
  /** The card's body, already HTML (use [paragraphs] or [rows]). */
  body: string;
  /** One button, at most. */
  action?: { label: string; url: string };
  /** The small print under the card, already HTML. */
  footer: string;
}

/** Plain text into paragraphs: blank lines split them, single newlines break. */
export function paragraphs(text: string): string {
  return text
    .trim()
    .split(/\n{2,}/)
    .map((p) => `<p style="margin:0 0 14px;font-family:${FONT};font-size:15px;line-height:24px;color:${C.ink};">${escapeHtml(p).replace(/\n/g, '<br>')}</p>`)
    .join('');
}

/** A short line of body copy in the secondary tone. */
export function lead(text: string): string {
  return `<p style="margin:0 0 20px;font-family:${FONT};font-size:15px;line-height:24px;color:${C.secondary};">${escapeHtml(text)}</p>`;
}

/** A list of items, each a title with a link under it, divided by hairlines. */
export function rows(items: Array<{ title: string; action: string; url: string }>): string {
  return (
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-top:1px solid ${C.divider};">` +
    items
      .map(
        (i) =>
          `<tr><td style="padding:14px 0;border-bottom:1px solid ${C.divider};font-family:${FONT};">` +
          `<div style="font-size:15px;line-height:22px;font-weight:600;color:${C.ink};">${escapeHtml(i.title)}</div>` +
          `<a href="${escapeHtml(i.url)}" target="_blank" style="display:inline-block;margin-top:2px;font-size:14px;line-height:20px;color:${C.link};text-decoration:none;">${escapeHtml(i.action)} &rarr;</a>` +
          '</td></tr>',
      )
      .join('') +
    '</table>'
  );
}

/** A signature line: the team's name, bold, after the words. */
export function signature(name: string): string {
  return `<p style="margin:22px 0 0;font-family:${FONT};font-size:15px;line-height:22px;font-weight:600;color:${C.ink};">${escapeHtml(name)}</p>`;
}

export function emailPage(p: EmailPage): string {
  const button = p.action
    ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 0;">` +
      `<tr><td align="center" bgcolor="${C.ink}" style="border-radius:10px;">` +
      `<a href="${escapeHtml(p.action.url)}" target="_blank" style="display:inline-block;padding:13px 22px;font-family:${FONT};font-size:15px;font-weight:600;line-height:20px;color:#FFFFFF;text-decoration:none;border-radius:10px;">${escapeHtml(p.action.label)}</a>` +
      '</td></tr></table>' +
      `<p style="margin:14px 0 0;font-family:${FONT};font-size:12px;line-height:18px;color:${C.tertiary};">Or open <a href="${escapeHtml(p.action.url)}" target="_blank" style="color:${C.tertiary};word-break:break-all;">${escapeHtml(p.action.url)}</a></p>`
    : '';
  const heading = p.heading
    ? `<h1 style="margin:0 0 12px;font-family:${FONT};font-size:21px;font-weight:700;line-height:28px;letter-spacing:-0.2px;color:${C.ink};">${p.heading}</h1>`
    : '';

  return (
    '<!doctype html><html lang="en"><head>' +
    '<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<meta name="x-apple-disable-message-reformatting">' +
    '<meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light">' +
    `<title>${escapeHtml(p.title)}</title></head>` +
    `<body style="margin:0;padding:0;background:${C.page};">` +
    (p.preheader
      ? `<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${escapeHtml(p.preheader)}</div>`
      : '') +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${C.page};">` +
    '<tr><td align="center" style="padding:32px 16px;">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">' +
    // Header: the tile, the name, the eyebrow.
    '<tr><td style="padding:0 4px 20px;">' +
    '<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' +
    `<td style="padding-right:12px;"><img src="${EMAIL_LOGO_URL}" width="40" height="40" alt="Help24" style="display:block;border:0;border-radius:10px;"></td>` +
    `<td style="font-family:${FONT};font-size:17px;font-weight:700;line-height:20px;color:${C.ink};">Help24<br>` +
    `<span style="font-size:11px;font-weight:600;letter-spacing:1.6px;text-transform:uppercase;color:${C.tertiary};">${escapeHtml(p.eyebrow)}</span></td>` +
    '</tr></table></td></tr>' +
    // The card.
    `<tr><td style="background:${C.card};border:1px solid ${C.border};border-radius:14px;padding:30px 28px;">` +
    heading +
    p.body +
    button +
    '</td></tr>' +
    // Footer.
    `<tr><td style="padding:20px 4px 0;font-family:${FONT};font-size:12px;line-height:18px;color:${C.tertiary};">` +
    p.footer +
    `<div style="margin-top:10px;"><a href="${SITE_URL}" target="_blank" style="color:${C.tertiary};font-weight:600;text-decoration:none;">help24.co.ke</a></div>` +
    '</td></tr>' +
    '</table></td></tr></table></body></html>'
  );
}
