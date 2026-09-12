# Support email — what is actually configured, and what to do about it

Investigation only. **No DNS record was created, changed or deleted, and no
mail service was configured.** Everything below is read from public DNS on
2026-09-12 and from the repository.

---

## 1. The bounce, explained exactly

Gmail reported:

```
The recipient server did not accept our requests to connect.
[help24.co.ke 64.29.17.1: timed out]
[help24.co.ke 216.198.79.1: timed out]
```

Those two addresses are not a mail server. They are the A records of
`help24.co.ke` itself, and they belong to Vercel:

```
help24.co.ke.        A     64.29.17.1
help24.co.ke.        A     216.198.79.1
www.help24.co.ke.    CNAME d09192f04276e37a.vercel-dns-017.com
```

`help24.co.ke` publishes **no MX record at all**. RFC 5321 §5.1 says that when
a domain has no MX, a sending mail server falls back to the domain's A/AAAA
records — the *implicit MX*. So Gmail did the only thing it could: it opened
SMTP connections to Vercel's web front ends on port 25. Vercel serves HTTP and
HTTPS and does not answer on 25, so the connections hung until Gmail gave up.

**There is no mailbox behind `support@help24.co.ke`, and there is no route by
which one could receive mail today.** Nothing is misconfigured; nothing is
configured.

## 2. Full DNS picture as it stands

| Record | `help24.co.ke` | `auth.help24.co.ke` |
|---|---|---|
| Nameservers | `meg.ns.cloudflare.com`, `theo.ns.cloudflare.com` | (inherits) |
| A | `64.29.17.1`, `216.198.79.1` (Vercel) | — |
| CNAME | — | `help24-24410.web.app` (Firebase Hosting) |
| MX | **none** | none |
| SPF (TXT) | **none** | `v=spf1 include:_spf.firebasemail.com ~all` |
| Other TXT | none | `firebase=help24-24410` |
| DMARC | **none** | none |
| CAA | none | none |

Three things follow from that table.

**DNS is hosted at Cloudflare.** The zone is authoritative on Cloudflare
nameservers even though the website is served from Vercel. Any mail records
would be added in the Cloudflare dashboard, which also means Cloudflare Email
Routing is available without moving anything.

**`auth.help24.co.ke` is outbound-only and must be left alone.** It is the
Firebase Auth custom domain: it carries the `firebase=` verification token and
an SPF record authorising Firebase's own senders, which is what lets password
resets arrive as `Help24 Team <noreply@auth.help24.co.ke>`. It has no inbound
role and needs none. Adding MX records to the apex does not touch it.

**The apex has no SPF and no DMARC.** Separate from the inbound problem, this
means nothing anywhere states who may send as `@help24.co.ke`, so the domain is
trivially spoofable in a way receiving servers have no basis to reject.

## 3. Where the dead address is currently advertised

`support@help24.co.ke` is surfaced in 17 places. It is exposed as a `mailto:`
on the website (support, contact, download, privacy, terms, community
guidelines, the close section, and the JSON-LD `ContactPoint` in the site
metadata) and named in the app's Help Centre FAQ answer about account deletion.

Two of those were the worst instances and have been changed in this pass, both
of them copy-only:

* `auth_error_mapper.dart` told a user whose account had just been **suspended**
  to email that address. Now points at `help24.co.ke/support`.
* The auth action and continue pages told a user who suspected their account was
  being attacked to email it. Now link to `/support`.

The remaining references are untouched, because deciding what to do with them
depends on which option below is chosen.

## 4. Options, judged against this configuration

### Cloudflare Email Routing — recommended to start

Free, and the zone is already on Cloudflare, so it is the only option that adds
no new vendor. It publishes Cloudflare's MX records and forwards
`support@help24.co.ke` to an existing mailbox (a Gmail account, say).

* Inbound works immediately; addresses are free and unlimited.
* **It cannot send.** Replies would come from the personal mailbox, which is
  the wrong name on a marketplace's support reply and gives the sender no SPF
  alignment on `help24.co.ke`. Gmail's "send mail as" can paper over this only
  with a separate SMTP relay.
* Best read as a *stopgap that stops the bouncing today*, not as the end state.

### Google Workspace — recommended as the end state

Roughly USD 6–7 per user per month. Real mailboxes, send *and* receive as
`support@help24.co.ke`, shared inbox delegation, and the SPF/DKIM/DMARC records
are generated for you.

* This is the one that makes a reply from Help24 look like it came from Help24.
* For a marketplace that will hold escrow, having support mail that
  authenticates as the domain is not cosmetic — it is what stops Help24's own
  messages being the ones that look like phishing.
* One mailbox is enough at launch; aliases are free.

### Zoho Mail

Has a free tier for a single domain with a handful of users, and can send and
receive. Cheaper than Workspace and materially better than forwarding. Worth
considering if the Workspace cost is unwelcome at this stage.

### A helpdesk (Zendesk, Front, HelpScout, Crisp)

Premature. These solve ticket volume, not delivery, and every one of them still
needs the domain's MX and DKIM configured. Revisit when one mailbox stops
coping.

## 5. Suggested order, when you come to do it

Nothing here has been executed.

1. **Decide the sending story first.** Forwarding-only and real-mailbox are
   different products; picking the mailbox provider first avoids doing the DNS
   twice.
2. Add MX records for the chosen provider at the Cloudflare apex.
3. Add SPF at the apex covering that provider. Note it must be **one merged
   record** — a second `v=spf1` TXT at the same name makes both invalid.
4. Add the provider's DKIM record.
5. Add DMARC at `_dmarc.help24.co.ke`, starting at `p=none` with a reporting
   address, and tighten once the reports are clean.
6. Leave `auth.help24.co.ke` untouched throughout. Its SPF is scoped to that
   subdomain and does not interact with the apex.
7. Send a test message from an external account and confirm delivery **before**
   putting the address back in front of users.
8. Only then revisit the 17 exposure points, and consider whether the app
   should keep pointing at `/support` regardless — a page can be updated
   without an app release, an address baked into a binary cannot.

## 6. One thing worth deciding separately

The app currently routes users to `help24.co.ke/support`, which is a page
offering an email address and a "coming soon" live chat. Once inbound mail
works, that page is honest. Until then it is the best available answer, because
it at least loads.

Whether the *app* should ever advertise a raw address is a separate question
from whether the address works. Pointing at a page keeps the routing editable
after release, which for a pre-launch product is worth more than saving the
user one tap.
