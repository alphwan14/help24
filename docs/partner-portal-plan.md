# Partner portal — plan

Status: P1 (capture) and P2 (portal and admin Partners) built 2026-10-26. P3–P5 not started.
Owner: Help24 team. Audience: everyone building or running the portal.

## What we are building, and for whom

A separate, signed-in portal where people who grow Help24 can see their own work:

| Who | What they need to see |
|---|---|
| **Onboarding agents** | The members they signed up, how each was credited (code, link or QR), and whether each became a *qualified* member — the number they are paid on |
| **Marketing agents** | Their links and QR codes: visits, scans, downloads, sign-ups and qualified members per link |
| **Market researchers** | Totals only: demand by category and town, activity trends, supply gaps. No individual people |

Agents are **paid per member**. That one fact shapes the whole design: crediting must be exact, hard to game, and auditable.

## Why not make them support agents

We checked what a dashboard `support_agent` can do today:

- **Sees almost everything.** The dashboard admits any admin and reads with full database rights: every member's phone and email, the member page with Call/WhatsApp, all payments and escrow, dispute evidence, Trust & Safety reports. Only *Admin roles* and *Promotion revenue* are closed to them.
- **Can change:** warn members, remove/restore content, triage and resolve reports, assign disputes, message both sides, add/request evidence, escalate.
- **Cannot:** money rulings, suspensions, bans, app controls.

An agent paid per sign-up with that access could export every member's contacts. So partners get **their own role, their own login and their own pages**, and never the admin role.

## Where it lives

**`partners.help24.co.ke`**, served by the same Next.js project as `admin.help24.co.ke`, with two hard walls:

1. **Host allow-list in middleware.** On `partners.` only `/partners/*` (and its login) is served; everything else is a 404. On `admin.`, `/partners/*` is a 404.
2. **Separate identity.** A partner signs in with their own Supabase Auth login, linked to a row in `partner_agents` — never `users.role = 'admin'`. The admin gate keeps refusing them, so even a bug in partner code cannot open an admin page.

Cookies are host-only, so an admin session and a partner session never share a cookie.

**Why not `admin.help24.co.ke/partners`?** It would put partners one misconfigured link away from admin pages, on the same cookies. **Why not a separate repository?** It doubles the design system, auth helpers and deploys for no extra safety the two walls don't already give.

Setup the team does (not code): add `partners.help24.co.ke` to the Vercel project; add a DNS CNAME to Vercel; add `https://partners.help24.co.ke/**` to Supabase Auth's redirect allow-list.

## How a member is credited

**The agent code is the single source of truth.** The link and the QR code are two ways of delivering it.

| Method | How it arrives in the app |
|---|---|
| **Code** | The member types it on the sign-up screen ("Agent code — optional") |
| **Link** | The agent shares `help24.co.ke/a/<CODE>`. The page shows the code and the download, then an "I've installed it — continue" button that opens the app with the code filled in |
| **QR** | The same page, reached by scanning: `help24.co.ke/a/<CODE>?src=qr` |

The app opening from `help24.co.ke/a/...` needs **Android App Links**:

- an intent filter in the app, so it ships in the next release (1.0.6+);
- an `assetlinks.json` on the website, signed with release certificate `48f1d72b…`.

A member who opens the link before installing still lands on the page, and the "continue" button carries the code across. Typing it always works.

Rules:

- **One agent per member.** Credit is set at sign-up and can be added or corrected for up to **72 hours** after it; then it is locked.
- **An agent cannot credit themselves.** The code owner's account, phone and email are refused.
- **The method is recorded as it happened**: `code`, `link` or `qr`. The website separately counts visits and scans per code, which is the top of the marketing funnel.

## When a member counts — the paid number

A sign-up becomes a **qualified member** only when it is all of:

- **Verified:** a phone number checked by SMS code, or a Google account. One phone number qualifies once, ever.
- **Used, not just installed:** active on **at least 2 different days within 14 days** of signing up (the same signal as the dashboard's activity states), **or** posted a request or offer, or applied to one.
- **In good standing:** not banned or suspended in the window.
- **Not flagged:** the same phone or device as another credited member, or many sign-ups from one device or in bursts, holds the member for review instead of paying.

Agents see each member's progress toward qualifying ("verified ✓ · active 1 of 2 days"), so they follow up instead of signing people up and walking away.

## What agents see — privacy

- **Names:** first name only. **Phones:** last 3 digits (`•••• ••• 678`). No email, no location, nothing a member posted or said.
- **Researchers:** totals only, and any group smaller than 5 people is hidden.
- **Every partner login is a named person.** There is no shared or public link. Logins can be suspended from the admin dashboard.

## Admin side — in admin.help24.co.ke

A **Partners** section:

- create agents and issue codes;
- suspend agents;
- see each agent's members and qualification status;
- review held and flagged credits;
- approve the monthly statement.

**Who approves payouts:** a senior admin. Every action is recorded with who and why, the same append-only pattern as App controls (migration 125).

## Phases

| Phase | Delivers | Needs |
|---|---|---|
| **P1 — Capture** | `partner_agents` and `member_attribution` tables; agent code on the app's sign-up screen; App Links for `/a/<CODE>`; the website's `/a/<CODE>` page with visit and scan counts | Migration, app 1.0.6, website release |
| **P2 — Onboarding portal** | `partners.help24.co.ke` login; "My members" with qualification progress; admin Partners section (create agents, codes, review) | P1 |
| **P3 — Marketing view** | Links and QR codes per campaign, with funnel: visits → downloads → sign-ups → qualified | P1 |
| **P4 — Research view** | Totals by category, town and week, groups under 5 hidden | Existing data |
| **P5 — Statements and payouts** | Monthly statement per agent; senior-admin approval; M-Pesa payout through the existing payout path | P2 |

Nothing is credited retroactively. Members who joined before P1 have no agent.

## Decisions still open

1. Payment amount per qualified member, and whether it differs by agent type.
2. Whether the 2-days-in-14 rule is the right bar, or posting or applying should be required.
3. How agents are paid (M-Pesa B2C to a verified number?) and how often.
4. Whether agents may see members who never qualified after the window closes.

## Status and setup (2026-10-26)

**Built:**
- **P1:** migration 127, app 1.0.6, and the website's `/a/<CODE>` page with App Links.
- **P2:** migration 128, the partner portal and the admin **Partners** section. Admins monitor agents from inside admin.help24.co.ke:
  - a leaderboard of every agent;
  - each agent's page, with members shown in full;
  - what the agent sees in their portal;
  - pause and invite controls, with a history of who did what.

**Sign-in for partners:** an admin adds the agent and sends the one-time invitation link (WhatsApp works). The agent sets a password at `/accept`. A new invitation also resets a forgotten password. No email is sent, because Supabase's default mailer only delivers to project team members.

**To switch the portal on (the team does these steps, not code):**
1. Vercel → the admin-dashboard project → Domains → add `partners.help24.co.ke`.
2. DNS: add a CNAME from `partners` to the target Vercel shows.

No new environment variables are needed. `PARTNER_HOSTS` defaults to `partners.help24.co.ke` and `PARTNER_PORTAL_URL` to `https://partners.help24.co.ke`. Supabase Auth needs no change, because partners sign in with a password and are never redirected.

**Still open:**
- The amount per qualified member, and how agents are paid (P5).
- Checking verified sign-in (phone or Google) before payment (P5).
- Fraud flags (same phone or device).
- The research view (P4) and marketing campaign links (P3).
