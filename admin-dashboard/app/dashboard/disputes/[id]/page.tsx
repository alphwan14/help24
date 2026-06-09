import { createServiceClient } from "@/lib/supabase-server";
import { notFound } from "next/navigation";
import DisputeDetailClient from "./DisputeDetailClient";

// Next.js 15: params is a Promise that must be awaited.
type PageProps = { params: Promise<{ id: string }> };

export default async function DisputeDetailPage({ params }: PageProps) {
  const { id } = await params;
  const db = createServiceClient();
  const { data, error } = await db
    .from("disputes")
    .select(
      `id, status, reason, admin_notes, resolved_by, provider_amount, buyer_refund,
       created_at, resolved_at,
       posts(id, title, price, author_user_id, selected_provider_id, status),
       transactions(id, amount, fee, total_paid, status, mpesa_receipt, created_at),
       job_completions(id, status, provider_note, created_at)`
    )
    .eq("id", id)
    .single();

  if (error || !data) notFound();

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const raw = data as any;

  // Supabase returns joined rows as arrays — grab the first element.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const posts = (Array.isArray(raw.posts) ? raw.posts[0] : raw.posts) as {
    author_user_id: string;
    selected_provider_id: string;
  } | null;

  let buyer = null;
  let provider = null;

  if (posts) {
    const [br, pr] = await Promise.all([
      db.from("users").select("id, name, phone_number").eq("id", posts.author_user_id).single(),
      db.from("users").select("id, name, phone_number").eq("id", posts.selected_provider_id).single(),
    ]);
    buyer = br.data;
    provider = pr.data;
  }

  return <DisputeDetailClient dispute={{ ...raw, posts, buyer, provider }} />;
}
