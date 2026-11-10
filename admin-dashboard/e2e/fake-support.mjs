// The backend's support Inbox (/admin/support, migration 138) for the e2e
// run: conversations and messages in memory, with the same outcomes as the
// real service (backend/src/support/support.service.ts): a sent reply waits on
// the member, a failed one stays on Help24 and can be sent again, a note is
// never emailed.
import { randomUUID } from "node:crypto";

export function createFakeSupport({ personByEmail }) {
  const conversations = [];
  const messages = [];
  /** Every email the Inbox sent, as the mail provider would have. */
  const mailOut = [];
  let mailDown = false;
  let refSeq = 0;

  const now = () => new Date().toISOString();
  const touch = (c, status) => {
    if (status) c.status = status;
    c.last_message_at = now();
  };
  const open = ({ email, name = null, subject, startedBy, label = "support" }) => {
    const c = {
      id: randomUUID(),
      ref: `H24-TEST${String.fromCharCode(65 + (refSeq++ % 26))}${String.fromCharCode(65 + (refSeq % 26))}`,
      label, status: "open", subject, contact_email: email.toLowerCase(), contact_name: name,
      user_id: personByEmail(email)?.id ?? null, started_by: startedBy, last_message_at: now(), created_at: now(),
    };
    conversations.push(c);
    return c;
  };
  const deliver = (c, m) => {
    if (mailDown) {
      m.delivery = "failed";
      m.delivery_error = "Email sending is not set up on the server (RESEND_API_KEY).";
      touch(c, "open");
    } else {
      m.delivery = "sent";
      m.delivery_error = null;
      mailOut.push({ to: c.contact_email, subject: `Re: ${c.subject} [${c.ref}]`, text: `${m.body}\n\nHelp24 Support\nhelp24.co.ke` });
      touch(c, "waiting");
    }
    return { id: m.id, delivery: m.delivery, delivery_error: m.delivery_error };
  };
  const reply = (c, admin, body) => {
    const m = { id: randomUUID(), conversation_id: c.id, author: "staff", admin_id: admin.id, internal: false, channel: "email", body: body.trim(), full_body: null, sender_verified: null, attachment_count: 0, delivery: "sending", delivery_error: null, created_at: now() };
    messages.push(m);
    return deliver(c, m);
  };

  return {
    mailOut,
    conversations,
    setMailDown(v) {
      mailDown = v;
    },
    /** As if workers/help24-mail had delivered an email to support@ or info@. */
    inbound({ from, name = null, to = "support@help24.co.ke", subject, text, verified = true, attachments = 0 }) {
      const c = open({ email: from, name, subject, startedBy: "member", label: to.startsWith("info@") ? "general" : "support" });
      messages.push({ id: randomUUID(), conversation_id: c.id, author: "member", admin_id: null, internal: false, channel: "email", body: text, full_body: null, sender_verified: verified, attachment_count: attachments, delivery: null, delivery_error: null, created_at: now() });
      return c;
    },
    /** Handles /admin/support/*; `admin` is the token's admin. Returns the response, or null if not ours. */
    handle({ method, p, url, body, admin, send, apiFail }) {
      if (method === "GET" && p === "/admin/support/conversations") {
        const status = url.searchParams.get("status");
        const label = url.searchParams.get("label");
        const list = conversations
          .filter((c) => (status ? c.status === status : true) && (label ? c.label === label : true))
          .sort((a, b) => b.last_message_at.localeCompare(a.last_message_at))
          .map((c) => {
            const last = messages.filter((m) => m.conversation_id === c.id && !m.internal).at(-1);
            return { ...c, preview: last ? { author: last.author, body: last.body.slice(0, 160) } : null };
          });
        const counts = { open: 0, waiting: 0, closed: 0 };
        for (const c of conversations) counts[c.status]++;
        return send(200, { counts, conversations: list });
      }
      if (method === "POST" && p === "/admin/support/conversations") {
        if (!body.email || !body.subject?.trim() || !body.body?.trim()) return apiFail(400, "Write a message first.");
        const c = open({ email: body.email, subject: body.subject.trim(), startedBy: "staff" });
        return send(201, { conversationId: c.id, ...reply(c, admin, body.body) });
      }
      const m = /^\/admin\/support\/conversations\/([0-9a-f-]{36})(\/.*)?$/.exec(p);
      if (!m) return null;
      const c = conversations.find((x) => x.id === m[1]);
      if (!c) return apiFail(404, "Conversation not found.");
      const rest = m[2] ?? "";
      if (method === "GET" && rest === "") {
        const person = c.user_id ? personByEmail(c.contact_email) : null;
        return send(200, {
          conversation: c,
          member: person ? { id: person.id, name: null, email: person.email, phone_number: null, created_at: "2026-09-01T08:00:00Z", last_seen: null } : null,
          messages: messages.filter((x) => x.conversation_id === c.id).map((x) => ({ ...x, admin_name: x.admin_id ? admin.name : null })),
        });
      }
      if (method === "PATCH" && rest === "") {
        if (!["open", "waiting", "closed"].includes(body.status)) return apiFail(400, "Unknown status.");
        c.status = body.status;
        return send(200, { id: c.id, status: c.status });
      }
      if (method === "POST" && rest === "/replies") {
        if (!body.body?.trim()) return apiFail(400, "Write a message first.");
        return send(201, reply(c, admin, body.body));
      }
      if (method === "POST" && rest === "/notes") {
        if (!body.body?.trim()) return apiFail(400, "Write a message first.");
        const note = { id: randomUUID(), conversation_id: c.id, author: "staff", admin_id: admin.id, internal: true, channel: "note", body: body.body.trim(), full_body: null, sender_verified: null, attachment_count: 0, delivery: null, delivery_error: null, created_at: now() };
        messages.push(note);
        return send(201, { id: note.id });
      }
      const retry = /^\/messages\/([0-9a-f-]{36})\/retry$/.exec(rest);
      if (method === "POST" && retry) {
        const msg = messages.find((x) => x.id === retry[1] && x.conversation_id === c.id);
        if (!msg || msg.delivery !== "failed") return apiFail(400, "Only a reply that was not sent can be sent again.");
        return send(200, deliver(c, msg));
      }
      return null;
    },
  };
}
