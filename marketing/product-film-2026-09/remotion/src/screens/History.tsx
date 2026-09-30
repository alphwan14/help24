import React from 'react';
import { CUE } from '../config/cues';
import { APP_PAGE, HISTORY as H } from '../config/screens';
import { E, ramp } from '../lib/anim';
import { Slice } from '../components/Slice';
import { StatusBar } from '../components/StatusBar';

/**
 * Service History -> My Work, as captured. The figures are this account's own
 * in-app values, not platform statistics, and the film does not caption them.
 * The summary and rows settle in order; the "Payment protected" chip on the
 * last row is where the closing mark comes from.
 */
export const HistoryScreen: React.FC<{ f: number }> = ({ f }) => {
  const settle = (i: number) => ramp(f, CUE.historyRows + i * 5, CUE.historyRows + 24 + i * 5, E.out);
  const chipGone = f >= CUE.chipLift;
  const items = [H.summary, ...H.rows];
  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE }}>
      <Slice shot="history-work" r={H.top} />
      {items.map((it, i) => {
        const p = settle(i);
        return (
          <Slice
            key={i}
            shot="history-work"
            r={it}
            style={{ transform: `translateY(${(1 - p) * 60}px)`, opacity: p }}
          >
            {i === items.length - 1 && chipGone && (
              <div
                style={{
                  position: 'absolute',
                  left: H.protectedChip.x - it.x - 2,
                  top: H.protectedChip.y - it.y - 2,
                  width: H.protectedChip.w + 4,
                  height: H.protectedChip.h + 4,
                  background: '#FFFFFF',
                }}
              />
            )}
          </Slice>
        );
      })}
      <Slice shot="history-work" r={H.bottom} style={{ opacity: settle(items.length) }} />
      <StatusBar />
    </div>
  );
};
