import React from 'react';
import { clamp01, E, ramp } from '../lib/anim';
import { Rect } from '../config/screens';

/**
 * Touch feedback the way Android draws it: the control dips a little and an
 * ink ripple spreads from the touch point, then fades. No finger, no cursor -
 * the UI shows it was touched.
 *
 * Returns the scale to apply to the pressed element, plus the ripple layer.
 */
export const pressScale = (f: number, down: number, up: number, depth = 0.028) => {
  const dip = ramp(f, down - 2, down + 3, E.out);
  const rel = ramp(f, up, up + 8, E.out);
  return 1 - depth * dip * (1 - rel);
};

export const Ripple: React.FC<{
  f: number;
  down: number;
  rect: Rect;
  at: { x: number; y: number };
  radius: number;
  color?: string;
  strength?: number;
}> = ({ f, down, rect, at, radius, color = '255,255,255', strength = 0.22 }) => {
  if (f < down - 1 || f > down + 30) return null;
  const grow = ramp(f, down - 1, down + 14, E.out);
  const fade = 1 - ramp(f, down + 8, down + 30, E.move);
  const maxR = Math.hypot(Math.max(at.x - rect.x, rect.x + rect.w - at.x), Math.max(at.y - rect.y, rect.y + rect.h - at.y));
  const rr = 30 + (maxR - 30) * grow;
  return (
    <div
      style={{
        position: 'absolute',
        left: rect.x,
        top: rect.y,
        width: rect.w,
        height: rect.h,
        borderRadius: radius,
        overflow: 'hidden',
        pointerEvents: 'none',
      }}
    >
      <div
        style={{
          position: 'absolute',
          left: at.x - rect.x - rr,
          top: at.y - rect.y - rr,
          width: rr * 2,
          height: rr * 2,
          borderRadius: '50%',
          background: `rgba(${color},${strength * clamp01(fade)})`,
        }}
      />
    </div>
  );
};

/**
 * Focus: everything except `rect` recedes toward the page colour, so the one
 * element that matters is the only thing at full contrast. A hole cut with a
 * spread box-shadow keeps the focused card's own corners.
 */
export const Veil: React.FC<{ rect: Rect; amount: number; radius: number; color?: string; max?: number }> = ({
  rect,
  amount,
  radius,
  color = '250,249,247',
  max = 0.72,
}) =>
  amount <= 0.001 ? null : (
    <div
      style={{
        position: 'absolute',
        left: rect.x,
        top: rect.y,
        width: rect.w,
        height: rect.h,
        borderRadius: radius,
        boxShadow: `0 0 0 6000px rgba(${color},${max * amount})`,
        pointerEvents: 'none',
      }}
    />
  );
