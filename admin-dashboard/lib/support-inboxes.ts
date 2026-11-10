import type { InboxLabel } from "./support";

/**
 * Where each inbox's mail comes in, and who answers it. Mirrors the backend's
 * identityFor (backend/src/support/support-rules.ts): security@ mail is
 * answered from security@ as Help24 Security; support@ and info@ mail from
 * support@ as Help24 Support. Safe in client components.
 */
export const INBOXES: Record<InboxLabel, { name: string; address: string; from: string; signature: string }> = {
  support: { name: "Support", address: "support@help24.co.ke", from: "support@help24.co.ke", signature: "Help24 Support" },
  general: { name: "General", address: "info@help24.co.ke", from: "support@help24.co.ke", signature: "Help24 Support" },
  security: { name: "Security", address: "security@help24.co.ke", from: "security@help24.co.ke", signature: "Help24 Security" },
};
