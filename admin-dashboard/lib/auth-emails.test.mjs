// node --test lib/auth-emails.test.mjs
//
// The Supabase Auth email templates (supabase-auth-emails/): the committed HTML
// matches its source, and every template keeps the rules in templates.mjs.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { TEMPLATES, apiFields, manifest, render } from "../supabase-auth-emails/templates.mjs";

// Line endings normalised: a Windows checkout (core.autocrlf) turns the committed LF into CRLF.
const html = (key) =>
  readFileSync(new URL(`../supabase-auth-emails/html/${key}.html`, import.meta.url), "utf8").replace(/\r\n/g, "\n");
const LINK = "{{ .ConfirmationURL }}";
const ALLOWED_VARIABLES = new Set(["ConfirmationURL", "Token", "Email", "NewEmail"]);

/** What a text-only mail client is left with. */
const asText = (h) =>
  h.replace(/<(head|style)[\s\S]*?<\/\1>/g, " ").replace(/<br\s*\/?>/g, "\n").replace(/<[^>]+>/g, " ").replace(/&[a-z]+;/g, " ").replace(/\s+/g, " ");

test("the committed HTML is exactly what the source renders (run `npm run emails:build`)", () => {
  for (const t of TEMPLATES) assert.equal(html(t.key), render(t), `${t.key}.html is stale`);
  const committed = JSON.parse(readFileSync(new URL("../supabase-auth-emails/html/manifest.json", import.meta.url), "utf8"));
  assert.deepEqual(committed, manifest());
});

test("links are Supabase's own one-time link — never a URL we assemble around a token", () => {
  for (const t of TEMPLATES) {
    const h = html(t.key);
    const links = h.split(LINK).length - 1;
    if (t.code) {
      assert.equal(links, 0, `${t.key} is a code, not a link`);
      assert.ok(h.includes("{{ .Token }}"), `${t.key} must show the code`);
    } else if (t.notification) {
      assert.equal(links, 0, `${t.key} only informs`);
    } else {
      // The button, and the same link printed as text and as its own href.
      assert.equal(links, 3, `${t.key} carries the confirmation link`);
      assert.ok(!/\{\{\s*\.(TokenHash|SiteURL|RedirectTo)/.test(h), `${t.key} must not hand-build a link`);
    }
  }
});

test("only the variables Supabase provides, used as values", () => {
  for (const t of TEMPLATES) {
    for (const [, name] of html(t.key).matchAll(/\{\{\s*\.?([A-Za-z]*)[^}]*\}\}/g)) {
      assert.ok(ALLOWED_VARIABLES.has(name), `${t.key} uses {{ .${name} }}`);
    }
  }
  assert.ok(html("email_change").includes("{{ .NewEmail }}"));
});

test("Help24's voice: no Supabase branding, a clear Help24 subject, one per template", () => {
  const subjects = new Set();
  for (const t of TEMPLATES) {
    assert.doesNotMatch(html(t.key), /supabase/i, `${t.key} mentions Supabase`);
    assert.match(t.subject, /Help24/);
    assert.ok(t.subject.length <= 60, `${t.key} subject is long`);
    subjects.add(t.subject);
    assert.ok(html(t.key).includes(`<title>${t.subject}</title>`));
  }
  assert.equal(subjects.size, TEMPLATES.length);
});

test("safe to render anywhere: no scripts, no external CSS, HTTPS Help24 links, an alt on the one image", () => {
  for (const t of TEMPLATES) {
    const h = html(t.key);
    assert.doesNotMatch(h, /<script|<link\b|@import|javascript:/i, t.key);
    for (const [url] of h.matchAll(/https?:\/\/[^\s"'<>]+/g)) {
      assert.match(url, /^https:\/\/(admin\.)?help24\.co\.ke(\/|$)/, `${t.key} links to ${url}`);
    }
    const images = [...h.matchAll(/<img\b[^>]*>/g)].map(([tag]) => tag);
    assert.equal(images.length, 1, `${t.key} has one image`);
    assert.match(images[0], /alt="Help24"/);
  }
});

test("accessible and mobile-friendly shell", () => {
  for (const t of TEMPLATES) {
    const h = html(t.key);
    assert.match(h, /<html lang="en">/);
    assert.match(h, /name="viewport"/);
    assert.match(h, /max-width:560px/);
    assert.ok(h.includes(t.preheader), `${t.key} preheader`);
    assert.ok([...h.matchAll(/<table\b[^>]*>/g)].every(([tag]) => tag.includes('role="presentation"')), `${t.key} layout tables are presentational`);
  }
});

test("still makes sense with the markup stripped — Supabase sends HTML only", () => {
  for (const t of TEMPLATES) {
    const text = asText(html(t.key));
    assert.ok(text.includes(t.heading), `${t.key} heading`);
    if (t.action?.url === LINK) assert.ok(text.includes(LINK), `${t.key} prints its link as text`);
    if (t.code) assert.ok(text.includes("{{ .Token }}"));
  }
});

test("Management API field names follow Supabase's naming", () => {
  const byKey = Object.fromEntries(manifest().map((m) => [m.key, m.managementApi]));
  assert.deepEqual(byKey.recovery, { subject: "mailer_subjects_recovery", content: "mailer_templates_recovery_content" });
  assert.deepEqual(byKey.reauthentication, { subject: "mailer_subjects_reauthentication", content: "mailer_templates_reauthentication_content" });
  assert.deepEqual(byKey.password_changed_notification, {
    subject: "mailer_subjects_password_changed_notification",
    content: "mailer_templates_password_changed_notification_content",
    enable: "mailer_notifications_password_changed_enabled",
  });
  assert.deepEqual(apiFields({ key: "invite" }), { subject: "mailer_subjects_invite", content: "mailer_templates_invite_content" });
});
