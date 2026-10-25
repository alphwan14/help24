/**
 * Help24's Supabase Auth emails — the one source for every template.
 *
 * Supabase Auth is the ADMIN DASHBOARD's credential store (the marketplace signs
 * in with Firebase), so every email here goes to a Help24 administrator. They
 * replace Supabase's defaults, which arrive as "Supabase Auth
 * <noreply@mail.app.supabase.io>" with Supabase's wording.
 *
 * ── What is generated, and where it goes ────────────────────────────────────
 * `node supabase-auth-emails/build.mjs` writes html/<key>.html and
 * html/manifest.json. The HTML is pasted into Supabase (Authentication →
 * Emails → Templates) or sent through the Management API using the field names
 * in the manifest — see docs/runbooks/admin-onboarding-and-identity-linking.md
 * §7. They are NOT wired into supabase/config.toml on purpose: that file has no
 * [auth] section, and adding one would let a future `supabase config push`
 * reset production auth settings to the CLI's defaults.
 *
 * ── Rules every template keeps (asserted by lib/auth-emails.test.mjs) ───────
 *  - Links are Supabase's own `{{ .ConfirmationURL }}` — the one-time token is
 *    checked by Supabase, never by a URL we assemble. The reauthentication email
 *    carries `{{ .Token }}`, a code, and no link at all.
 *  - HTML only: Supabase's hosted mailer sends an HTML body with no plain-text
 *    part, so each template reads correctly with the markup stripped — the full
 *    link is printed as text under the button.
 *  - No scripts, no external CSS, no tracking. One image (the logo), with alt
 *    text, so the email still reads as Help24 with images blocked.
 */
import tokens from "../lib/design-tokens.generated.json" with { type: "json" };

const C = tokens.color.light;

/** Served by the dashboard itself (public/help24.png), so it ships with every deploy. */
export const LOGO_URL = "https://admin.help24.co.ke/help24.png";
export const DASHBOARD_URL = "https://admin.help24.co.ke";
export const SUPPORT_EMAIL = "support@help24.co.ke";

const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const LINK = "{{ .ConfirmationURL }}";

/**
 * `key` matches Supabase's own naming, so the Management API fields are
 * `mailer_subjects_<key>` and `mailer_templates_<key>_content`.
 */
export const TEMPLATES = [
  {
    key: "recovery",
    dashboardName: "Reset password",
    subject: "Reset your Help24 admin password",
    preheader: "Use this link to choose a new password. It works once.",
    heading: "Reset your password",
    paragraphs: [
      "Someone asked to reset the password for the Help24 admin account <strong>{{ .Email }}</strong>. If that was you, choose a new password below.",
      "For your security the link works once, expires soon, and only opens in the browser where you asked for it.",
    ],
    action: { label: "Choose a new password", url: LINK },
    notice: "Didn't ask for this? Ignore this email — your password stays as it is. If these keep arriving, tell us at " + SUPPORT_EMAIL + ".",
  },
  {
    key: "invite",
    dashboardName: "Invite user",
    subject: "You've been invited to Help24 Admin",
    preheader: "An administrator invited you to the Help24 operations dashboard.",
    heading: "You're invited to Help24 Admin",
    paragraphs: [
      "An administrator invited <strong>{{ .Email }}</strong> to the Help24 operations dashboard.",
    ],
    action: { label: "Accept the invitation", url: LINK },
    notice: "Weren't expecting this? Ignore it — nothing happens unless you accept.",
  },
  {
    key: "reauthentication",
    dashboardName: "Reauthentication",
    subject: "Your Help24 verification code",
    preheader: "Enter this code to confirm a change to your admin account.",
    heading: "Confirm it's you",
    paragraphs: [
      "Enter this code to confirm a sensitive change to the Help24 admin account <strong>{{ .Email }}</strong>. It works once and expires shortly.",
    ],
    code: "{{ .Token }}",
    notice: "Didn't start a change? Don't share this code with anyone, and change your password from Settings.",
  },
  {
    key: "magic_link",
    dashboardName: "Magic link",
    subject: "Your Help24 sign-in link",
    preheader: "A one-time link to sign in to Help24 Admin.",
    heading: "Sign in to Help24 Admin",
    paragraphs: ["Use this one-time link to sign in as <strong>{{ .Email }}</strong>."],
    action: { label: "Sign in", url: LINK },
    notice: "Didn't ask to sign in? Ignore this email — nobody can use it without access to your inbox.",
  },
  {
    key: "email_change",
    dashboardName: "Change email address",
    subject: "Confirm your new Help24 email address",
    preheader: "Confirm the new email address for your admin account.",
    heading: "Confirm your new email address",
    paragraphs: [
      "Confirm changing the email address of your Help24 admin account from <strong>{{ .Email }}</strong> to <strong>{{ .NewEmail }}</strong>.",
    ],
    action: { label: "Confirm new address", url: LINK },
    notice: "Didn't ask for this? Don't confirm — and change your password from Settings.",
  },
  {
    key: "confirmation",
    dashboardName: "Confirm signup",
    subject: "Confirm your Help24 email address",
    preheader: "Confirm your email address to finish setting up your admin sign-in.",
    heading: "Confirm your email address",
    paragraphs: ["Confirm <strong>{{ .Email }}</strong> to finish setting up your Help24 admin sign-in."],
    action: { label: "Confirm email address", url: LINK },
    notice: "Didn't sign up? Ignore this email.",
  },
  {
    key: "password_changed_notification",
    dashboardName: "Password changed (security notification)",
    notification: true,
    subject: "Your Help24 admin password was changed",
    preheader: "If this wasn't you, contact Help24 straight away.",
    heading: "Your password was changed",
    // No claim that other devices are already signed out: Supabase ends the
    // other sessions, but access tokens already issued stay valid until they
    // expire (up to an hour by default). And no reset button until the reset
    // flow is deployed and tested — contacting support is the remedy that
    // works today.
    paragraphs: [
      "The password for the Help24 admin account <strong>{{ .Email }}</strong> was just changed. Devices signed in to this account will need to sign in again.",
      "If this was you, there's nothing more to do.",
    ],
    notice: "If you didn't make this change, email " + SUPPORT_EMAIL + " straight away so we can secure your account.",
  },
];

/** Management API fields for one template (PATCH /v1/projects/{ref}/config/auth). */
export function apiFields(t) {
  return {
    subject: `mailer_subjects_${t.key}`,
    content: `mailer_templates_${t.key}_content`,
    // Security notifications are off until enabled per project.
    ...(t.notification ? { enable: `mailer_notifications_${t.key.replace(/_notification$/, "")}_enabled` } : {}),
  };
}

function button({ label, url }) {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 8px;">
                <tr>
                  <td align="center" bgcolor="${C.actionFill}" style="border-radius:10px;">
                    <a href="${url}" target="_blank" style="display:inline-block;padding:14px 24px;font-family:${FONT};font-size:15px;font-weight:600;line-height:20px;color:${C.contentOnAction};text-decoration:none;border-radius:10px;">${label}</a>
                  </td>
                </tr>
              </table>
              <p style="margin:16px 0 0;font-family:${FONT};font-size:13px;line-height:20px;color:${C.contentSecondary};">Button not working? Copy this link into your browser:<br><a href="${url}" target="_blank" style="color:${C.accentText};word-break:break-all;">${url}</a></p>`;
}

function codeBlock(code) {
  return `<p style="margin:24px 0 8px;font-family:${FONT};font-size:13px;line-height:20px;color:${C.contentSecondary};">Your code</p>
              <p style="margin:0;padding:14px 20px;display:inline-block;background:${C.surfaceSunken};border:1px solid ${C.borderHairline};border-radius:10px;font-family:'SFMono-Regular',Menlo,Consolas,monospace;font-size:26px;font-weight:700;letter-spacing:6px;color:${C.contentPrimary};">${code}</p>`;
}

export function render(t) {
  const paragraphs = t.paragraphs
    .map((p) => `<p style="margin:0 0 14px;font-family:${FONT};font-size:15px;line-height:24px;color:${C.contentPrimary};">${p}</p>`)
    .join("\n              ");
  const call = t.code ? codeBlock(t.code) : t.action ? button(t.action) : "";
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="x-apple-disable-message-reformatting">
    <meta name="color-scheme" content="light">
    <meta name="supported-color-schemes" content="light">
    <title>${t.subject}</title>
  </head>
  <body style="margin:0;padding:0;background:${C.page};">
    <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${t.preheader}</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${C.page};">
      <tr>
        <td align="center" style="padding:32px 16px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
            <tr>
              <td style="padding:0 4px 20px;">
                <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                  <tr>
                    <td style="padding-right:12px;"><img src="${LOGO_URL}" width="40" height="40" alt="Help24" style="display:block;border:0;border-radius:10px;"></td>
                    <td style="font-family:${FONT};font-size:17px;font-weight:700;line-height:20px;color:${C.contentPrimary};">Help24<br><span style="font-size:11px;font-weight:600;letter-spacing:2px;text-transform:uppercase;color:${C.contentTertiary};">Admin security</span></td>
                  </tr>
                </table>
              </td>
            </tr>
            <tr>
              <td style="background:${C.surface};border:1px solid ${C.borderHairline};border-radius:14px;padding:32px 28px;">
              <h1 style="margin:0 0 16px;font-family:${FONT};font-size:22px;font-weight:700;line-height:30px;color:${C.contentPrimary};">${t.heading}</h1>
              ${paragraphs}
              ${call}
              <p style="margin:24px 0 0;padding:14px 16px;background:${C.cautionSubtle};border-radius:10px;font-family:${FONT};font-size:13px;line-height:20px;color:${C.contentPrimary};">${t.notice}</p>
              </td>
            </tr>
            <tr>
              <td style="padding:20px 4px 0;font-family:${FONT};font-size:12px;line-height:18px;color:${C.contentTertiary};">
                You're receiving this because of activity on a Help24 admin account. Help24 will never ask for your password by email or phone.<br>
                Help24 · <a href="${DASHBOARD_URL}" target="_blank" style="color:${C.contentTertiary};">admin.help24.co.ke</a> · <a href="mailto:${SUPPORT_EMAIL}" style="color:${C.contentTertiary};">${SUPPORT_EMAIL}</a>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>
`;
}

/** What the runbook and the Management API need, per template. */
export function manifest() {
  return TEMPLATES.map((t) => ({
    key: t.key,
    dashboardName: t.dashboardName,
    subject: t.subject,
    file: `html/${t.key}.html`,
    managementApi: apiFields(t),
  }));
}
