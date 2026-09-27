import { redirect } from "next/navigation";

// Suspensions and bans moved to Trust & Safety, where each one carries a reason,
// an end date and an audit record. The old list read the users.is_banned flag.
export default function SuspendedUsersPage() {
  redirect("/dashboard/trust-safety/suspended");
}
