// DISABLED — chat push notifications are sent exclusively by the NestJS backend
// via POST /notifications/chat-message (called by the Flutter client on each send).
// That path uses the fcm_tokens table, sends MessagingStyle-grouped notifications
// with the correct title format (sender name), and also persists the in-app bell entry.
//
// Keeping this edge function active caused every message to fire TWO FCM pushes:
//   • This function → title "New Message" (generic, via users.fcm_tokens legacy column)
//   • Backend HTTP → title "SenderName" (correct, via fcm_tokens table)
//
// To re-enable: restore the full implementation from git history and re-deploy.

Deno.serve((_req: Request) => {
  console.log("[send-chat-push] disabled — notifications handled by backend HTTP endpoint");
  return new Response(JSON.stringify({ ok: true, disabled: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
