"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";
import type { ConversationStatus } from "./support";

/**
 * Inbox writes, through the backend (/admin/support). Each returns a result
 * instead of throwing, so the composer can say what happened in place.
 */

export type SupportResult = {
  ok: boolean;
  error?: string;
  /** A reply was saved but the email did not go: why, in words an admin can act on. */
  notSent?: string;
  conversationId?: string;
};

function fail(err: unknown): SupportResult {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

type Delivery = { id: string; delivery: "sent" | "failed"; delivery_error: string | null };

export async function sendSupportReply(conversationId: string, body: string): Promise<SupportResult> {
  try {
    const r = await adminActionRequest<Delivery>(`/admin/support/conversations/${conversationId}/replies`, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
    revalidatePath(`/dashboard/inbox/${conversationId}`);
    revalidatePath("/dashboard/inbox");
    return r.delivery === "sent" ? { ok: true } : { ok: true, notSent: r.delivery_error ?? "The email was not sent." };
  } catch (err) {
    return fail(err);
  }
}

export async function retrySupportReply(conversationId: string, messageId: string): Promise<SupportResult> {
  try {
    const r = await adminActionRequest<Delivery>(
      `/admin/support/conversations/${conversationId}/messages/${messageId}/retry`,
      { method: "POST" },
    );
    revalidatePath(`/dashboard/inbox/${conversationId}`);
    return r.delivery === "sent" ? { ok: true } : { ok: true, notSent: r.delivery_error ?? "The email was not sent." };
  } catch (err) {
    return fail(err);
  }
}

export async function addSupportNote(conversationId: string, body: string): Promise<SupportResult> {
  try {
    await adminActionRequest(`/admin/support/conversations/${conversationId}/notes`, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
    revalidatePath(`/dashboard/inbox/${conversationId}`);
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

export async function setSupportStatus(conversationId: string, status: ConversationStatus): Promise<SupportResult> {
  try {
    await adminActionRequest(`/admin/support/conversations/${conversationId}`, {
      method: "PATCH",
      body: JSON.stringify({ status }),
    });
    revalidatePath(`/dashboard/inbox/${conversationId}`);
    revalidatePath("/dashboard/inbox");
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

export async function startSupportConversation(input: {
  email: string;
  subject: string;
  body: string;
  /** support@ as Help24 Support (default) or security@ as Help24 Security. */
  from?: "support" | "security";
}): Promise<SupportResult> {
  try {
    const r = await adminActionRequest<{ conversationId: string } & Delivery>("/admin/support/conversations", {
      method: "POST",
      body: JSON.stringify(input),
    });
    revalidatePath("/dashboard/inbox");
    return {
      ok: true,
      conversationId: r.conversationId,
      ...(r.delivery === "sent" ? {} : { notSent: r.delivery_error ?? "The email was not sent." }),
    };
  } catch (err) {
    return fail(err);
  }
}
