import type { GeoPlace } from "@/lib/analytics";

/**
 * Kenya as dots: each place where something happened, at its real
 * coordinates, sized by activity (requests and offers) and coloured by how
 * much of its demand got an answer. No coastline or borders (no map data is
 * bundled); the shape of Kenya comes from where the places are.
 */

// Kenya's bounding box, a little padded.
const W = { lng0: 33.7, lng1: 42.1, lat0: 5.2, lat1: -4.9 };
const SIZE = { w: 420, h: (420 * (W.lat0 - W.lat1)) / (W.lng1 - W.lng0) };
const x = (lng: number) => ((lng - W.lng0) / (W.lng1 - W.lng0)) * SIZE.w;
const y = (lat: number) => ((W.lat0 - lat) / (W.lat0 - W.lat1)) * SIZE.h;

function tone(g: GeoPlace): string {
  if (g.requests === 0) return "fill-gray-400";
  const r = g.responded / g.requests;
  return r >= 0.5 ? "fill-positive-500" : r > 0 ? "fill-caution-500" : "fill-critical-500";
}

export default function PlaceMap({ places }: { places: GeoPlace[] }) {
  const pts = places.filter((g) => g.lat != null && g.lng != null);
  const maxAct = Math.max(1, ...pts.map((g) => g.requests + g.offers));
  const r = (g: GeoPlace) => 4 + 18 * Math.sqrt((g.requests + g.offers) / maxAct);
  // Label the busiest places, skipping any whose label would land on one
  // already placed (Nairobi's satellites sit within a few pixels of it).
  const labelled = new Set<string>();
  const placed: Array<{ x: number; y: number }> = [];
  for (const g of [...pts].sort((a, b) => b.requests + b.offers - (a.requests + a.offers))) {
    if (labelled.size >= 6) break;
    const px = x(g.lng!), py = y(g.lat!);
    if (placed.some((q) => Math.abs(q.x - px) < 70 && Math.abs(q.y - py) < 22)) continue;
    labelled.add(g.id);
    placed.push({ x: px, y: py });
  }

  return (
    <div>
      <svg viewBox={`0 0 ${SIZE.w} ${SIZE.h}`} className="w-full max-h-[460px]" role="img" aria-label="Activity by place in Kenya">
        {/* A quiet graticule, every 2 degrees */}
        {[34, 36, 38, 40, 42].map((lng) => (
          <line key={`v${lng}`} x1={x(lng)} x2={x(lng)} y1={0} y2={SIZE.h} className="stroke-gray-100" strokeWidth={1} />
        ))}
        {[4, 2, 0, -2, -4].map((lat) => (
          <g key={`h${lat}`}>
            <line x1={0} x2={SIZE.w} y1={y(lat)} y2={y(lat)} className={lat === 0 ? "stroke-gray-200" : "stroke-gray-100"} strokeWidth={1} strokeDasharray={lat === 0 ? "4 4" : undefined} />
            {lat === 0 && (
              <text x={4} y={y(0) - 4} className="fill-gray-400" fontSize={10}>
                Equator
              </text>
            )}
          </g>
        ))}
        {/* Biggest first, so small places stay visible on top */}
        {[...pts]
          .sort((a, b) => r(b) - r(a))
          .map((g) => (
            <g key={g.id}>
              <circle cx={x(g.lng!)} cy={y(g.lat!)} r={r(g)} className={`${tone(g)} opacity-70 stroke-surface`} strokeWidth={1.5}>
                <title>
                  {`${g.name}: ${g.requests} requests, ${g.offers} offers, ${g.requests ? Math.round((g.responded / g.requests) * 100) : 0}% answered`}
                </title>
              </circle>
              {labelled.has(g.id) && (
                <text x={x(g.lng!) + r(g) + 4} y={y(g.lat!) + 4} fontSize={12} className="fill-gray-700 font-medium">
                  {g.name}
                </text>
              )}
            </g>
          ))}
      </svg>
      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 text-[11.5px] text-gray-500">
        <Key className="bg-positive-500" label="Half or more answered" />
        <Key className="bg-caution-500" label="Some answered" />
        <Key className="bg-critical-500" label="None answered" />
        <Key className="bg-gray-400" label="Offers only" />
        <span className="text-gray-400">Size: requests and offers</span>
      </div>
    </div>
  );
}

function Key({ className, label }: { className: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={`h-2.5 w-2.5 rounded-full ${className}`} aria-hidden />
      {label}
    </span>
  );
}
