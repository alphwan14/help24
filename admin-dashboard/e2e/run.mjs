// npm run test:e2e
//
// The admin auth flows end to end: a real Next.js dev server and a real
// browser (Edge or Chrome, headless, driven over CDP — e2e/browser.mjs)
// against e2e/fake-stack.mjs in place of Supabase and the backend. Every
// service URL the app reads is overridden, so NOTHING here reaches production,
// sends a real email or touches a real password.
//
// Needs: a Chromium browser (E2E_BROWSER overrides the search), and ports
// 3101 / 9333 / 54399 free. Artifacts (screenshots, logs) go to e2e/.artifacts.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { launchBrowser } from "./browser.mjs";
import { startFakeStack } from "./fake-stack.mjs";

const ADMIN = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ARTIFACTS = join(ADMIN, "e2e", ".artifacts");
const SHOTS = join(ARTIFACTS, "shots");
const FAKE_PORT = 54399, APP_PORT = 3101, CDP_PORT = 9333;
const APP = `http://localhost:${APP_PORT}`;
const CALLBACK = `${APP}/auth/callback`;

const ALICE = "alice@help24.test", ALICE_PW1 = "Initial-pass-1", ALICE_PW2 = "Battery-staple-42", ALICE_PW3 = "Recovered-pass-77", ALICE_PW4 = "Settings-link-88";
const BOB = "bob@help24.test", BOB_PW = "Bobs-pass-22";
const CAROL = "carol@help24.test", CAROL_PW = "Carols-pass-3";
const DAVE = "dave@help24.test", DAVE_PW = "Dave-initial-1";
const ERIN = "erin@help24.test", ERIN_OLD = "Erin-old-pass-1", ERIN_PW = "Erin-new-pass-2";
const FRANK = "frank@help24.test", FRANK_OLD = "Frank-old-pass-1", FRANK_PW = "Frank-new-pass-2";
const GINA = "gina@help24.test", GINA_OLD = "Gina-old-pass-1", GINA_PW = "Gina-new-pass-2";
const HANA = "hana@help24.test", HANA_OLD = "Hana-old-pass-1", HANA_PW = "Hana-new-pass-2";
const UMA = "uma@help24.test", UMA_PW = "Umas-pass-55"; // an admin whose login nobody has linked
const SECRETS = ["Partner-pass-31", ALICE_PW1, ALICE_PW2, ALICE_PW3, ALICE_PW4, BOB_PW, CAROL_PW, DAVE_PW, ERIN_OLD, ERIN_PW, FRANK_OLD, FRANK_PW, GINA_OLD, GINA_PW, HANA_OLD, HANA_PW, UMA_PW];

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  — ${detail}` : ""}`);
}
const note = (text) => console.log(`NOTE  ${text}`);
const section = (title) => console.log(`\n── ${title} ──`);

// Empty, not delete: on Windows a folder something is "in" cannot be removed.
mkdirSync(ARTIFACTS, { recursive: true });
for (const entry of readdirSync(ARTIFACTS)) {
  try { rmSync(join(ARTIFACTS, entry), { recursive: true, force: true }); } catch {}
}
mkdirSync(SHOTS, { recursive: true });

// `next dev` with a custom dist dir rewrites these two tracked files; put them back after.
const restorable = ["tsconfig.json", "next-env.d.ts"].map((f) => [join(ADMIN, f), readFileSync(join(ADMIN, f), "utf8")]);

/* ── the fake stack ─────────────────────────────────────────────────────── */
const fake = await startFakeStack({
  port: FAKE_PORT,
  siteUrl: APP,
  redirectAllowList: [CALLBACK],
  templatesDir: join(ADMIN, "supabase-auth-emails", "html"),
});
const FAKE = fake.origin;
function person(email, password, role, { linked = true, arbitration = null } = {}) {
  if (password) fake.addAuthUser(email, password);
  fake.addPerson(email, role);
  if (password && linked) fake.linkByEmail(email);
  if (arbitration) fake.addArbitrationAdmin(email, arbitration.name, arbitration.role, arbitration.active ?? true);
}
person(ALICE, ALICE_PW1, "admin", { arbitration: { name: "Alice Wanjiru", role: "super_admin" } });
person(BOB, BOB_PW, "admin", { arbitration: { name: "Bob Kamau", role: "senior_admin" } });
person(CAROL, CAROL_PW, "user");
person(UMA, UMA_PW, "admin", { linked: false });
person(DAVE, null, "user"); // uses the app; no dashboard login yet
for (const [email, old] of [[ERIN, ERIN_OLD], [FRANK, FRANK_OLD], [GINA, GINA_OLD], [HANA, HANA_OLD]]) {
  person(email, old, "admin", { arbitration: { name: email.split("@")[0], role: "support_agent", active: false } });
}
fake.addInvite("inv-dave", DAVE, "support_agent");
fake.addInvite("inv-erin", ERIN, "senior_admin");
fake.addInvite("inv-frank", FRANK, "support_agent");
fake.addInvite("inv-gina", GINA, "support_agent");
fake.addInvite("inv-hana", HANA, "support_agent");
fake.addInvite("inv-expired", "late@help24.test", "support_agent", { expired: true });

/* ── next dev, pointed only at the fake ─────────────────────────────────── */
const serverOutput = [];
const next = spawn(process.execPath, [join(ADMIN, "node_modules/next/dist/bin/next"), "dev", "--port", String(APP_PORT)], {
  cwd: ADMIN,
  env: {
    ...process.env,
    NEXT_PUBLIC_SUPABASE_URL: FAKE,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: "fake-anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "fake-service-key",
    BACKEND_URL: FAKE,
    NEXT_PUBLIC_BACKEND_URL: FAKE,
    NEXT_DIST_DIR: ".next-e2e",
    // The partner portal gets its own origin: same server, another host name,
    // so its cookies are separate from the admin's — as on production.
    PARTNER_HOSTS: `127.0.0.1:${APP_PORT}`,
    PARTNER_PORTAL_URL: `http://127.0.0.1:${APP_PORT}`,
    NEXT_TELEMETRY_DISABLED: "1",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
next.stdout.on("data", (d) => serverOutput.push(String(d)));
next.stderr.on("data", (d) => serverOutput.push(String(d)));

let browser = null;
let exitCode = 0;
try {
  for (let i = 0; ; i++) {
    try {
      if ((await fetch(`${APP}/login`, { redirect: "manual" })).status === 200) break;
    } catch {}
    if (i > 240) throw new Error("next dev never became ready");
    await sleep(500);
  }
  browser = await launchBrowser({ profileDir: join(ARTIFACTS, "profile"), port: CDP_PORT });
  const pg = browser.page;
  const { goto, fill, click, clickText, value, waitFor, bodyHas, pathIs, evaluate, send } = pg;
  const shot = (name, full) => pg.shot(join(SHOTS, name), full);
  const S = { cur: 'input[name="current-password"]', neu: 'input[name="new-password"]', conf: 'input[name="confirm-password"]', submit: 'form button[type="submit"]' };
  const authRequestsSince = (n) => fake.log.slice(n).filter((l) => l.path.startsWith("/auth/v1/token") || (l.path === "/auth/v1/user" && l.method === "PUT"));
  const sessionCookies = async () => (await pg.cookies(APP)).filter((c) => /^sb-.+-auth-token(\.\d+)?$/.test(c.name));

  async function signIn(email, password) {
    await goto(`${APP}/login`);
    await waitFor("!!document.querySelector('input[type=email]')", "login form");
    await fill("input[type=email]", email);
    await fill("input[autocomplete=current-password]", password);
    await click("form button[type=submit]");
  }
  async function signOut() {
    await clickText("Sign out", "nav button");
    await waitFor(pathIs("/login"), "sign-out to /login");
  }
  async function requestReset(email) {
    await goto(`${APP}/login?reset=1`);
    await waitFor(bodyHas("Send reset link"), "reset mode");
    await fill("input[type=email]", email);
    await click("form button[type=submit]");
    await waitFor(bodyHas("a reset link is on its way"), "reset requested");
    return fake.lastEmailTo(email);
  }
  async function fillInvite(name, password, confirm = password) {
    await fill('input[name="name"]', name);
    await fill('input[name="password"]', password);
    await fill('input[name="confirm"]', confirm);
  }

  /* ════════════════════════════════════════════════════════════════════ */
  section("access control");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(pathIs("/login"), "redirect to /login");
  check("signed out: /dashboard/settings redirects to /login", true);
  await goto(`${APP}/reset-password`);
  await waitFor(bodyHas("This reset link has expired"), "reset page without a session");
  check("signed out: /reset-password offers a new link and shows no form", await evaluate(`!document.querySelector('input[name="new-password"]')`));
  await signIn(CAROL, CAROL_PW);
  await waitFor(bodyHas("Access denied"), "non-admin denial");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`location.pathname === '/login' && location.search.includes('unauthorized')`, "non-admin bounced");
  check("signed-in NON-admin: /dashboard/settings is refused", true);
  await pg.clearCookies();
  // A correct password on a login nobody has linked: refused, and told the truth.
  await signIn(UMA, UMA_PW);
  await waitFor(bodyHas("isn't connected to a Help24 account"), "unlinked login explained");
  check("UNLINKED login: refused with 'not linked yet', not 'no admin privileges'", await evaluate(`!document.body.innerText.includes("does not have admin privileges")`));
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`location.pathname === '/login' && location.search.includes('not-linked')`, "unlinked bounced");
  check("UNLINKED login: /dashboard/settings is refused", true);
  await pg.clearCookies();

  /* ════════════════════════════════════════════════════════════════════ */
  section("settings and changing a password");
  const gateMark = fake.log.length;
  await signIn(ALICE, ALICE_PW1);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "admin lands in dashboard");
  // The admin gate resolves link AND role in ONE query (users(role) embed); a
  // separate users lookup means a round trip crept back onto every request.
  check("sign-in lands on the overview in one navigation, not via /dashboard",
    await evaluate(`location.pathname`) === "/dashboard/overview", await evaluate(`location.pathname`));
  const gateCalls = fake.log.slice(gateMark);
  // The gate's own query is a ROLE lookup; the overview page reads users for its
  // figures too, which is not the gate.
  const roleLookups = gateCalls.filter((l) => l.path === "/rest/v1/users" && l.select.trim() === "role");
  check("admin gate: identity + role in one round trip, no separate users lookup",
    gateCalls.some((l) => l.path === "/rest/v1/user_auth_identities" && l.select.includes("users(role)")) && roleLookups.length === 0,
    `${roleLookups.length} separate role lookups`);
  // The sign-in page reaches the dashboard by a client-side navigation too; Sign
  // out must work from there without a page load in between.
  await waitFor(`!document.body.innerText.includes('Setting up your admin workspace')`, "shell ready", 30000).catch(() => {});
  await clickText("Sign out", "nav button");
  const loginSignOut = await waitFor(pathIs("/login"), "sign-out after signing in", 20000).then(() => true, () => false);
  check("existing login flow: Sign out works straight after signing in", loginSignOut);
  if (!loginSignOut) await pg.clearCookies();
  await signIn(ALICE, ALICE_PW1);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "admin lands in dashboard again");
  await goto(`${APP}/dashboard/users/admins`);
  await waitFor(bodyHas("Invite an admin"), "Admin Roles page");
  check("existing route /dashboard/users/admins still renders for a super_admin", true);
  await click('nav a[href="/dashboard/settings"]');
  await waitFor(`${pathIs("/dashboard/settings")} && ${bodyHas("Change password")}`, "Settings via sidebar");
  check("sidebar Settings entry navigates to /dashboard/settings", true);
  check("Settings link marks itself current", await evaluate(`document.querySelector('nav a[href="/dashboard/settings"]').getAttribute('aria-current') === 'page'`));
  await waitFor(`!document.body.innerText.includes('Setting up your admin workspace')`, "shell ready", 30000).catch(() => {});
  const account = await evaluate("document.querySelector('section').innerText");
  check("account card: this admin's name, email, role, sign-in method",
    ["Alice Wanjiru", ALICE, "Super Admin", "Email and password"].every((t) => account.includes(t)));
  check("account card shows no other admin's details", !account.includes(BOB) && !account.includes("Bob Kamau"));
  check("autocomplete: current-password, new-password, new-password",
    await evaluate(`[${JSON.stringify(S.cur)}, ${JSON.stringify(S.neu)}, ${JSON.stringify(S.conf)}].map(s => document.querySelector(s).autocomplete).join() === 'current-password,new-password,new-password'`));
  check("every password input has a label", await evaluate(`[...document.querySelectorAll('form input[type=password]')].every(i => i.labels && i.labels.length === 1)`));
  await shot("1-settings-desktop.png");

  let mark = fake.log.length;
  await click(S.submit);
  await waitFor(`${bodyHas("Enter your current password.")} && ${bodyHas("Enter a new password.")} && ${bodyHas("Re-enter your new password.")}`, "empty-field errors");
  check("empty submit: three field errors, focus on the first", await waitFor(`document.activeElement && document.activeElement.name === 'current-password'`, "focus", 5000).catch(() => false));
  await fill(S.cur, ALICE_PW1);
  await fill(S.neu, "12345678");
  await fill(S.conf, "12345678");
  await click(S.submit);
  await waitFor(bodyHas("Add letters as well as numbers."), "policy error");
  check("password policy: all-digit password refused", true);
  await fill(S.neu, ALICE_PW2);
  await fill(S.conf, ALICE_PW2 + "x");
  await click(S.submit);
  await waitFor(bodyHas("The passwords don't match."), "mismatch error");
  check("mismatched confirmation refused", true);
  check("strength meter + checklist react to typing", await evaluate(`document.body.innerText.includes('Strong') && document.body.innerText.includes('Different from your current password')`));
  await fill(S.neu, ALICE_PW1);
  await fill(S.conf, ALICE_PW1);
  await click(S.submit);
  await waitFor(bodyHas("Your new password must be different from your current one."), "unchanged error");
  check("unchanged password refused", true);
  check("none of the invalid submits reached the auth provider", authRequestsSince(mark).length === 0);

  mark = fake.log.length;
  await fill(S.cur, "Wrong-pass-99");
  await fill(S.neu, ALICE_PW2);
  await fill(S.conf, ALICE_PW2);
  await click(S.submit);
  await waitFor(bodyHas("That isn't your current password."), "wrong-current error");
  check("wrong current password: field error, field cleared", (await value(S.cur)) === "");
  check("wrong current password: password unchanged, no update sent", fake.password(ALICE) === ALICE_PW1 && !fake.log.slice(mark).some((l) => l.method === "PUT"));

  const otherDevice = fake.signInDirect(ALICE, ALICE_PW1);
  const bobDevice = fake.signInDirect(BOB, BOB_PW);
  const arbBefore = await pg.cookie(APP, "h24_admin_token");
  const restoresBefore = fake.restores.get(ALICE) ?? 0;
  await fill(S.cur, ALICE_PW1);
  await fill(S.neu, ALICE_PW2);
  await fill(S.conf, ALICE_PW2);
  await click(S.submit);
  await waitFor(bodyHas("Password changed."), "success message");
  await waitFor(`!document.querySelector(${JSON.stringify(S.submit)}).disabled`, "form idle again");
  check("success: fields cleared and hidden again", await evaluate(`[${JSON.stringify(S.cur)}, ${JSON.stringify(S.neu)}, ${JSON.stringify(S.conf)}].every(s => { const i = document.querySelector(s); return i.value === '' && i.type === 'password'; })`));
  check("provider holds the NEW password", fake.password(ALICE) === ALICE_PW2);
  check("alice's other device signed out by the provider", !fake.isLive(otherDevice.access_token));
  check("bob's password and session untouched", fake.password(BOB) === BOB_PW && fake.isLive(bobDevice.access_token));
  const arbAfter = await pg.cookie(APP, "h24_admin_token");
  check("arbitration token re-minted (old one retired), still httpOnly",
    (fake.restores.get(ALICE) ?? 0) === restoresBefore + 1 && arbAfter && arbBefore && arbAfter.value !== arbBefore.value && arbAfter.httpOnly);
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`${pathIs("/dashboard/settings")} && ${bodyHas("Change password")}`, "still signed in after reload");
  check("this browser stays signed in after the change", true);
  await signOut();
  await fill("input[type=email]", ALICE);
  await fill("input[autocomplete=current-password]", ALICE_PW1);
  await click("form button[type=submit]");
  await waitFor(bodyHas("Invalid email or password."), "old password refused");
  check("old password no longer signs in", true);
  await fill("input[autocomplete=current-password]", ALICE_PW2);
  await click("form button[type=submit]");
  await waitFor(`location.pathname.startsWith('/dashboard')`, "new password signs in");
  check("new password signs in", true);

  /* ════════════════════════════════════════════════════════════════════ */
  section("recovering a forgotten password, through the email");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(bodyHas("Change password"), "settings");
  await signOut();
  let mail = await requestReset(ALICE);
  check("the reset email asks Supabase to return to the exact callback", mail && new URL(mail.link).searchParams.get("redirect_to") === CALLBACK, mail?.link.replace(/token=[^&]+/, "token=…"));
  check("the email is Help24's template, subject included", mail.subject === "Reset your Help24 admin password" && mail.html.includes("Reset your password") && !/supabase/i.test(mail.html.replaceAll(mail.link, "")));
  check("the email's button and printed link are Supabase's verify link, not one we built", mail.html.split(mail.link).length - 1 === 3 && mail.link.startsWith(`${FAKE}/auth/v1/verify?token=pkce_`));
  // Preview copy only: the logo from this checkout, so rendering it fetches nothing live.
  writeFileSync(join(ARTIFACTS, "reset-email.html"),
    mail.html.replaceAll("https://admin.help24.co.ke/help24.png", pathToFileURL(join(ADMIN, "public", "help24.png")).href));
  const holder = fake.signInDirect(ALICE, ALICE_PW2);
  const bobBeforeReset = fake.signInDirect(BOB, BOB_PW);
  await goto(mail.link);
  await waitFor(`${pathIs("/reset-password")} && ${bodyHas("Set a new password")}`, "reset form from the emailed link");
  check("email link → Supabase verify → /auth/callback → reset form, code gone from the URL", await evaluate(`!location.search.includes('code')`));
  await shot("4-reset-form.png");
  await fill(S.neu, ALICE_PW3);
  await fill(S.conf, ALICE_PW3 + "?");
  await click(S.submit);
  await waitFor(bodyHas("The passwords don't match."), "reset mismatch");
  check("reset: mismatched confirmation refused", fake.password(ALICE) === ALICE_PW2);
  await fill(S.conf, ALICE_PW3);
  await click(S.submit);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "redirect after reset");
  check("reset sets the new password and lands in the dashboard", fake.password(ALICE) === ALICE_PW3);
  check("reset signed out alice's other sessions", !fake.isLive(holder.access_token));
  check("reset left bob alone", fake.password(BOB) === BOB_PW && fake.isLive(bobBeforeReset.access_token));
  // Signed out first: a live recovery session would (rightly) still show the form.
  await goto(`${APP}/dashboard/settings`);
  await waitFor(bodyHas("Change password"), "settings");
  await signOut();
  await goto(mail.link);
  await waitFor(`${pathIs("/reset-password")} && ${bodyHas("This reset link has expired")}`, "reused link");
  check("a reused reset link is refused honestly", await evaluate(`!document.querySelector('input[name="new-password"]')`));

  mail = await requestReset(ALICE);
  fake.expireRecoveryEmails();
  await goto(mail.link);
  await waitFor(bodyHas("This reset link has expired"), "expired link");
  check("an expired reset link is refused honestly", fake.password(ALICE) === ALICE_PW3);
  await shot("5-reset-expired.png");

  await requestReset(ALICE);
  await goto(`${CALLBACK}?code=%25zz-not-a-code&next=https%3A%2F%2Fevil.example%2Fsteal`);
  await waitFor(bodyHas("This reset link has expired"), "malformed code");
  check("a malformed code is refused, and the callback never leaves this origin", await evaluate(`location.origin === ${JSON.stringify(APP)} && location.pathname === '/reset-password'`));

  mail = await requestReset(ALICE);
  await pg.clearCookies(); // as if the email were opened in another browser
  await goto(mail.link);
  await waitFor(bodyHas("Open the link in the browser that asked for it"), "other-browser state");
  check("a link opened in a browser that never asked for it cannot set a password", fake.password(ALICE) === ALICE_PW3);
  await goto(CALLBACK);
  await waitFor(bodyHas("This reset link has expired"), "no-code state");
  check("the callback with no code at all → invalid-link state", true);

  await signIn(ALICE, ALICE_PW3);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "signed in");
  await goto(`${APP}/reset-password`);
  await waitFor(bodyHas("already signed in"), "ordinary-session state");
  check("an ordinary session cannot use /reset-password to skip the current password", await evaluate(`!document.querySelector('input[name="new-password"]')`));
  await goto(`${APP}/dashboard/settings`);
  await waitFor(bodyHas("Email me a reset link"), "settings reset button");
  await clickText("Email me a reset link");
  await waitFor(bodyHas("Reset link sent."), "settings reset sent");
  mail = fake.lastEmailTo(ALICE);
  await goto(mail.link);
  await waitFor(bodyHas("Set a new password"), "reset form from the settings-requested email");
  await fill(S.neu, ALICE_PW4);
  await fill(S.conf, ALICE_PW4);
  await click(S.submit);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "redirect after settings reset");
  check("Settings → 'Email me a reset link' → email → new password", fake.password(ALICE) === ALICE_PW4);

  /* ════════════════════════════════════════════════════════════════════ */
  section("invitations");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(bodyHas("Change password"), "settings");
  await signOut();
  await goto(`${APP}/accept-invite?token=nope`);
  await waitFor(bodyHas("Invite not found"), "unknown invite");
  check("unknown invite token → 'Invite not found'", true);
  await goto(`${APP}/accept-invite?token=inv-expired`);
  await waitFor(bodyHas("Invite expired"), "expired invite");
  check("expired invitation → 'Invite expired', no form", await evaluate(`!document.querySelector('input[name="password"]')`));

  // A first-time invitee: the backend creates the login and promotes the
  // person, but linking the login to their identity is a human step.
  await goto(`${APP}/accept-invite?token=inv-dave`);
  await waitFor(bodyHas("Valid invitation"), "dave's invitation");
  await fillInvite("Dave Otieno", DAVE_PW, DAVE_PW + "!");
  await click("form button[type=submit]");
  await waitFor(bodyHas("Passwords do not match."), "invite mismatch");
  check("invite: mismatched passwords refused before anything is created", fake.credentialCount(DAVE) === 0 && fake.inviteStatus("inv-dave") === "pending");
  await fillInvite("Dave Otieno", DAVE_PW);
  await click("form button[type=submit]");
  await waitFor(`location.pathname === '/login' && location.search.includes('invite-pending')`, "first-time invitee outcome", 120000);
  await waitFor(bodyHas("A super admin still has to finish activating"), "pending message");
  check("first-time invitee: password set, told activation is pending — never 'Invite already completed'",
    fake.password(DAVE) === DAVE_PW && fake.roleOf(DAVE) === "admin" && !fake.isLinked(DAVE));
  check("first-time invitee is left with no session and no arbitration token",
    (await sessionCookies()).length === 0 && !(await pg.cookie(APP, "h24_admin_token")));
  await shot("6-invite-pending.png");
  await goto(`${APP}/accept-invite?token=inv-dave`);
  await waitFor(bodyHas("Invite already completed"), "consumed invite, signed out");
  check("a consumed invitation cannot be used again", await evaluate(`!document.querySelector('input[name="password"]')`));
  await signIn(CAROL, CAROL_PW);
  await waitFor(bodyHas("Access denied"), "carol signed in");
  await goto(`${APP}/accept-invite?token=inv-dave`);
  await waitFor(bodyHas("Invite already completed"), "consumed invite, non-admin");
  check("a signed-in NON-admin opening a used invitation is not let in", await evaluate(pathIs("/accept-invite")));
  await pg.clearCookies();
  fake.linkByEmail(DAVE); // the runbook's §1 step, done by a super admin
  await signIn(DAVE, DAVE_PW);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "dave signs in once linked");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`${bodyHas("Dave Otieno")} && ${bodyHas("Support Agent")}`, "dave's settings");
  check("once linked, the invitee signs in with the password they chose and sees their own account", true);
  await goto(`${APP}/accept-invite?token=inv-dave`);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "signed-in admin past a used invitation");
  check("a signed-in admin re-opening their used invitation is taken to the dashboard", true);
  await signOut();

  // A re-invited admin whose login is already linked: straight in.
  await goto(`${APP}/accept-invite?token=inv-erin`);
  await waitFor(bodyHas("Valid invitation"), "erin's invitation");
  await fillInvite("Erin Achieng", ERIN_PW);
  await click("form button[type=submit]");
  await waitFor(`location.pathname.startsWith('/dashboard')`, "erin lands in the dashboard", 120000);
  check("valid invitation → password set → signed in → dashboard, with no manual sign-in", fake.password(ERIN) === ERIN_PW);
  check("…pre-connected: the arbitration cookie arrived with the redirect, httpOnly", (await pg.cookie(APP, "h24_admin_token"))?.httpOnly === true);
  // Straight from the action's redirect, no page load in between: the
  // dashboard must be fully usable — server actions included.
  await signOut();
  check("right after accepting, Sign out works (later server actions are not stalled)", true);
  await signIn(ERIN, ERIN_PW);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "erin signs back in");
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`${bodyHas("Erin Achieng")} && ${bodyHas("Senior Admin")}`, "erin's settings");
  check("the invitee's Settings shows their own name and invited role", true);
  await goto(`${APP}/accept-invite?token=inv-erin`);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "refresh after accepting");
  check("refreshing the invitation right after accepting goes to the dashboard, not an error", true);
  await signOut();

  // Double submit: two submissions of the same form in the same instant.
  await goto(`${APP}/accept-invite?token=inv-frank`);
  await waitFor(bodyHas("Valid invitation"), "frank's invitation");
  await fillInvite("Frank Mwangi", FRANK_PW);
  const postsBefore = pg.requests.length;
  await evaluate("(() => { const f = document.querySelector('form'); f.requestSubmit(); f.requestSubmit(); return true; })()");
  await waitFor(`location.pathname.startsWith('/dashboard')`, "double submit resolves", 120000);
  check("double submit: one login, one admin record, invitation consumed once, dashboard reached",
    fake.credentialCount(FRANK) === 1 && fake.inviteStatus("inv-frank") === "completed" && fake.password(FRANK) === FRANK_PW &&
      [...fake.admins.values()].filter((a) => a.email === FRANK).length === 1);
  check("…and the second submission never left the browser",
    pg.requests.slice(postsBefore).filter((r) => r.method === "POST" && r.url.startsWith(`${APP}/accept-invite`)).length === 1);
  await signOut(); // a queued duplicate would have stalled every server action after it, this one included

  // Retry after a lost response: the backend already accepted it.
  await goto(`${APP}/accept-invite?token=inv-gina`);
  await waitFor(bodyHas("Valid invitation"), "gina's invitation");
  fake.acceptOutOfBand("inv-gina", "Gina Njeri", GINA_PW);
  await fillInvite("Gina Njeri", GINA_PW);
  await click("form button[type=submit]");
  await waitFor(`location.pathname.startsWith('/dashboard')`, "retry with the password that was set", 120000);
  check("retry of an acceptance that already went through: signed straight in", fake.credentialCount(GINA) === 1);
  await signOut();
  await goto(`${APP}/accept-invite?token=inv-hana`);
  await waitFor(bodyHas("Valid invitation"), "hana's invitation");
  fake.acceptOutOfBand("inv-hana", "Hana Wairimu", HANA_PW);
  await fillInvite("Hana Wairimu", "Not-what-was-set-1");
  await click("form button[type=submit]");
  await waitFor(bodyHas("Invite already completed"), "retry with another password");
  check("retry with a different password: honest error, no session, password unchanged",
    (await sessionCookies()).length === 0 && fake.password(HANA) === HANA_PW && (await evaluate(pathIs("/accept-invite"))));
  // The retry may only try the address the server signed for this invitation.
  await goto(`${APP}/accept-invite?token=inv-hana`);
  await waitFor(bodyHas("Invite already completed"), "hana's used invitation");
  fake.addInvite("inv-ivy", "ivy@help24.test", "support_agent");
  await goto(`${APP}/accept-invite?token=inv-ivy`);
  await waitFor(bodyHas("Valid invitation"), "ivy's invitation");
  fake.acceptOutOfBand("inv-ivy", "Ivy Chebet", "Ivy-chosen-pass-1");
  mark = fake.log.length;
  await evaluate(`(() => { document.querySelector('input[name="email"]').value = ${JSON.stringify(CAROL)}; return true; })()`);
  await fillInvite("Ivy Chebet", CAROL_PW);
  await click("form button[type=submit]");
  await waitFor(bodyHas("Invite already completed"), "tampered retry");
  check("a retry with a tampered address never even attempts that sign-in",
    !fake.log.slice(mark).some((l) => l.path === "/auth/v1/token?grant_type=password" && l.body.includes(CAROL)) && (await sessionCookies()).length === 0);

  const crossSite = await fetch(`${APP}/accept-invite/submit`, { method: "POST", redirect: "manual", headers: { Origin: "https://evil.example", "Content-Type": "application/x-www-form-urlencoded" }, body: "token=inv-dave&name=Eve&password=Evil-pass-123&confirm=Evil-pass-123" });
  check("a cross-site POST to the invitation endpoint is refused", crossSite.status === 403);
  const bogus = await fetch(`${APP}/accept-invite/submit`, { method: "POST", redirect: "manual", headers: { Origin: APP, "Content-Type": "application/x-www-form-urlencoded" }, body: "token=nope&name=Eve&password=Evil-pass-123&confirm=Evil-pass-123" });
  check("an unknown token: 303 back to the form with a code, not text", bogus.status === 303 && (bogus.headers.get("location") ?? "").endsWith("/accept-invite?token=nope&error=invitation"), bogus.headers.get("location"));
  await goto(`${APP}/accept-invite?token=inv-hana&error=${encodeURIComponent("Call +254700000000 to verify")}`);
  check("words typed into ?error= never reach the page", !(await evaluate(bodyHas("Call +254700000000"))));

  /* ════════════════════════════════════════════════════════════════════ */
  section("screens");
  await signIn(ALICE, ALICE_PW4);
  await waitFor(`location.pathname.startsWith('/dashboard')`, "signed in");

  /* ════════════════════════════════════════════════════════════════════ */
  section("app controls");
  {
    const F = 'section[aria-label="Features"]';
    await goto(`${APP}/dashboard/operations/controls`);
    await waitFor(`${bodyHas("Change history")} && !!document.querySelector('${F}')`, "app controls");
    check("App controls shows the four controls and the live values",
      await evaluate(`["Features", "App version", "Maintenance banner", "Announcement"].every(t => !!document.querySelector('section[aria-label="' + t + '"]')) && document.querySelector('input[name="soft"]').value === "1.0.5"`));
    check("the sidebar carries App Controls", await evaluate(`!!document.querySelector('nav a[href="/dashboard/operations/controls"]')`));

    await click(`${F} button[aria-label="Payments"]`);
    await waitFor(`!document.querySelector('${F} .btn-primary').disabled`, "review enabled");
    check("nothing is sent by flipping a switch", !fake.log.some((l) => l.method === "PATCH"));
    await click(`${F} .btn-primary`);
    await waitFor(`!!document.querySelector('[role="dialog"]')`, "confirm dialog");
    const dialog = await evaluate(`document.querySelector('[role="dialog"]').innerText`);
    check("confirm names exactly what changes and what it stops",
      dialog.includes("Payments: on → off") && dialog.includes("Nobody can start an M-Pesa payment") && !dialog.includes("Posting:"), dialog.slice(0, 200));
    check("confirm is refused without a reason", await evaluate(`[...document.querySelectorAll('[role="dialog"] button')].find(b => b.textContent.includes("Confirm")).disabled`));
    await fill('[role="dialog"] textarea', "M-Pesa callbacks failing");
    await shot("8-app-controls-confirm.png");
    await clickText("Confirm change");
    await waitFor(`!document.querySelector('[role="dialog"]') && ${bodyHas("1 off")}`, "saved", 15000);
    const write = fake.log.filter((l) => l.method === "PATCH").at(-1);
    const sent = JSON.parse(write?.body || "{}");
    check("one PATCH /admin/config/ops.kill_switches with the value and the reason",
      write?.path === "/admin/config/ops.kill_switches" && sent.value?.payments === false && sent.reason === "M-Pesa callbacks failing", write?.body);
    check("the backend now serves payments off", fake.appConfig.ops.kill_switches.payments === false);
    const last = fake.configHistory.at(-1);
    check("the change is recorded with who and why", last?.admin_email === ALICE && last?.reason === "M-Pesa callbacks failing");
    check("the history on the page reads the change back",
      await evaluate(`document.querySelector('section[aria-label="Change history"]').innerText.includes("Payments: on → off")`));

    await shot("9-app-controls.png", true);
    await fill('input[name="hard"]', "1.0.6");
    check("a required version above the suggested one is refused before review",
      await evaluate(`${bodyHas("cannot be higher than the suggested one")} && document.querySelector('section[aria-label="App version"] .btn-primary').disabled`));
    check("no other write went out", fake.log.filter((l) => l.method === "PATCH").length === 1);
  }

  /* ════════════════════════════════════════════════════════════════════ */
  section("partner portal");
  {
    const PARTNER = `http://127.0.0.1:${APP_PORT}`;
    const AGENT_EMAIL = "wanjiru.agent@help24.test", AGENT_PW = "Partner-pass-31";
    const onAdmin = await fetch(`${APP}/partners`, { redirect: "manual" });
    check("the partner portal does not exist on the admin host", onAdmin.status === 404, String(onAdmin.status));
    const signedOut = await fetch(`${PARTNER}/`, { redirect: "manual" });
    check("partner host, signed out: sent to the partner sign-in",
      signedOut.status === 307 && (signedOut.headers.get("location") ?? "").endsWith("/login"), signedOut.headers.get("location"));
    const adminOnPartner = await fetch(`${PARTNER}/dashboard/overview`, { redirect: "manual" });
    check("admin pages are not reachable from the partner host", adminOnPartner.status === 307 && (adminOnPartner.headers.get("location") ?? "").endsWith("/login"));

    await goto(`${APP}/dashboard/partners`);
    await waitFor(`!!document.querySelector('[data-testid="admin-partners"]')`, "admin partners");
    await clickText("Add agent");
    await waitFor(`!!document.querySelector('[role="dialog"]')`, "add agent dialog");
    await fill('[role="dialog"] input', "Wanjiru Agent");
    await fill('[role="dialog"] input[type="email"]', AGENT_EMAIL);
    await clickText("Add agent", '[role="dialog"] button');
    await waitFor(`!!document.querySelector('[data-testid="invite-link"]')`, "invite link", 15000);
    const inviteUrl = await evaluate(`document.querySelector('[data-testid="invite-link"] .font-mono').textContent`);
    const agent = fake.partnerAgentByEmail(AGENT_EMAIL);
    check("adding an agent gives a code and a one-time invitation on the partner host",
      !!agent && /^H24-[A-HJ-NP-Z2-9]{4}$/.test(agent.code) && inviteUrl.startsWith(`${PARTNER}/accept?token=`), inviteUrl.slice(0, 40));
    check("the invitation token is not what the database keeps", !fake.log.some((l) => l.body.includes(inviteUrl.split("token=")[1])));
    fake.creditToAgent(agent.id, DAVE, { active_days: 2 });
    fake.creditToAgent(agent.id, CAROL, { active_days: 1, method: "qr" });
    await clickText("Done", '[role="dialog"] button');
    await waitFor(`location.pathname.startsWith('/dashboard/partners/') && ${bodyHas("Members credited to Wanjiru Agent")}`, "agent page");
    check("admins see the agent's members whole, linked to each member page",
      await evaluate(`${bodyHas("dave Kamau")} && ${bodyHas("0712 345 678")} && !!document.querySelector('a[href^="/dashboard/users/"]')`));
    await shot("12-admin-partner.png", true);
    check("and can see exactly what the agent sees, without signing in as them",
      await evaluate(`${bodyHas("What Wanjiru Agent sees in the partner portal")}`));

    await goto(inviteUrl);
    await waitFor(bodyHas("Welcome, Wanjiru Agent"), "invitation page");
    await fill('input[name="password"]', AGENT_PW);
    await fill('input[name="confirm"]', AGENT_PW);
    await clickText("Create my partner account");
    await waitFor(`location.origin === ${JSON.stringify(PARTNER)} && location.pathname === "/" && !!document.querySelector('[data-testid="partner-code"]')`, "partner overview", 20000);
    check("accepting the invitation signs the agent in to their own overview",
      (await evaluate(`document.querySelector('[data-testid="partner-code"]').textContent`)) === agent.code);
    // Each tile as label|value|hint, read paragraph by paragraph.
    const tiles = await evaluate(`[...document.querySelectorAll('.card')].map(c => [...c.querySelectorAll('p')].map(x => x.textContent.trim()).join('|')).join(' || ')`);
    check("overview: 2 credited, 1 qualified, 1 in progress",
      /Members credited\|2\|/.test(tiles) && /Qualified\|1\|/.test(tiles) && /In progress\|1\|/.test(tiles), tiles.slice(0, 240));
    check("the admin session on the admin host is untouched", !!(await pg.cookie(APP, "h24_admin_token")));

    await goto(`${PARTNER}/members`);
    await waitFor(`!!document.querySelector('[data-testid="partner-members"]')`, "partner members");
    const list = await evaluate(`document.querySelector('[data-testid="partner-members"]').innerText`);
    await shot("13-partner-members.png", true);
    check("members: first names and the last 3 digits only",
      list.includes("dave") && list.includes("•••• ••• 678") && !list.includes("Kamau") && !list.includes("0712 345 678"), list.slice(0, 160));
    check("members: progress toward qualifying is spelled out",
      list.includes("Qualified") && list.includes("In progress") && /Needs 1 more day/.test(list));
    check("no member's email anywhere on the partner page",
      !(await evaluate(`document.documentElement.outerHTML.includes(${JSON.stringify(DAVE)}) || document.documentElement.outerHTML.includes(${JSON.stringify(CAROL)})`)));
    await goto(`${PARTNER}/dashboard/overview`);
    check("a signed-in partner still cannot reach admin pages",
      await waitFor(`${bodyHas("404")} || ${bodyHas("could not be found")}`, "404", 15000).then(() => true, () => false));

    await goto(`${PARTNER}/`);
    await waitFor(`!!document.querySelector('[data-testid="partner-code"]') && ${bodyHas("Members credited")}`, "overview again");
    await sleep(800);
    await shot("11-partner-overview.png", true);
    await clickText("Sign out");
    await waitFor(`location.pathname === "/login"`, "partner signed out");
    await fill('input[name="email"]', ALICE);
    await fill('input[name="password"]', ALICE_PW4);
    await clickText("Sign in");
    await waitFor(bodyHas("isn't a Help24 partner account"), "admin refused on partner host", 15000);
    check("an admin login is refused by the partner portal", true);

    await goto(`${APP}/dashboard/partners/${agent.id}`);
    await clickText("Pause agent");
    await waitFor(`!!document.querySelector('[role="dialog"] textarea')`, "pause dialog");
    await fill('[role="dialog"] textarea', "Testing the pause");
    await clickText("Confirm", '[role="dialog"] button');
    await waitFor(bodyHas("Paused"), "paused", 15000);
    check("pausing is recorded with who and why",
      fake.partnerEvents.some((e) => e.agent_id === agent.id && e.action === "suspended" && e.reason === "Testing the pause" && e.admin_email === ALICE));
    await goto(`${PARTNER}/login`);
    await fill('input[name="email"]', AGENT_EMAIL);
    await fill('input[name="password"]', AGENT_PW);
    await clickText("Sign in");
    await waitFor(bodyHas("partner account is paused"), "paused agent refused", 15000);
    check("a paused agent can no longer sign in", true);
  }

  /* ════════════════════════════════════════════════════════════════════ */
  section("live operations board");
  {
    await goto(`${APP}/dashboard/operations/live`);
    await waitFor(`!!document.querySelector('[data-testid="live-board"]')`, "live board");
    check("live board: the four headline figures and the panels render",
      await evaluate(`["In the app now", "Jobs in progress", "Held in escrow", "Paying out", "Requests waiting for anyone", "Happening now", "Sharing live location"].every(t => document.body.innerText.includes(t))`));
    check("live board: an empty minute reads as empty, not as a failed read",
      await evaluate(`${bodyHas("Nobody has the app open at the moment.")} && !(${bodyHas("Could not be read just now")})`));
    check("live board: says how fresh it is", await evaluate(bodyHas("refreshes every 30s")));
    await goto(`${APP}/dashboard/operations/controls`);
    await waitFor(`!!document.querySelector('[data-testid="versions-in-use"]')`, "versions in use");
    check("App controls shows the versions in use beside the gates", true);
  }

  /* ════════════════════════════════════════════════════════════════════ */
  section("member page");
  {
    const daveId = fake.idOf(DAVE);
    await goto(`${APP}/dashboard/users/${daveId}`);
    await waitFor(`${bodyHas("Trust & Safety record")} && ${bodyHas("Money for their work")}`, "member page");
    await shot("10-member.png", true);
    check("member page: activity, standing and push reach in the header",
      await evaluate(`${bodyHas("Active today")} && ${bodyHas("Good standing")} && ${bodyHas("Reach 1 phone")}`));
    check("member page: call, WhatsApp and email go to this member",
      await evaluate(`!!document.querySelector('a[href="tel:+254712345678"]') && !!document.querySelector('a[href="https://wa.me/254712345678"]') && !!document.querySelector('a[href^="mailto:"]')`));
    check("member page: Trust & Safety record links to the same member",
      await evaluate(`!!document.querySelector('a[href="/dashboard/trust-safety/users/${daveId}"]')`));
    check("member page: empty history reads as none, not as a failed read",
      await evaluate(`${bodyHas("Has not posted anything.")} && !(${bodyHas("Could not be read just now")})`));
    check("member page: the push token never reaches the page", !(await evaluate(`document.documentElement.outerHTML.includes("fcm-secret-token-e2e")`)));
    await goto(`${APP}/dashboard/users/not a valid id`);
    check("member page: a malformed id is a 404, not a query",
      await waitFor(`${bodyHas("404")} || ${bodyHas("could not be found")} || ${bodyHas("not found")}`, "404", 15000).then(() => true, () => false),
      await evaluate("document.body.innerText.slice(0, 160)"));
  }
  // Desktop: the shell is one screen tall and only <main> scrolls, so the rail
  // stays put. If anything on the page escapes that box the DOCUMENT scrolls
  // and carries the rail up with it.
  await send("Emulation.setDeviceMetricsOverride", { width: 1366, height: 768, deviceScaleFactor: 1, mobile: false });
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`${bodyHas("Change password")} && !document.body.innerText.includes('Setting up your admin workspace')`, "settings desktop");
  await sleep(400);
  const desk = await evaluate(`(() => {
    const doc = document.scrollingElement;
    const main = document.querySelector("main");
    main.scrollTop = main.scrollHeight;
    window.scrollTo(0, 99999);
    const escaping = [...document.body.querySelectorAll("*")]
      .filter((el) => !main.contains(el) && el.getBoundingClientRect().bottom > innerHeight + 1 && getComputedStyle(el).position !== "fixed")
      .slice(0, 6)
      .map((el) => el.tagName.toLowerCase() + "." + String(el.className).split(" ").slice(0, 4).join(".") + " bottom=" + Math.round(el.getBoundingClientRect().bottom));
    return JSON.stringify({ docOverflow: doc.scrollHeight - doc.clientHeight, windowScrollY: window.scrollY, escaping });
  })()`);
  const deskState = JSON.parse(desk);
  check("desktop Settings: only <main> scrolls — the document never moves the rail",
    deskState.docOverflow <= 0 && deskState.windowScrollY === 0, desk);
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  await goto(`${APP}/dashboard/settings`);
  await waitFor(`${bodyHas("Change password")} && !document.body.innerText.includes('Setting up your admin workspace')`, "settings mobile");
  check("no horizontal scroll at 390px", await evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth"));
  await shot("2-settings-mobile.png", true);
  await click('button[aria-label="Open navigation"]');
  await sleep(500);
  check("the mobile drawer carries the Settings entry", await evaluate(`[...document.querySelectorAll('nav[aria-label="Mobile navigation"] a')].some(a => a.getAttribute('href') === '/dashboard/settings')`));
  await shot("3-drawer-mobile.png");
  await send("Emulation.setDeviceMetricsOverride", { width: 640, height: 1100, deviceScaleFactor: 1, mobile: false });
  await goto(pathToFileURL(join(ARTIFACTS, "reset-email.html")).href);
  await shot("7-reset-email.png", true);
  await send("Emulation.clearDeviceMetricsOverride");

  /* ════════════════════════════════════════════════════════════════════ */
  section("nothing secret where it does not belong");
  const tokens = fake.outbox.map((m) => m.token);
  const appRequests = pg.requests.filter((r) => r.url.startsWith(APP));
  const misplaced = pg.requests.filter((r) => SECRETS.some((s) => r.postData.includes(s)) && !r.url.startsWith(`${FAKE}/auth/v1/`) && !r.url.startsWith(`${APP}/accept-invite`)
    // The partner portal's own sign-in and invitation forms (server actions).
    && !r.url.startsWith(`http://127.0.0.1:${APP_PORT}/accept`) && !r.url.startsWith(`http://127.0.0.1:${APP_PORT}/login`));
  check("passwords went only to the auth provider — or to the invite form's own server action", misplaced.length === 0, misplaced.map((r) => r.url).join(", "));
  check("no recovery token ever reached a Help24 URL or request body", !appRequests.some((r) => tokens.some((t) => r.url.includes(t) || r.postData.includes(t))));
  const logText = serverOutput.join("");
  check("server logs: no password, no recovery token", !SECRETS.some((s) => logText.includes(s)) && !tokens.some((t) => logText.includes(t)));
  check("browser console: no password, no recovery token", !pg.consoleLines.some((l) => SECRETS.some((s) => l.includes(s)) || tokens.some((t) => l.includes(t))));
  if (/GET \/auth\/callback\?code=/.test(logText)) note("the dev server's request log prints /auth/callback?code=… — Supabase's one-time PKCE code, useless without this browser's verifier");
  const thrown = pg.exceptions.filter((e) => !/overview|recharts/i.test(e));
  check("no uncaught browser exceptions", thrown.length === 0, thrown.slice(0, 3).join(" || "));
} catch (err) {
  exitCode = 1;
  check("run aborted", false, err.stack ?? String(err));
  if (browser) {
    try { await browser.page.shot(join(SHOTS, "FAIL.png")); } catch {}
    writeFileSync(join(ARTIFACTS, "browser-console.log"), [
      ...browser.page.consoleLines, "--- exceptions ---", ...browser.page.exceptions,
      "--- last requests ---", ...browser.page.requests.slice(-30).map((r) => `${r.method} ${r.url}`),
    ].join("\n"));
  }
  writeFileSync(join(ARTIFACTS, "fake.log"), fake.log.slice(-60).map((l) => `${l.method} ${l.path}`).join("\n"));
} finally {
  writeFileSync(join(ARTIFACTS, "server.log"), serverOutput.join(""));
  browser?.stop();
  if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(next.pid), "/T", "/F"], { stdio: "ignore" });
  else next.kill("SIGTERM");
  fake.server.close();
  for (const [file, content] of restorable) if (readFileSync(file, "utf8") !== content) writeFileSync(file, content);
  rmSync(join(ADMIN, ".next-e2e"), { recursive: true, force: true });
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length || exitCode ? 1 : 0);
}
