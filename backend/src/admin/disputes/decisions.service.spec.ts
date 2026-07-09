import { DecisionsService } from './decisions.service';

/**
 * Regression protection for the FULL_RELEASE payout fix (Sprint 1, Phase 1.1).
 *
 * The original bug: a dispute resolution called mpesa.releasePayout() (which only
 * accepted 'paid' transactions) on a 'disputed' transaction, the call threw, the
 * error was swallowed, and the provider was told "payout approved" while receiving
 * nothing — leaving the transaction stuck as 'disputed'.
 *
 * These tests lock in the two halves of the fix:
 *   1. FULL_RELEASE opts into releasing from the 'disputed' state, and only marks
 *      the dispute resolved / notifies after the payout is successfully initiated.
 *   2. A payout-initiation failure is surfaced (not swallowed): the dispute is left
 *      open for retry and no success notification is sent.
 */

function makeSupabaseMock() {
  const updates: Record<string, Array<{ obj: any; col: string; val: any }>> = {};
  const client = {
    from(table: string) {
      return {
        update(obj: any) {
          // Chainable + awaitable: supports `.eq(...)` and `.eq(...).eq(...)`.
          const chain: any = {
            eq: (col: string, val: any) => {
              (updates[table] ??= []).push({ obj, col, val });
              return chain;
            },
            then: (resolve: (v: any) => any) => resolve({ error: null }),
          };
          return chain;
        },
      };
    },
  };
  return { client, updates };
}

function build() {
  const supa = makeSupabaseMock();
  const mpesa = { releasePayout: jest.fn().mockResolvedValue({ message: 'Payout initiated.', transaction_id: 'tx1' }) };
  const notifications = { sendMany: jest.fn().mockResolvedValue(undefined) };
  const events = { emit: jest.fn() };
  const disputes = { systemMessage: jest.fn().mockResolvedValue(undefined) };
  const service = new DecisionsService(
    supa as any,
    notifications as any,
    mpesa as any,
    events as any,
    disputes as any,
  );
  return { service, supa, mpesa, notifications, events, disputes };
}

const admin = { id: 'a1', email: 'admin@help24.io', name: 'Admin', role: 'senior_admin' } as any;

// applyFinancial(type, disputeId, txId, postId, postTitle, providerId, buyerId, providerAmount, clientRefund, admin)
const applyFullRelease = (service: DecisionsService) =>
  (service as any).applyFinancial('FULL_RELEASE', 'd1', 'tx1', 'p1', 'Fix sink', 'prov1', 'buyer1', 100, 0, admin);

describe('DecisionsService FULL_RELEASE payout', () => {
  it('releases a disputed transaction via B2C (allowFromDisputed) and resolves the dispute', async () => {
    const { service, supa, mpesa, notifications } = build();

    await applyFullRelease(service);

    expect(mpesa.releasePayout).toHaveBeenCalledWith({ post_id: 'p1' }, { allowFromDisputed: true });
    // Dispute is transitioned to resolved only after the payout was initiated.
    expect(supa.updates['disputes']?.[0]?.obj.status).toBe('resolved');
    expect(supa.updates['posts']?.[0]?.obj.status).toBe('completed');
    // Parties are notified of the approved payout.
    expect(notifications.sendMany).toHaveBeenCalledTimes(1);
  });

  it('participant thread message NEVER names the admin and does not claim funds were received', async () => {
    const { service, disputes } = build();

    await applyFullRelease(service);

    const msg = disputes.systemMessage.mock.calls[0][1] as string;
    expect(msg).toContain('Decision by admin');
    expect(msg).not.toContain(admin.email); // no email PII
    expect(msg).not.toContain('by Admin'); // no admin display name
    expect(msg).toMatch(/being processed/i); // truthful: not settled yet
    expect(msg).not.toMatch(/released|paid|received/i);
  });

  it('provider payout notification says "being processed", never "released to you"', async () => {
    const { service, notifications } = build();

    await applyFullRelease(service);

    const sent = notifications.sendMany.mock.calls[0][0] as Array<{ userId: string; type: string; body: string }>;
    const providerNote = sent.find((n) => n.userId === 'prov1' && n.type === 'dispute_resolved_release');
    expect(providerNote).toBeDefined();
    expect(providerNote!.body).toMatch(/being processed/i);
    expect(providerNote!.body).not.toMatch(/released the full payment|released.*to you/i);
  });

  it('surfaces a payout failure: dispute stays open, no success notification (no silent swallow)', async () => {
    const { service, supa, mpesa, notifications } = build();
    mpesa.releasePayout.mockRejectedValueOnce(new Error('B2C unavailable'));

    await expect(applyFullRelease(service)).rejects.toThrow('B2C unavailable');

    expect(mpesa.releasePayout).toHaveBeenCalledTimes(1);
    // Critical: the dispute must NOT be marked resolved when the money never moved.
    expect(supa.updates['disputes']).toBeUndefined();
    expect(supa.updates['posts']).toBeUndefined();
    expect(notifications.sendMany).not.toHaveBeenCalled();
  });
});
