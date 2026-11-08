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
