import { isDuplicateReport, toHttpError } from './moderation-errors';

describe('toHttpError', () => {
  it.each([
    ['HELP24_MODERATION_INVALID: a suspension needs an end between 1 hour and 1 year from now', 400, 'A suspension needs an end between 1 hour and 1 year from now.'],
    ['HELP24_MODERATION_NOT_FOUND: account not found', 404, 'Account not found.'],
    ['HELP24_MODERATION_CONFLICT: this account is already banned', 409, 'This account is already banned.'],
    ['HELP24_MODERATION_SELF: you cannot moderate your own account', 403, 'You cannot moderate your own account.'],
    ['HELP24_ADMIN_INVALID: the acting admin is unknown or inactive', 403, 'The acting admin is unknown or inactive.'],
    ['HELP24_MODERATION_NO_CHANGE: nothing to update', 400, 'Nothing to update.'],
    ['HELP24_FINANCE_NOT_FOUND: payment not found', 404, 'Payment not found.'],
    ['HELP24_FINANCE_CONFLICT: this is already recorded as paid (completed)', 409, 'This is already recorded as paid (completed).'],
    ['HELP24_FINANCE_FORBIDDEN: applying a ruling needs a senior admin', 403, 'Applying a ruling needs a senior admin.'],
    ['HELP24_FINANCE_INVALID: give a reason of 5 to 1000 characters', 400, 'Give a reason of 5 to 1000 characters.'],
    ['HELP24_APPEND_ONLY: rows in admin_alert_reviews cannot be changed or removed', 403, 'Rows in admin_alert_reviews cannot be changed or removed.'],
  ])('%s → %i with the database sentence passed through', (message, status, sentence) => {
    const e = toHttpError({ code: 'P0001', message });
    expect(e.getStatus()).toBe(status);
    expect((e.getResponse() as { message: string }).message).toBe(sentence);
  });

  it('unrecognised errors are infrastructure faults: 503 with a generic sentence', () => {
    const e = toHttpError({ code: '57014', message: 'canceling statement due to statement timeout' });
    expect(e.getStatus()).toBe(503);
    expect(JSON.stringify(e.getResponse())).not.toContain('statement timeout');
  });

  it('recognises both forms of a duplicate report', () => {
    expect(isDuplicateReport({ message: 'HELP24_REPORT_DUPLICATE: x' })).toBe(true);
    expect(isDuplicateReport({ code: '23505', message: 'violates unique constraint "user_reports_one_open_per_target"' })).toBe(true);
    expect(isDuplicateReport({ code: '23505', message: 'violates unique constraint "something_else"' })).toBe(false);
  });
});
