import { AdminAlert } from '../alerts/alert-rules';

/** A support alert carrying member details the emails must never repeat. */
export function alert(over: Partial<AdminAlert> = {}): AdminAlert {
  return {
    id: 'support_waiting',
    category: 'support',
    priority: 'medium',
    title: '1 support conversation is waiting for a reply',
    detail: 'Mary Wanjiku · waiting 2h',
    action: 'Reply from the Inbox',
    count: 1,
    amount_kes: 2500,
    oldest_at: '2026-11-11T06:00:00.000Z',
    latest_at: '2026-11-11T06:00:00.000Z',
    href: '/dashboard/inbox',
    fingerprint: 'fp1',
    items: [{ id: 'c1', label: 'Payout not received', detail: 'Mary Wanjiku · 0712345678', at: '2026-11-11T06:00:00.000Z' }],
    review: null,
    ...over,
  };
}
