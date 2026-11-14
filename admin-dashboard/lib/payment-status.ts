/**
 * A transaction's status in words, for the payments lists. The raw values
 * (payout_pending, released) are the database's; an admin reads these.
 * A 'paid' row with a failure_reason is a payout M-Pesa refused: the money
 * is back with Help24 and the provider is not paid.
 */
export const PAYMENT_STATUS_WORDS: Record<string, string> = {
  pending: "Waiting for M-Pesa",
  paid: "Held by Help24",
  payout_pending: "Payout sent, no answer yet",
  released: "Provider paid",
  failed: "Payment did not go through",
  disputed: "In dispute",
  refunded: "Refunded to the client",
};

export function paymentStatusWords(status: string, failureReason?: string | null): string {
  if (status === "paid" && failureReason) return "Payout failed";
  return PAYMENT_STATUS_WORDS[status] ?? status.replace(/_/g, " ");
}

export function paymentHref(transactionId: string): string {
  return `/dashboard/payments/${encodeURIComponent(transactionId)}`;
}
