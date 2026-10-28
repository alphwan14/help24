/** The one help line under each sign-in form (components/auth/AuthShell.tsx). */

const SUPPORT = (
  <a href="mailto:support@help24.co.ke" className="font-medium text-gray-600 hover:text-gray-900 hover:underline">
    support@help24.co.ke
  </a>
);

export const ADMIN_HELP = <>Trouble signing in? Ask your super admin, or write to {SUPPORT}.</>;

export const PARTNER_HELP = <>Need help? Write to {SUPPORT}.</>;
