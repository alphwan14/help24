import "server-only";
import { adminRequest } from "./api";

import type { DisputeMoney } from "./finance-types";

export type { DisputeMoney, ShareState } from "./finance-types";

export function getDisputeMoney(disputeId: string): Promise<DisputeMoney> {
  return adminRequest<DisputeMoney>(`/admin/finance/disputes/${encodeURIComponent(disputeId)}/money`);
}
