import { redirect } from "next/navigation";

export default function TrustSafetyIndex() {
  redirect("/dashboard/trust-safety/queue");
}
