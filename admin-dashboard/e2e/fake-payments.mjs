// The backend's payment page (/admin/transactions/:id, backend admin/payments)
// for the e2e run: one payment's story and its actions, in memory, with the
// same rules as backend/src/admin/payments/payment-view.ts: an action is
// offered only when the payment fits it, money actions need a senior admin,
// every action needs a reason (except Check with M-Pesa) and is recorded with
// the admin's name before it takes effect.
import { randomUUID } from "node:crypto";

const SENIOR = ["senior_admin", "super_admin"];

export function createFakePayments() {
  const payments = new Map();
  /** Every action the backend accepted: { id, action, body, admin }. */
  const taken = [];
  const now = () => new Date().toISOString();

  function actionsFor(s, role) {
    const senior = SENIOR.includes(role);
    const out = [];
    const offer = (id, label, explanation, needsSenior) =>
      out.push({ id, label, explanation, allowed: !needsSenior || senior, blocked_reason: needsSenior && !senior ? "A senior admin takes this action." : null });
    const disputed = s.disputes.some((d) => !["resolved", "merged"].includes(d.status));
    if (s.tx.status === "paid" && s.escrow === "locked" && !disputed && s.completion?.status === "approved") {
      offer("retry_payout", "Retry payout", `Sends KES ${s.tx.amount} to the provider on M-Pesa again.`, true);
    }
    if (s.tx.status === "payout_pending") offer("check_mpesa", "Check with M-Pesa", "Asks M-Pesa what happened to this payout.", true);
    if (s.tx.status === "paid" && s.escrow === "locked" && !disputed && s.completion?.status === "pending_approval") {
      offer("approve_completion", "Approve completion now", "Approves the finished work for the client and starts the payout to the provider. Both are told.", true);
    }
    if (["paid", "payout_pending"].includes(s.tx.status) && !disputed) {
      offer("open_dispute", "Open a dispute", "Opens a case for the client or the provider and freezes the money until a senior admin decides it in Disputes.", false);
    }
    return out;
  }

  function view(s, admin) {
    const label = s.disputes.some((d) => d.status === "open") ? ["disputed", "In dispute", "Funds are frozen while an admin reviews the dispute."]
      : s.tx.status === "payout_pending" ? ["payout_processing", "Payout processing", "Payout has been initiated and is awaiting confirmation."]
      : ["in_escrow", "Payment protected", "The money is held safely by Help24 until the work is approved."];
    return {
      transaction: { ...s.tx, phone: "254712345678", receipt_number: "H24-RCPT-0001", failure_reason: null },
      settlement: {
        state: label[0], label: label[1], explanation: label[2], attention_required: false, is_terminal: false,
        amounts: { amount: s.tx.amount, fee: s.tx.fee, total_paid: s.tx.total_paid, provider_amount: null, client_refund: null, provider_owed: null, advance_paid: null, held: s.tx.amount },
      },
      post: { ...s.post, type: "request", category: "plumbing", location: "Kilimani", price: s.tx.amount, archived_at: null },
      client: { id: s.post.author_user_id, name: null, email: null, phone_number: null },
      provider: { id: s.post.selected_provider_id, name: null, email: null, phone_number: null },
      escrow: { status: s.escrow, released_at: null, created_at: s.tx.created_at },
      completion: s.completion,
      materials_advance: null,
      disputes: s.disputes,
      attempts: [{ id: s.tx.id, status: s.tx.status, total_paid: s.tx.total_paid, failure_reason: null, created_at: s.tx.created_at }],
      timeline: [...s.timeline].sort((a, b) => a.at.localeCompare(b.at)),
      actions: actionsFor(s, admin.role),
      admin_actions: s.adminActions,
    };
  }

  const PATHS = { "retry-payout": "retry_payout", "check-mpesa": "check_mpesa", "approve-completion": "approve_completion", "open-dispute": "open_dispute" };
  const TITLES = { approve_completion: "Admin approved the finished work", open_dispute: "Admin opened a dispute", retry_payout: "Admin sent the payout again", check_mpesa: "Admin asked M-Pesa about the payout" };

  return {
    taken,
    /** A paid job whose provider marked it done; the client has not answered. */
    addAwaitingApproval({ title, clientId, providerId }) {
      const id = randomUUID();
      const paidAt = new Date(Date.now() - 3 * 86400e3).toISOString();
      const doneAt = new Date(Date.now() - 86400e3).toISOString();
      payments.set(id, {
        tx: { id, status: "paid", amount: 2500, fee: 45, total_paid: 2545, mpesa_receipt: "QK12ABC34", created_at: paidAt },
        post: { id: randomUUID(), title, status: "assigned", created_at: new Date(Date.now() - 4 * 86400e3).toISOString(), author_user_id: clientId, selected_provider_id: providerId },
        escrow: "locked",
        completion: { id: randomUUID(), status: "pending_approval", created_at: doneAt, reviewed_at: null, auto_approve_at: new Date(Date.now() + 86400e3).toISOString(), approved_by: null },
        disputes: [],
        adminActions: [],
        timeline: [
          { at: new Date(Date.now() - 4 * 86400e3).toISOString(), title: "Request posted", detail: null, tone: "neutral", by: null },
          { at: paidAt, title: "This payment: KES 2,545 paid", detail: "M-Pesa QK12ABC34", tone: "good", by: null },
          { at: doneAt, title: "Provider marked the job as done", detail: "Waiting for the client.", tone: "neutral", by: null },
        ],
      });
      return { id, row: { id, post_id: payments.get(id).post.id, buyer_user_id: clientId, amount: 2500, fee: 45, total_paid: 2545, status: "paid", mpesa_receipt: "QK12ABC34", failure_reason: null, created_at: paidAt, payment_receipts: [] } };
    },
    state: (id) => payments.get(id),
    /** Handles /admin/transactions/*; `admin` is the token's admin. Returns the response, or null if not ours. */
    handle({ method, p, body, admin, send, apiFail }) {
      const m = /^\/admin\/transactions\/([^/]+)(?:\/([a-z-]+))?$/.exec(p);
      if (!m) return null;
      if (!/^[0-9a-f-]{36}$/.test(m[1])) return apiFail(400, "Validation failed (uuid is expected)");
      const s = payments.get(m[1]);
      if (!s) return apiFail(404, "Payment not found.");
      if (method === "GET" && !m[2]) return send(200, view(s, admin));
      const action = PATHS[m[2] ?? ""];
      if (method !== "POST" || !action) return null;

      const offered = actionsFor(s, admin.role).find((a) => a.id === action);
      if (!offered) return apiFail(409, "That action does not fit this payment as it stands now. Reload the page.");
      if (!offered.allowed) return apiFail(403, offered.blocked_reason);
      const reason = action === "check_mpesa" ? "Asked M-Pesa for the status of this payout." : String(body.reason ?? "").trim();
      if (reason.length < 5) return apiFail(400, "Say why, in a few words (at least 5 characters).");
      if (action === "open_dispute" && !["client", "provider"].includes(body.raised_by)) return apiFail(400, "raised_by must be one of: client, provider");

      taken.push({ id: s.tx.id, action, body, admin: admin.email });
      const at = now();
      s.adminActions.push({ action_type: action, admin_email: admin.email, admin_role: admin.role, reason, created_at: at });
      s.timeline.push({ at, title: TITLES[action], detail: reason, tone: "neutral", by: `${admin.email} (${admin.role})` });
      if (action === "approve_completion") {
        s.completion = { ...s.completion, status: "approved", approved_by: "admin", reviewed_at: at };
        s.tx.status = "payout_pending";
        s.escrow = "payout_pending";
        s.timeline.push({ at, title: "Work approved by Help24", detail: null, tone: "good", by: null });
        return send(200, { ok: true, message: "Approved. The payout to the provider has started." });
      }
      if (action === "open_dispute") {
        const d = { id: randomUUID(), status: "open", raised_by_role: body.raised_by, opened_by_admin_id: "admin", created_at: at, escalated_at: null, resolved_at: null };
        s.disputes.push(d);
        s.timeline.push({ at, title: `Dispute opened by Help24 for the ${body.raised_by}`, detail: "Money frozen until it is decided.", tone: "attention", by: null });
        return send(201, { ok: true, dispute_id: d.id, message: "Dispute opened. The money is frozen until it is decided." });
      }
      return send(200, { ok: true, message: action === "check_mpesa" ? "Asked M-Pesa for the result." : "Payout sent to M-Pesa." });
    },
  };
}
