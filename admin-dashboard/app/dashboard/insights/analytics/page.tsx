import { redirect } from "next/navigation";

export default function AnalyticsPage() {
  redirect("/dashboard/insights/trends");
}
