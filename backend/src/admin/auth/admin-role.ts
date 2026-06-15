/**
 * Admin RBAC roles for the Disputes Centre, in ascending privilege order.
 *
 *   support_agent → view cases, comment, add evidence, claim/assign, ESCALATE
 *   senior_admin  → + issue financial decisions (FULL_RELEASE / FULL_REFUND / PARTIAL_SPLIT)
 *   super_admin   → + override cases assigned to others, manage admin_users
 */
export const ADMIN_ROLES = ['support_agent', 'senior_admin', 'super_admin'] as const;
export type AdminRole = (typeof ADMIN_ROLES)[number];

/** Numeric rank used for hierarchical `>=` comparisons. */
const RANK: Record<AdminRole, number> = {
  support_agent: 1,
  senior_admin: 2,
  super_admin: 3,
};

/** True when `role` is at least as privileged as `minimum`. */
export function roleAtLeast(role: AdminRole, minimum: AdminRole): boolean {
  return RANK[role] >= RANK[minimum];
}

/** The authenticated admin attached to the request by AdminAuthGuard. */
export interface AdminContext {
  id: string;
  email: string;
  name: string;
  role: AdminRole;
}
