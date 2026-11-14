/**
 * The Help24 mark, drawn to follow the theme.
 *
 * The console used to show the app icon (`/help24.png`, a near-black tile)
 * wherever the brand appeared, so in light mode a dark block sat on a light
 * page and read as pasted on. Inside the product the mark stands on its own,
 * the way the mobile app shows it: the two bars take the page's text colour
 * (ink in light mode, paper in dark) and the crossbar is always brand amber.
 *
 * The tile belongs to places with no page around it: the browser tab
 * (public/favicon.svg) and a phone's home screen (public/help24.png).
 */
export default function BrandMark({ size = 28, className = "" }: { size?: number; className?: string }) {
  return (
    <svg
      width={size}
      height={size}
      // The brand mark's own geometry (branding/help24-mark.svg, 60 x 56),
      // centred in a square.
      viewBox="-6 -8 72 72"
      role="img"
      aria-label="Help24"
      className={["shrink-0 text-gray-900", className].join(" ")}
    >
      <rect x="0" y="0" width="11" height="56" rx="5.5" fill="currentColor" />
      <rect x="49" y="0" width="11" height="56" rx="5.5" fill="currentColor" />
      <rect x="19" y="22" width="22" height="12" rx="6" fill="#E8A33D" />
    </svg>
  );
}
