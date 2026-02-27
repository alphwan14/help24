// Triggered by Database Webhook on public.chat_messages INSERT.
// Uses SUPABASE_SERVICE_ROLE_KEY for all reads (bypasses RLS). Resolves recipient
// from chats (user1, user2), loads fcm_tokens and notifications_enabled, sends FCM v1.
//
// Setup:
// 1. Database > Webhooks > Create webhook on table chat_messages, Events: Insert,
//    Action: Invoke Edge Function "send-chat-push", Method: POST.
// 2. Secrets: SUPABASE_SERVICE_ROLE_KEY, FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "";
const FIREBASE_CLIENT_EMAIL = Deno.env.get("FIREBASE_CLIENT_EMAIL") ?? "";
const FIREBASE_PRIVATE_KEY = Deno.env.get("FIREBASE_PRIVATE_KEY") ?? "";

/** Webhook payload from Supabase Database Webhook (INSERT on chat_messages). */
interface WebhookPayload {
  type?: string;
  table?: string;
  record?: {
    id?: string;
    chat_id?: string;
    sender_id?: string;
    content?: string;
    created_at?: string;
    type?: string;
    attachment_url?: string;
  };
  old_record?: unknown;
}

function ensureString(v: unknown): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  return String(v);
}

function base64urlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  const b64 = btoa(binary);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getGoogleAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: FIREBASE_CLIENT_EMAIL,
    sub: FIREBASE_CLIENT_EMAIL,
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  };
  const header = { alg: "RS256", typ: "JWT" };
  const headerB64 = base64urlEncode(JSON.stringify(header));
  const payloadB64 = base64urlEncode(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;

  const pemContents = FIREBASE_PRIVATE_KEY
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\\n/g, "\n")
    .replace(/\s/g, "");
  const binaryKey = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput)
  );
  const signatureB64 = base64urlEncode(new Uint8Array(signature));
  const jwt = `${signingInput}.${signatureB64}`;

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!tokenRes.ok) {
    const err = await tokenRes.text();
    throw new Error(`Google OAuth2 token failed: ${tokenRes.status} ${err}`);
  }
  const tokenData = (await tokenRes.json()) as { access_token?: string };
  if (!tokenData.access_token) {
    throw new Error("Google OAuth2 response missing access_token");
  }
  return tokenData.access_token;
}

async function sendFcmV1(
  accessToken: string,
  fcmToken: string,
  title: string,
  body: string,
  chatId: string
): Promise<{ ok: boolean; error?: string }> {
  const url = `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`;
  const bodyPayload = {
    message: {
      token: fcmToken,
      notification: { title, body },
      data: { chat_id: String(chatId) },
    },
  };
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify(bodyPayload),
  });
  const text = await res.text();
  if (res.ok) {
    console.log("[FCM v1] success:", res.status, text);
    return { ok: true };
  }
  console.error("[FCM v1] error:", res.status, text);
  return { ok: false, error: text };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch (e) {
    console.error("[send-chat-push] Invalid JSON body:", e);
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const record = payload.record;
  const rawChatId = record?.chat_id;
  const rawSenderId = record?.sender_id;

  if (rawChatId == null || rawSenderId == null || rawChatId === "" || rawSenderId === "") {
    console.error("[send-chat-push] Missing chat_id or sender_id in payload.record");
    return new Response(JSON.stringify({ error: "Missing chat_id or sender_id" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const chatId = ensureString(rawChatId);
  const senderId = ensureString(rawSenderId);

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error("[send-chat-push] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    return new Response(JSON.stringify({ error: "Server misconfiguration" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabaseHeaders = {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };

  try {
    const chatRes = await fetch(
      `${SUPABASE_URL}/rest/v1/chats?id=eq.${encodeURIComponent(chatId)}&select=user1,user2`,
      { headers: supabaseHeaders }
    );
    if (!chatRes.ok) {
      console.error("[send-chat-push] Chats fetch failed:", chatRes.status, await chatRes.text());
      return new Response(JSON.stringify({ error: "Failed to fetch chat" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
    const chats = (await chatRes.json()) as { user1: string; user2: string }[];
    if (!chats?.length) {
      console.log("[send-chat-push] Chat not found:", chatId);
      return new Response(JSON.stringify({ ok: true, reason: "Chat not found" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    const { user1, user2 } = chats[0];
    const recipientId = ensureString(user1) === senderId ? ensureString(user2) : ensureString(user1);

    if (recipientId === senderId || recipientId === "") {
      console.log("[send-chat-push] Recipient is sender or empty, skip push");
      return new Response(JSON.stringify({ ok: true, reason: "Recipient is sender" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const userRes = await fetch(
      `${SUPABASE_URL}/rest/v1/users?id=eq.${encodeURIComponent(recipientId)}&select=fcm_tokens,notifications_enabled`,
      { headers: supabaseHeaders }
    );
    if (!userRes.ok) {
      console.error("[send-chat-push] Users fetch failed:", userRes.status, await userRes.text());
      return new Response(JSON.stringify({ error: "Failed to fetch recipient" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
    const users = (await userRes.json()) as {
      fcm_tokens?: unknown;
      notifications_enabled?: boolean;
    }[];
    if (!users?.length) {
      console.log("[send-chat-push] Recipient not found:", recipientId);
      return new Response(JSON.stringify({ ok: true, reason: "Recipient not found" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    const recipient = users[0];
    const notificationsEnabled = recipient.notifications_enabled === true;
    if (!notificationsEnabled) {
      console.log("[send-chat-push] Notifications disabled for recipient:", recipientId);
      return new Response(JSON.stringify({ ok: true, reason: "Notifications disabled" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    const rawTokens = recipient.fcm_tokens;
    const tokens: string[] = Array.isArray(rawTokens)
      ? (rawTokens as unknown[]).filter((t): t is string => typeof t === "string" && t.length > 0)
      : [];
    if (tokens.length === 0) {
      console.log("[send-chat-push] No fcm_tokens for recipient:", recipientId);
      return new Response(JSON.stringify({ ok: true, reason: "No fcm_tokens" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const senderNameRes = await fetch(
      `${SUPABASE_URL}/rest/v1/users?id=eq.${encodeURIComponent(senderId)}&select=name`,
      { headers: supabaseHeaders }
    );
    const senderRows = senderNameRes.ok
      ? ((await senderNameRes.json()) as { name?: string }[])
      : [];
    const senderName = senderRows?.[0]?.name?.trim() || "Someone";
    const rawContent = record?.content ?? "";
    const messagePreview =
      (typeof rawContent === "string" ? rawContent : String(rawContent)).trim().slice(0, 80) ||
      "New message";
    const title = "New Message";
    const body = `${senderName}: ${messagePreview}`;

    if (!FIREBASE_PROJECT_ID || !FIREBASE_CLIENT_EMAIL || !FIREBASE_PRIVATE_KEY) {
      console.error(
        "[send-chat-push] Missing FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, or FIREBASE_PRIVATE_KEY"
      );
      return new Response(JSON.stringify({ error: "FCM not configured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const accessToken = await getGoogleAccessToken();
    let sent = 0;
    for (const token of tokens) {
      const result = await sendFcmV1(accessToken, token, title, body, chatId);
      if (result.ok) sent++;
    }
    console.log(`[send-chat-push] sent ${sent}/${tokens.length} FCM v1 messages for chat=${chatId}`);

    return new Response(
      JSON.stringify({ ok: true, sent, total: tokens.length, chat_id: chatId }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  } catch (e) {
    console.error("[send-chat-push] error:", e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
