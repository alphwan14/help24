import { readFileSync } from 'fs';
import { join } from 'path';

/**
 * The feed and promoted slots are served to every client, guests included, and
 * they read through the service role — so no RLS policy can stop them from
 * handing out personal data. They used to embed every author's and applicant's
 * email and phone number. They now embed people from public_profiles
 * (migration 123), which carries neither.
 *
 * This reads the source on purpose: the selects are string constants, and the
 * property that matters is what the string asks Postgres for.
 */
const SERVED_TO_CLIENTS = ['feed/feed.repository.ts', 'promotions/serving.service.ts'];

describe('people embedded in client-facing selects carry no email or phone number', () => {
  it.each(SERVED_TO_CLIENTS)('%s', (file) => {
    const source = readFileSync(join(__dirname, '..', file), 'utf8');
    const embeds = [...source.matchAll(/(?:users|public_profiles)[!:][^()]*\(([^)]*)\)/g)].map((m) => m[0]);

    expect(embeds.length).toBeGreaterThan(0);
    for (const embed of embeds) {
      expect(embed).toContain('public_profiles');
      expect(embed).not.toMatch(/\bemail\b|\bphone_number\b/);
    }
  });
});
