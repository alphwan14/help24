import { notFound, redirect } from "next/navigation";
import { ApiError, getCurrentAdmin, getDispute, getRecommendation, startEarly } from "@/lib/api";
import type { DisputeRecommendation } from "@/lib/api";
import DisputeDetailClient from "./DisputeDetailClient";
import MoneyPanel from "./MoneyPanel";
import { getDisputeMoney, type DisputeMoney } from "@/lib/finance-api";

export const dynamic = "force-dynamic";

type PageProps = { params: Promise<{ id: string }> };

export default async function DisputeDetailPage({ params }: PageProps) {
  const { id } = await params;

  // The case, its recommendation and its money are independent reads. They
  // used to run one after another AFTER the access check — four backend round
  // trips in series. All four now start together; nothing is read until access
  // is confirmed (see startEarly in lib/api.ts), and each keeps its own
  // handling below.
  const disputeRequest = startEarly(getDispute(id));
  const recommendationRequest = startEarly(getRecommendation(id));
  const moneyRequest = startEarly(getDisputeMoney(id));

  // Authenticate against the backend; bounce to the queue (which shows the
  // connect gate) if no valid admin token.
  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/disputes");

  let dispute;
  try {
    dispute = await disputeRequest;
  } catch (err) {
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) notFound();
    throw err;
  }

  // Advisory recommendation is best-effort — never block the case view on it.
  let recommendation: DisputeRecommendation | null = null;
  try {
    recommendation = await recommendationRequest;
  } catch {
    recommendation = null;
  }

  // Money after the ruling — only once the case is closed; an open case is
  // decided in the case view below. Best-effort like the recommendation: a
  // failure hides the panel, never the case.
  let money: DisputeMoney | null = null;
  try {
    const m = await moneyRequest;
    money = m.dispute.closed ? m : null;
  } catch {
    money = null;
  }

  return (
    <div className="space-y-6">
      {money && <MoneyPanel money={money} role={admin.role} />}
      <DisputeDetailClient dispute={dispute} recommendation={recommendation} admin={admin} />
    </div>
  );
}
