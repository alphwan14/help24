import React from 'react';
import { CUE } from '../config/cues';
import { HISTORY } from '../config/screens';
import { COLOR, mixColor } from '../config/theme';
import { DISCOVER } from '../config/screens';
import { clamp01, E, mix, ramp } from '../lib/anim';
import { Slice } from './Slice';
import { LOCKUP_VIEWBOX, WORDMARK_D } from '../brand/wordmark';
import { MARK_OPEN, markEndOf, stageOf } from '../scenes/choreography';
import { useFormat } from '../config/format';

/**
 * The Help24 mark, from mobile-app/assets/brand/help24-mark.svg (viewBox 60x56):
 * two ink bars (11x56, r5.5) at x=0 and x=49, and the amber crossbar (22x12, r6)
 * at (19, 22). Drawn from live rectangles so each part can move on the music.
 */
const markRects = (cx: number, cy: number, u: number) => ({
  left: { x: cx - 30 * u, y: cy - 28 * u, w: 11 * u, h: 56 * u },
  right: { x: cx + 19 * u, y: cy - 28 * u, w: 11 * u, h: 56 * u },
  cross: { x: cx - 11 * u, y: cy - 6 * u, w: 22 * u, h: 12 * u },
});

const box = (
  rect: { x: number; y: number; w: number; h: number },
  style: React.CSSProperties,
): React.CSSProperties => ({
  position: 'absolute',
  left: rect.x,
  top: rect.y,
  width: rect.w,
  height: rect.h,
  ...style,
});

/* ------------------------------------------------------------------ opening */

/**
 * The device's side rails, in stage px: where the mark's two bars end up. They
 * cover only the straight run of the bezel, so their ends never poke past the
 * body's rounded corners when the body fades in around them.
 */
const RAIL_W = 44;
const railLeft = { x: -24, y: 70, w: RAIL_W, h: 2260 };
const railRight = { x: 1080 + 24 - RAIL_W, y: 70, w: RAIL_W, h: 2260 };

/** 0 -> 1 across the opening: the mark unfolding into the phone. */
export const unfold = (f: number) => ramp(f, CUE.open, CUE.opened, E.inOut);

/**
 * Bars rise on beats 0 and 1 (the first one from frame 0, so the film moves
 * immediately), the crossbar joins on beat 2. Then the mark unfolds: the two
 * ink bars travel out and stretch into the phone's two edges, while the
 * crossbar - the exact size and colour of Discover's selected "All" chip -
 * settles into that chip, and the app blooms out from it.
 */
export const OpeningMark: React.FC<{ f: number }> = ({ f }) => {
  if (f > CUE.opened + 8) return null;
  const u = MARK_OPEN.unit;
  const m = markRects(MARK_OPEN.cx, MARK_OPEN.cy, u);
  const gl = ramp(f, 0, CUE.barLeft + 2, E.out);
  const gr = ramp(f, CUE.barRight - 13, CUE.barRight + 2, E.out);
  const gc = ramp(f, CUE.crossbar - 13, CUE.crossbar + 2, E.out);
  const t = unfold(f);
  const lerp = (a: typeof railLeft, b: typeof railLeft, k: number) => ({
    x: mix(a.x, b.x, k),
    y: mix(a.y, b.y, k),
    w: mix(a.w, b.w, k),
    h: mix(a.h, b.h, k),
  });
  const left = lerp(m.left, railLeft, t);
  const right = lerp(m.right, railRight, t);
  // the chip lands early in the unfold, then hands over to the real one
  const toChip = ramp(f, CUE.open, CUE.open + 18, E.move);
  const chip = DISCOVER.allChip;
  const cross = {
    x: mix(m.cross.x, chip.x, toChip),
    y: mix(m.cross.y, chip.y, toChip),
    w: mix(m.cross.w, chip.w, toChip),
    h: mix(m.cross.h, chip.h, toChip),
  };
  const crossFade = 1 - ramp(f, CUE.open + 16, CUE.open + 24, E.linear);
  // rails hand over to the device body as it arrives
  const railFade = 1 - ramp(f, CUE.opened, CUE.opened + 8, E.linear);
  const bar = (g: number, r: typeof left): React.CSSProperties => ({
    background: COLOR.ink,
    borderRadius: Math.min(r.w / 2, 5.5 * u),
    transform: `scaleY(${0.001 + 0.999 * g})`,
    transformOrigin: '50% 50%',
    opacity: clamp01(g * 3) * railFade,
  });
  return (
    <>
      <div style={box(left, bar(gl, left))} />
      <div style={box(right, bar(gr, right))} />
      {crossFade > 0 && (
        <div
          style={box(cross, {
            background: COLOR.amber,
            borderRadius: cross.h / 2,
            transform: `scale(${0.001 + 0.999 * gc}, ${0.35 + 0.65 * gc})`,
            transformOrigin: '50% 50%',
            opacity: clamp01(gc * 3) * crossFade,
          })}
        />
      )}
    </>
  );
};

/* ------------------------------------------------------------------ closing */

/**
 * The last UI element on screen, a real "Payment protected" chip, lifts off
 * the phone. Its words go, it turns brand amber and becomes the crossbar; the
 * two bars close in and meet it on the downbeat. Then the mark takes on its
 * app-icon tile, slides left, and the wordmark unrolls: the official lockup
 * (help24-lockup.svg), assembled rather than cut to.
 */
export const EndMark: React.FC<{ f: number }> = ({ f }) => {
  const format = useFormat();
  if (f < CUE.chipLift - 1) return null;
  const MARK_END = markEndOf(format);
  const STAGE = stageOf(format);
  const u = MARK_END.unit;
  const cx = MARK_END.cx;
  const cy = MARK_END.cy;
  const m = markRects(cx, cy, u);
  const chipR = HISTORY.protectedChip;
  const chipAt = { x: STAGE.devB.x + chipR.x, y: STAGE.devB.y + chipR.y, w: chipR.w, h: chipR.h };

  const lift = ramp(f, CUE.chipLift, CUE.chipLift + 18, E.out);
  const morph = ramp(f, CUE.chipMorph, CUE.chipMorph + 30, E.inOut);
  const words = 1 - ramp(f, CUE.chipMorph, CUE.chipMorph + 10, E.linear);
  const amber = ramp(f, CUE.chipMorph + 2, CUE.chipMorph + 22, E.move);

  // bars: accelerate in, meet on the downbeat
  const snap = (t: number) => t * t * (1.4 - 0.4 * t);
  const bars = snap(ramp(f, CUE.barsIn, CUE.markComplete - 1, E.linear));
  const barIn = ramp(f, CUE.barsIn, CUE.barsIn + 8, E.linear);

  // tile + lockup
  const L = (56 * u) / 35.84; // lockup units -> stage px (the tile's mark is 35.84 units tall)
  const tileSize = 64 * L;
  const tileT = ramp(f, CUE.tile, CUE.tile + 22, E.out);
  const slide = ramp(f, CUE.lockup, CUE.lockup + 34, E.inOut);
  const lockW = LOCKUP_VIEWBOX.w * L;
  const lockLeft = cx - lockW / 2;
  const tileCx = mix(cx, lockLeft + tileSize / 2, slide);
  const dx = tileCx - cx;
  const reveal = ramp(f, CUE.lockup + 8, CUE.lockup + 40, E.move);
  const barColor = mixColor(COLOR.ink, COLOR.brandPaper, ramp(f, CUE.tile + 2, CUE.tile + 14, E.linear));
  // inside the tile the mark sits at 12.8/14.08 of 64 - identical to the centred mark
  const cross = {
    x: mix(chipAt.x, m.cross.x, morph) + dx,
    y: mix(chipAt.y, m.cross.y, morph),
    w: mix(chipAt.w, m.cross.w, morph),
    h: mix(chipAt.h, m.cross.h, morph),
  };
  const lifted = f < CUE.chipMorph + 10;
  const chipShadow = lift * (1 - morph);

  return (
    <>
      {/* the tile, growing from behind the mark */}
      {tileT > 0 && (
        <div
          style={{
            position: 'absolute',
            left: tileCx - tileSize / 2,
            top: cy - tileSize / 2,
            width: tileSize,
            height: tileSize,
            borderRadius: 14.08 * L,
            background: COLOR.ink,
            transform: `scale(${0.56 + 0.44 * tileT})`,
            transformOrigin: '50% 50%',
            opacity: clamp01(tileT * 2.2),
          }}
        />
      )}
      {/* amber pill: the chip, becoming the crossbar */}
      <div
        style={box(cross, {
          background: mixColor('#F2ECE1', COLOR.amber, amber),
          borderRadius: cross.h / 2,
          transform: `scale(${1 + 0.07 * lift * (1 - morph)})`,
          boxShadow: `0 ${18 * chipShadow}px ${44 * chipShadow}px rgba(18,22,26,${0.2 * chipShadow})`,
        })}
      />
      {lifted && (
        <Slice
          shot="history-work"
          r={chipR}
          x={chipAt.x}
          y={chipAt.y}
          radius={chipR.h / 2}
          style={{
            opacity: words,
            transform: `scale(${1 + 0.07 * lift})`,
          }}
        />
      )}
      {/* the two sides */}
      {f >= CUE.barsIn && (
        <>
          <div
            style={box(
              { ...m.left, x: m.left.x - 520 * (1 - bars) + dx },
              { background: barColor, borderRadius: 5.5 * u, opacity: barIn },
            )}
          />
          <div
            style={box(
              { ...m.right, x: m.right.x + 520 * (1 - bars) + dx },
              { background: barColor, borderRadius: 5.5 * u, opacity: barIn },
            )}
          />
        </>
      )}
      {/* the wordmark, verbatim from the lockup file */}
      {reveal > 0 && (
        <svg
          viewBox={`0 0 ${LOCKUP_VIEWBOX.w} ${LOCKUP_VIEWBOX.h}`}
          style={{
            position: 'absolute',
            left: lockLeft,
            top: cy - tileSize / 2,
            width: lockW,
            height: tileSize,
            overflow: 'visible',
            clipPath: `inset(0 ${(1 - reveal) * 100}% 0 ${(78 / LOCKUP_VIEWBOX.w) * 100}%)`,
            transform: `translateX(${(1 - reveal) * -40}px)`,
          }}
        >
          <path d={WORDMARK_D} fill={COLOR.ink} />
        </svg>
      )}
    </>
  );
};
