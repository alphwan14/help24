import { LAYER, LayerTag } from "./Badges";
import { fmtDateTime } from "@/lib/moderation-labels";
import type { TimelineEvent } from "@/lib/moderation-api";

/**
 * One chronology, three kinds of truth. Every row says which layer it belongs
 * to — what the platform recorded, what someone alleged, what an admin
 * decided — so a report never reads like a fact and a fact never reads like a
 * verdict.
 */
export default function Timeline({ events, empty = "Nothing recorded yet." }: { events: TimelineEvent[]; empty?: string }) {
  return (
    <div>
      <div className="flex flex-wrap gap-x-4 gap-y-1.5 mb-4">
        {(Object.keys(LAYER) as Array<keyof typeof LAYER>).map((k) => (
          <span key={k} className="inline-flex items-center gap-1.5 text-[11.5px] text-gray-500">
            <span className={`w-2 h-2 rounded-full ${LAYER[k].dot}`} />
            {LAYER[k].label}
          </span>
        ))}
      </div>
      {events.length === 0 ? (
        <p className="text-[13px] text-gray-400">{empty}</p>
      ) : (
        <ol className="relative border-l border-gray-200 ml-1 space-y-4">
          {events.map((e, i) => (
            <li key={`${e.at}-${e.kind}-${i}`} className="pl-4 relative">
              <span className={`absolute -left-[5px] top-1.5 w-[9px] h-[9px] rounded-full ring-2 ring-surface ${LAYER[e.layer].dot}`} />
              <div className="flex flex-wrap items-center gap-2">
                <LayerTag layer={e.layer} />
                <time dateTime={e.at} className="text-[11.5px] text-gray-400 tabular-nums">
                  {fmtDateTime(e.at)}
                </time>
              </div>
              <p className="text-[13px] text-gray-800 mt-1">{e.label}</p>
              {e.detail && <p className="text-[12.5px] text-gray-500 mt-0.5 whitespace-pre-line break-words">{e.detail}</p>}
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
