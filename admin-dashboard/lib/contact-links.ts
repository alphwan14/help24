/**
 * Links that reach a member from the dashboard — call, WhatsApp, email.
 *
 * Numbers in public.users are typed by people: "0712 345 678", "+254712…",
 * "254712…", "712345678". WhatsApp's wa.me needs the international form with
 * no plus and no spaces, so a Kenyan local number is rewritten to 254…; a
 * number that is not recognisably Kenyan is used as typed, digits only, and
 * anything too short to dial gets no link at all.
 */

function digits(phone: string): string {
  return phone.replace(/[^\d]/g, "");
}

/** International digits (2547…/2541…), or null when it cannot be dialled. */
export function internationalDigits(phone: string | null | undefined): string | null {
  if (!phone) return null;
  const d = digits(phone);
  if (/^0[17]\d{8}$/.test(d)) return `254${d.slice(1)}`;
  if (/^[17]\d{8}$/.test(d)) return `254${d}`;
  if (/^254[17]\d{8}$/.test(d)) return d;
  return d.length >= 10 && d.length <= 15 ? d : null;
}

export function telHref(phone: string | null | undefined): string | null {
  const d = internationalDigits(phone);
  return d ? `tel:+${d}` : null;
}

export function whatsappHref(phone: string | null | undefined): string | null {
  const d = internationalDigits(phone);
  return d ? `https://wa.me/${d}` : null;
}

export function mailtoHref(email: string | null | undefined): string | null {
  const e = email?.trim();
  return e && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) ? `mailto:${e}` : null;
}
