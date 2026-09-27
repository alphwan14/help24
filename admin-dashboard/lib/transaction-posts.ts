import "server-only";
import type { createServiceClient } from "./supabase-server";

type Db = ReturnType<typeof createServiceClient>;

export type TxPost = { title: string | null; archived_at: string | null } | null;

/**
 * Attach each transaction's listing (title, archived_at) with a second query.
 *
 * WHY NOT `posts(title)` IN THE SELECT
 * ------------------------------------
 * Live `transactions.post_id` has no foreign key to `posts`, so PostgREST
 * cannot embed it: every payments page asked for `posts(title)`, got
 * "Could not find a relationship between 'transactions' and 'posts'", ignored
 * the error and rendered an EMPTY table while 45 transactions existed. A
 * lookup by id works whether or not the key is ever added.
 */
export async function attachPosts<T extends { post_id: string | null }>(
  db: Db,
  rows: T[],
): Promise<Array<T & { posts: TxPost }>> {
  const ids = [...new Set(rows.map((r) => r.post_id).filter((id): id is string => !!id))];
  const byId = new Map<string, TxPost>();
  // Chunked so a long page never builds an over-long request URL.
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await db.from("posts").select("id, title, archived_at").in("id", ids.slice(i, i + 100));
    if (error) {
      // Titles are decoration; the money rows still render, labelled by id.
      console.error("[payments] post titles unavailable:", error.message);
      break;
    }
    for (const p of data ?? []) byId.set(p.id as string, { title: p.title as string | null, archived_at: p.archived_at as string | null });
  }
  return rows.map((r) => ({ ...r, posts: (r.post_id && byId.get(r.post_id)) || null }));
}
