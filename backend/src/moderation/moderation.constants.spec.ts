import * as fs from 'fs';
import * as path from 'path';
import { roleAtLeast } from '../admin/auth/admin-role';
import {
  CAPABILITIES,
  LIFT_MIN_ROLE,
  REPORT_CATEGORIES,
  REPORT_STATUSES,
  SANCTION_MIN_ROLE,
  SEVERITIES,
  referenceOf,
} from './moderation.constants';

/**
 * The shared contract. supabase/tests/trust-safety/db.test.mjs pins the SQL
 * (moderation_report_categories, moderation_capabilities, the reason CHECK)
 * against this same file, and mobile-app/test pins the app's ReportCategory —
 * so the three layers cannot disagree about the taxonomy without a failure.
 */
const taxonomy = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, '../../../supabase/tests/trust-safety/report_taxonomy.json'), 'utf8'),
) as { categories: string[]; capabilities: string[]; statuses: string[]; severities: string[] };

describe('moderation constants — parity with the database taxonomy', () => {
  it('report categories', () => expect([...REPORT_CATEGORIES]).toEqual(taxonomy.categories));
  it('capabilities', () => expect([...CAPABILITIES]).toEqual(taxonomy.capabilities));
  it('statuses', () => expect([...REPORT_STATUSES]).toEqual(taxonomy.statuses));
  it('severities', () => expect([...SEVERITIES]).toEqual(taxonomy.severities));
});

describe('moderation constants — the RBAC ladder', () => {
  it('any admin may warn; suspensions and partial restrictions need senior; a ban needs super', () => {
    expect(SANCTION_MIN_ROLE).toEqual({
      warning: 'support_agent',
      messaging: 'senior_admin',
      marketplace: 'senior_admin',
      suspension: 'senior_admin',
      ban: 'super_admin',
    });
  });

  it('lifting follows the same rungs as imposing', () => {
    for (const kind of ['suspension', 'messaging', 'marketplace', 'ban'] as const) {
      expect(LIFT_MIN_ROLE[kind]).toBe(SANCTION_MIN_ROLE[kind]);
    }
  });

  it('a support agent can never ban, whatever else changes', () => {
    expect(roleAtLeast('support_agent', SANCTION_MIN_ROLE.ban)).toBe(false);
    expect(roleAtLeast('senior_admin', SANCTION_MIN_ROLE.ban)).toBe(false);
  });
});

describe('referenceOf', () => {
  it('matches my_account_status(): the first eight hex digits, upper-case', () => {
    // SQL: upper(left(replace(id::text, '-', ''), 8))
    expect(referenceOf('7f3a9c21-0b2d-4e5f-8a9b-0c1d2e3f4a5b')).toBe('7F3A9C21');
  });
});
