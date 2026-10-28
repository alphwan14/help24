import type { AuthAudience } from "@/components/auth/AuthShell";

/** What each sign-in page says about the place behind it (components/auth/AuthShell.tsx). */

export const ADMIN_AUDIENCE: AuthAudience = {
  product: "Help24 Operations",
  headline: "Look after Help24, together.",
  lede: "The console the Help24 team uses to look after members, their money and their trust in the marketplace.",
  points: [
    "Members, requests, payments and disputes in one place",
    "Every decision recorded with who made it and why",
    "Access by invitation from a super admin",
  ],
  help: <>Trouble signing in? Ask your super admin, or write to <a href="mailto:support@help24.co.ke" className="font-medium text-gray-600 hover:text-gray-900 hover:underline">support@help24.co.ke</a>.</>,
};

export const PARTNER_AUDIENCE: AuthAudience = {
  product: "Help24 Partners",
  headline: "Every member you bring, in one place.",
  lede: "For the agents who introduce people to Help24 — in person, by link or by QR code.",
  points: [
    "Your agent code, link and QR code, ready to share",
    "Each member appears the moment they join with your code",
    "See who has qualified, and what the rest still need",
  ],
  help: <>Need help? Write to <a href="mailto:support@help24.co.ke" className="font-medium text-gray-600 hover:text-gray-900 hover:underline">support@help24.co.ke</a>.</>,
};
