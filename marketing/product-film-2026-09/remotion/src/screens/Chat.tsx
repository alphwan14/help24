import React from 'react';
import { CUE } from '../config/cues';
import { APP_PAGE, CHAT as CH, SECURE as S } from '../config/screens';
import { clamp01, E, mix, ramp, springAt } from '../lib/anim';
import { Slice } from '../components/Slice';
import { StatusBar } from '../components/StatusBar';
import { Veil } from '../components/Press';

/**
 * The real conversation pinned to the Emergency Dog Trainer job, played back
 * message by message. Every bubble is its own slice of the capture; the final
 * frame is the capture's own layout, scrolled so the latest message rests just
 * above the composer - as the app keeps it.
 *
 * m1 is already there when we arrive; the rest land with an irregular,
 * conversational rhythm (see CUE.m2..m6), with a pause before "Arrived".
 */
const ARRIVE = [CUE.toChat, CUE.m2, CUE.m3, CUE.m4, CUE.m5, CUE.m6];
const SHIFT_FRAMES = 15;

const restOffset = (i: number) => {
  const m = CH.msgs[i].rect;
  return CH.restBottom - (m.y + m.h);
};

/** How far the whole stack is pushed down, so the latest message sits above the composer. */
export const stackOffset = (f: number) => {
  let off = restOffset(0);
  for (let i = 1; i < ARRIVE.length; i++) {
    const p = ramp(f, ARRIVE[i], ARRIVE[i] + SHIFT_FRAMES, E.move);
    off = mix(off, restOffset(i), p);
  }
  return off;
};

/** Incoming runs: the avatar sits beside the last bubble of a run (m2 alone; then m4, m5, m6). */
const RUNS = [[1], [3, 4, 5]];

export const toChatT = (f: number) => ramp(f, CUE.toChat, CUE.toChat + 26, E.move);

export const ChatScreen: React.FC<{ f: number }> = ({ f }) => {
  const t = toChatT(f);
  const x = (1 - t) * 240;
  const opacity = ramp(t, 0.25, 0.8, E.linear);
  const off = stackOffset(f);
  const leave = ramp(f, CUE.toTrackers, CUE.toTrackers + 20, E.linear);
  // while "Arrived" is held, the rest of the thread recedes
  const arrivedFocus = Math.min(ramp(f, CUE.arrivedPush + 6, CUE.arrivedPush + 34, E.move), 1 - leave);
  const m5 = CH.msgs[4].rect;
  const bannerTitleHidden = f < CUE.toChat + 30;

  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE, transform: `translateX(${x}px)`, opacity }}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: CH.viewport.y,
          width: 1080,
          height: CH.viewport.h,
          overflow: 'hidden',
        }}
      >
        <div style={{ position: 'absolute', left: 0, top: off - CH.viewport.y, width: 1080, height: 2400 }}>
          <Slice shot="chat" r={CH.dateChip} />
          {CH.msgs.map((m, i) => {
            if (f < ARRIVE[i]) return null;
            const first = i === 0;
            const p = first ? 1 : springAt(f, ARRIVE[i], 17, i === 4 ? 0.16 : 0.1);
            const o = first ? 1 : ramp(f, ARRIVE[i], ARRIVE[i] + 7, E.linear);
            const q = clamp01(p);
            const tf = m.out
              ? `translateY(${(1 - q) * 80}px) scale(${0.93 + 0.07 * p})`
              : `translate(${(1 - q) * -26}px, ${(1 - q) * 26}px) scale(${0.93 + 0.07 * p})`;
            return (
              <Slice
                key={m.id}
                shot="chat"
                r={m.rect}
                style={{
                  transform: tf,
                  transformOrigin: m.out ? '100% 100%' : '0% 100%',
                  opacity: o,
                }}
              />
            );
          })}
          <Avatar f={f} />
        </div>
      </div>
      <Slice shot="chat" r={CH.top} />
      <Slice shot="chat" r={CH.banner}>
        {bannerTitleHidden && (
          <div
            style={{
              position: 'absolute',
              left: CH.bannerTitle.x - 4,
              top: CH.bannerTitle.y - CH.banner.y - 4,
              width: CH.bannerTitle.w + 8,
              height: CH.bannerTitle.h + 8,
              background: '#F4F0E9',
            }}
          />
        )}
      </Slice>
      <Slice shot="chat" r={CH.composer} />
      <Veil
        rect={{ x: m5.x, y: m5.y + off, w: m5.w, h: m5.h }}
        amount={arrivedFocus}
        radius={44}
        max={0.7}
      />
      <StatusBar />
    </div>
  );
};

const Avatar: React.FC<{ f: number }> = ({ f }) => {
  const els: React.ReactNode[] = [];
  RUNS.forEach((run, ri) => {
    const start = ARRIVE[run[0]];
    if (f < start) return;
    // bottom of the latest bubble in this run
    let y = CH.msgs[run[0]].rect.y + CH.msgs[run[0]].rect.h;
    for (let k = 1; k < run.length; k++) {
      const p = ramp(f, ARRIVE[run[k]], ARRIVE[run[k]] + 14, E.move);
      const m = CH.msgs[run[k]].rect;
      y = mix(y, m.y + m.h, p);
    }
    const o = ramp(f, start + 2, start + 10, E.linear);
    els.push(
      <Slice key={ri} shot="chat" r={CH.avatar} x={CH.avatar.x} y={y - CH.avatar.h} radius={40} style={{ opacity: o }} />,
    );
  });
  return <>{els}</>;
};

/** "Emergency Dog Trainer": the Secure header -> the chat's pinned job banner. */
export const TitleToBannerFlyer: React.FC<{ f: number }> = ({ f }) => {
  const t = ramp(f, CUE.toChat, CUE.toChat + 30, E.inOut);
  if (f < CUE.toChat || f >= CUE.toChat + 30) return null;
  const a = S.headerTitle;
  const b = CH.bannerTitle;
  const sB = b.h / a.h;
  const k = mix(1, sB, t);
  const cross = ramp(t, 0.35, 0.65, E.linear);
  return (
    <div
      style={{
        position: 'absolute',
        left: mix(a.x, b.x, t),
        top: mix(a.y, b.y, t),
        transform: `scale(${k})`,
        transformOrigin: '0 0',
      }}
    >
      <Slice shot="secure" r={a} x={0} y={0} style={{ opacity: 1 - cross }} />
      <Slice
        shot="chat"
        r={b}
        x={0}
        y={0}
        style={{ opacity: cross, transform: `scale(${1 / sB})`, transformOrigin: '0 0' }}
      />
    </div>
  );
};
