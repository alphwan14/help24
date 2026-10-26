/**
 * Which hosts are the partner portal. The same Next app serves
 * admin.help24.co.ke and partners.help24.co.ke; middleware routes by host:
 * a partner host serves ONLY app/partners/*, and an admin host never does.
 *
 * PARTNER_HOSTS (comma-separated, host[:port]) overrides the default — the
 * e2e run uses it to give the portal its own origin on localhost.
 */
const DEFAULT_PARTNER_HOSTS = ["partners.help24.co.ke"];

export function partnerHosts(): string[] {
  const env = process.env.PARTNER_HOSTS;
  return env ? env.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean) : DEFAULT_PARTNER_HOSTS;
}

export function isPartnerHost(host: string | null | undefined): boolean {
  return !!host && partnerHosts().includes(host.toLowerCase());
}

/** Where invitation links point. */
export function partnerPortalUrl(): string {
  return (process.env.PARTNER_PORTAL_URL ?? `https://${partnerHosts()[0]}`).replace(/\/$/, "");
}
