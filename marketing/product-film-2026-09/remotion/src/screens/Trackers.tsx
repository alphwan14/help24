import React from 'react';
import { CUE } from '../config/cues';
import { JOB, r, Rect } from '../config/screens';
import { E, ramp } from '../lib/anim';
import { Slice } from '../components/Slice';
import { stageOf } from '../scenes/choreography';
import { useFormat } from '../config/format';

/**
 * The two trackers the app keeps for every job, lifted out of the real
 * job-status screen and laid side by side. Their rows reveal in order - the
 * states themselves are exactly as captured (Payment Required / In Progress);
 * nothing is advanced, because nothing was paid.
 *
 * Only the cards are shown, not the screen's title, so no other job's name
 * appears next to the Emergency Dog Trainer story.
 */
const Card: React.FC<{
  f: number;
  rect: Rect;
  rows: number[];
  at: { x: number; y: number };
  inAt: number;
  rowsAt: number;
}> = ({ f, rect, rows, at, inAt, rowsAt }) => {
  const p = ramp(f, inAt, inAt + 26, E.enter);
  const lift = ramp(f, inAt + 6, inAt + 40, E.move);
  const headH = rows[0] - rect.y;
  const tailY = rows[rows.length - 1];
  const bw = JOB.borderW;
  return (
    <div
      style={{
        position: 'absolute',
        left: at.x,
        top: at.y,
        width: rect.w,
        height: rect.h,
        transform: `translateY(${(1 - p) * 140}px)`,
        opacity: p,
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: JOB.cardRadius,
          boxShadow: `0 ${50 * lift}px ${110 * lift}px -24px rgba(18,22,26,${0.24 * lift}), 0 ${10 * lift}px ${
            26 * lift
          }px rgba(18,22,26,${0.07 * lift})`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: JOB.cardRadius,
          overflow: 'hidden',
          background: '#FFFFFF',
        }}
      >
        {/* header ("Payment" / "Completion") and the card's bottom edge */}
        <Slice shot="job-status" r={r(rect.x, rect.y, rect.w, headH)} x={0} y={0} />
        <Slice shot="job-status" r={r(rect.x, tailY, rect.w, rect.y + rect.h - tailY)} x={0} y={tailY - rect.y} />
        {/* the side borders down the (initially empty) body */}
        <Slice shot="job-status" r={r(rect.x, rows[0], bw, tailY - rows[0])} x={0} y={headH} />
        <Slice shot="job-status" r={r(rect.x + rect.w - bw, rows[0], bw, tailY - rows[0])} x={rect.w - bw} y={headH} />
        {rows.slice(0, -1).map((y0, i) => {
          const y1 = rows[i + 1];
          const q = ramp(f, rowsAt + i * 5, rowsAt + i * 5 + 14, E.out);
          return (
            <Slice
              key={i}
              shot="job-status"
              r={r(rect.x + bw, y0, rect.w - bw * 2, y1 - y0)}
              x={bw}
              y={y0 - rect.y}
              style={{ opacity: q, transform: `translateY(${(1 - q) * 16}px)` }}
            />
          );
        })}
      </div>
    </div>
  );
};

export const Trackers: React.FC<{ f: number }> = ({ f }) => {
  const format = useFormat();
  if (f < CUE.trackersIn - 2 || f > CUE.toHistory + 60) return null;
  const { x, y, gap, stacked } = stageOf(format).trackers;
  // side by side in landscape; stacked in portrait, where they are read top to bottom
  const second = stacked ? { x, y: y + JOB.payment.h + gap } : { x: x + JOB.payment.w + gap, y };
  return (
    <>
      <Card f={f} rect={JOB.payment} rows={JOB.paymentRows} at={{ x, y }} inAt={CUE.trackersIn} rowsAt={CUE.rowsPayment} />
      <Card
        f={f}
        rect={JOB.completion}
        rows={JOB.completionRows}
        at={second}
        inAt={CUE.trackersIn + 7}
        rowsAt={CUE.rowsCompletion}
      />
    </>
  );
};
