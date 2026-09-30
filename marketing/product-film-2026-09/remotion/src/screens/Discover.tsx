import React from 'react';
import { CUE } from '../config/cues';
import { APP_PAGE, DISCOVER as D, r } from '../config/screens';
import { E, mix, ramp, track } from '../lib/anim';
import { Slice } from '../components/Slice';
import { StatusBar } from '../components/StatusBar';
import { pressScale, Ripple } from '../components/Press';

/** Feed scroll, in content pixels: two real flicks, each decelerating the way a fling does. */
export const discoverScroll = (f: number) =>
  track(
    [
      { f: CUE.flick1, v: D.scrollMin },
      { f: CUE.flick1 + 34, v: 300, ease: E.out },
      { f: CUE.flick2, v: 300, ease: E.linear },
      { f: CUE.flick2 + 38, v: 612, ease: E.out },
    ],
    f,
  );

/** 0 -> 1: the app blooming out of the All chip. */
export const discoverOpen = (f: number) => ramp(f, CUE.open + 6, CUE.opened, E.inOut);

const CHIP_C = { x: D.allChip.x + D.allChip.w / 2, y: D.allChip.y + D.allChip.h / 2 };
/** far enough from the chip to cover the whole screen */
const BLOOM_R = Math.hypot(1080 - CHIP_C.x, 2400 - CHIP_C.y) + 40;

export const DiscoverScreen: React.FC<{ f: number }> = ({ f }) => {
  const s = discoverScroll(f);
  const open = discoverOpen(f);
  const chip = D.allChip;
  const clip = open < 1 ? `circle(${mix(0, BLOOM_R, open)}px at ${CHIP_C.x}px ${CHIP_C.y}px)` : undefined;
  const fabScale = pressScale(f, CUE.fabDown, CUE.fabUp, 0.04);

  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE, clipPath: clip }}>
      <Slice shot="discover" r={D.top} />
      {/* until the crossbar has landed, it stands in for the chip (see OpeningMark) */}
      {f < CUE.open + 16 && (
        <div
          style={{
            position: 'absolute',
            left: chip.x - 3,
            top: chip.y - 3,
            width: chip.w + 6,
            height: chip.h + 6,
            background: APP_PAGE,
          }}
        />
      )}
      <div
        style={{
          position: 'absolute',
          left: D.viewport.x,
          top: D.viewport.y,
          width: D.viewport.w,
          height: D.viewport.h,
          overflow: 'hidden',
        }}
      >
        {D.feed.map((p) => (
          <Slice key={p.shot + p.srcY} shot={p.shot} r={r(0, p.srcY, 1080, p.h)} x={0} y={p.contentY - s - D.viewport.y} />
        ))}
      </div>
      <Slice shot="discover" r={D.nav} />
      <Slice
        shot="discover-scroll1"
        r={D.fab}
        radius={D.fabRadius}
        style={{ transform: `scale(${fabScale})`, transformOrigin: '50% 50%' }}
      />
      <Ripple
        f={f}
        down={CUE.fabDown}
        rect={D.fab}
        at={{ x: D.fab.x + 150, y: D.fab.y + 84 }}
        radius={D.fabRadius}
        color="255,255,255"
        strength={0.2}
      />
      <StatusBar />
    </div>
  );
};
