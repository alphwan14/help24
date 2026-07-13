import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ArchivedBadge, archivedRowClass } from "@/components/PostStatusBadge";
import { offerRateLabel, schemasByName, smartAnswerLines, type Json } from "@/lib/post-display";

type OfferRow = {
  id: string;
  title: string;
  category: string;
  location: string;
  price: number;
  pricing_type: string;
  archived_at: string | null;
  author_user_id: string | null;
  created_at: string;
  attributes: Json | null;
  users: { name: string | null; email: string | null; phone_number: string | null } | null;
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getOffers() {
  const db = createServiceClient();
  const { data } = await db
    .from("posts")
    .select("id, title, category, location, price, pricing_type, archived_at, author_user_id, created_at, attributes, users(name, email, phone_number)")
    .eq("type", "offer")
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as OfferRow[];
}

async function getSchemas() {
  const db = createServiceClient();
  const { data } = await db.from("categories").select("name, question_schema");
  return schemasByName(data ?? []);
}

export default async function MarketplaceOffersPage() {
  const [rows, schemas] = await Promise.all([getOffers(), getSchemas()]);

  const columns = [
    {
      key: "title",
      label: "Offer",
      render: (r: OfferRow) => {
        const answers = smartAnswerLines(
          schemas.get(r.category?.toLowerCase() ?? "") ?? null,
          "offer",
          r.attributes,
        );
        return (
          <div className="max-w-xs">
            <div className="flex items-center gap-2">
              <p className="font-medium text-gray-900 truncate">{r.title}</p>
              {r.archived_at && <ArchivedBadge />}
            </div>
            <p className="text-xs text-gray-400">{r.category} · {r.location}</p>
            {answers.length > 0 && (
              <p className="text-xs text-indigo-500 truncate" title={answers.join("\n")}>
                {answers.join(" · ")}
              </p>
            )}
          </div>
        );
      },
    },
    {
      key: "provider",
      label: "Provider",
      render: (r: OfferRow) => (
        <div>
          <p className="text-gray-800">{r.users?.name || r.users?.email || "—"}</p>
          {r.users?.email && <p className="text-xs text-gray-400">{r.users.email}</p>}
        </div>
      ),
    },
    {
      key: "phone",
      label: "M-Pesa Phone",
      render: (r: OfferRow) =>
        r.users?.phone_number ? (
          <span className="badge bg-green-100 text-green-700">{r.users.phone_number}</span>
        ) : (
          <span className="badge bg-red-100 text-red-600">Not set</span>
        ),
    },
    {
      key: "price",
      label: "Starting Price",
      render: (r: OfferRow) => (
        <span className="font-medium">{offerRateLabel(r.price, r.pricing_type)}</span>
      ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: OfferRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} results</p>
      <DataTable
        columns={columns}
        rows={rows}
        emptyMessage="No offers found."
        rowClassName={(r) => archivedRowClass(r.archived_at)}
      />
    </div>
  );
}
