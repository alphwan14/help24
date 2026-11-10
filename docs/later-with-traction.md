# Later, once Help24 has traction

Features the owner wants but has parked until there is enough traffic for
them to mean something. Each entry says what it is, why it waits, and what
"enough traffic" looks like. Move an item out of here when work starts.

## Reply rate on provider profiles

Parked 2026-11-08 by the owner.

**What:** how responsive a provider is, shown to clients, for example
"Replies to 9 in 10 messages, usually within an hour". On a marketplace it is
one of the strongest reasons to pick one provider over another.

**Why it waits:** with only a handful of conversations, the number is noise.
One unanswered message reads "50% reply rate", the same trap the dispute-rate
rule exists to avoid (counts always, percentages only above a sample).

**What it needs:**

- A backend metric per provider: the share of client-started conversations
  that got a reply within 24 hours, and the median time to first reply. The
  raw data exists (every message has a timestamp); nothing computes it yet.
  This is a backend change, so it needs a named driver under the freeze.
- Add it to the reputation response, then to the Profile stats row (Jobs,
  Rating, Reply rate) and the provider's public profile.
- Show it only above a minimum sample (for example 10 conversations), like
  the percentage rule in `ReputationProfileSection`.

**Start when:** providers routinely have 10+ client conversations each.

## Materials Advance: the parts not built yet

Parked 2026-11-11 by the owner. The feature itself is built and switched off
(`MATERIALS_ADVANCE_ENABLED`, docs/materials-advance.md). These pieces wait
until advances actually happen, because until then there is nothing for them
to show or settle.

**What:**

- **Admin payment and dispute pages show the advance.** Today only the stuck
  alert lists one. Finance and the dispute team should see "KES 4,000 sent for
  materials on 12 Nov, KES 6,000 held" on the job, the payment and the dispute
  page, so a manual refund is never sized from the full job by mistake. Until
  this exists, check `materials_advances` before any manual refund.
- **A "Materials advance" line on the receipt** (amount, date, M-Pesa
  reference), for both the customer's and the provider's copy. The totals on
  today's receipt are already correct.
- **A reconcile button for a stuck advance.** The Transaction Status Query
  answer is already routed to the advance; what is missing is the admin action
  that asks M-Pesa for it, the way the escrow page does for final payouts.
- **SMS for the advance messages** ("Materials money sent", "not sent, try
  again"), once Africa's Talking is wired. Push and in-app only today.
- **A server record of terms acceptance** (who accepted which version, when),
  for proof if a refund or advance is ever contested. Today it is stored on
  the phone only. Needs a small migration and one endpoint.
- **Recovering a misused advance.** The terms say Help24 pursues the fundi;
  the tool for it (hold the fundi's next payouts until the amount is repaid,
  record it on the dispute) does not exist.

**Why it waits:** no provider is verified yet, so no job can use an advance.
The first real advances will show which of these finance needs first.

**Start when:** the switch is on and the first few advances have gone out, or
at the first dispute on a job with an advance, whichever comes first.
