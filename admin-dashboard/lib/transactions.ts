import "server-only";
import { adminRequest } from "./api";
import type { TransactionDetail } from "./transaction-types";

export type * from "./transaction-types";

/**
 * One payment's whole story and the actions that fit it now
 * (GET /admin/transactions/:id, backend admin/payments). The backend decides
 * which actions are offered and re-checks them when one is taken.
 */
export function getTransaction(id: string): Promise<TransactionDetail> {
  return adminRequest<TransactionDetail>(`/admin/transactions/${encodeURIComponent(id)}`);
}
