import { redirect } from "next/navigation";
import { DASHBOARD_HOME } from "@/lib/routes";

export default function Home() {
  redirect(DASHBOARD_HOME);
}
