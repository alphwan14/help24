import { notFound } from "next/navigation";
import RestoringAccess from "../../disputes/RestoringAccess";
import { ApiError, getCurrentAdmin, startEarly } from "@/lib/api";
import { getSupportThread, type SupportThread } from "@/lib/support";
import { maskMediaUrls } from "@/lib/media-link";
import ThreadView from "./ThreadView";

export const dynamic = "force-dynamic";

/** One conversation: the messages, the composer, and who the member is. */
export default async function ConversationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();

  const threadRequest = startEarly(getSupportThread(id));
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  let thread: SupportThread;
  try {
    thread = await threadRequest;
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) notFound();
    return (
      <p role="alert" className="rounded-xl bg-critical-50 px-4 py-3 text-sm text-critical-700">
        {e instanceof ApiError ? e.message : "This conversation could not be read."} Reload to try again.
      </p>
    );
  }

  // Photos open under admin.help24.co.ke, never a storage address.
  return <ThreadView thread={maskMediaUrls(thread)} />;
}
