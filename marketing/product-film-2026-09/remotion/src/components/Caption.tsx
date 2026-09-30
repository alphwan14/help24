import React from 'react';
import { E, ramp } from '../lib/anim';
import { COLOR, FONT, mixColor, TYPE } from '../config/theme';

/**
 * The film's one typographic gesture: each line rises 20px out of a slight
 * blur and settles (ease-out, 18 frames, 4-frame stagger); the block leaves
 * faster than it came (10 frames). Type is still while it is being read.
 */
const lineIn = (f: number, at: number) => {
  const p = ramp(f, at, at + 18, E.out);
  return {
    opacity: p,
    transform: `translateY(${(1 - p) * 20}px)`,
    filter: p < 0.999 ? `blur(${(1 - p) * 6}px)` : undefined,
  } as React.CSSProperties;
};

export const Caption: React.FC<{
  f: number;
  lines: string[];
  inAt: number;
  outAt: number;
  sub?: string;
  subAt?: number;
  x: number;
  y: number;
  night?: number;
  width?: number;
  align?: 'left' | 'center';
  size?: number;
  subSize?: number;
  subWidth?: number;
}> = ({ f, lines, inAt, outAt, sub, subAt, x, y, night = 0, width = 760, align = 'left', size, subSize, subWidth }) => {
  if (f < inAt - 1 || f > outAt + 12) return null;
  const out = ramp(f, outAt, outAt + 10, E.exit);
  const text = mixColor(COLOR.textOnPaper, COLOR.textOnNight, night);
  const subC = mixColor(COLOR.subOnPaper, COLOR.subOnNight, night);
  const H = TYPE.headline;
  const fs = size ?? H.size;
  return (
    <div
      style={{
        position: 'absolute',
        left: align === 'center' ? x - width / 2 : x,
        top: y,
        width,
        transform: `translateY(-50%) translateY(${-10 * out}px)`,
        opacity: 1 - out,
        fontFamily: FONT,
        textAlign: align,
      }}
    >
      {lines.map((line, i) => (
        <div
          key={i}
          style={{
            fontSize: fs,
            fontWeight: H.weight,
            letterSpacing: `${H.tracking}em`,
            lineHeight: H.leading,
            color: text,
            whiteSpace: 'nowrap',
            ...lineIn(f, inAt + i * 4),
          }}
        >
          {line}
        </div>
      ))}
      {sub && subAt !== undefined && (
        <div
          style={{
            marginTop: 24,
            fontSize: subSize ?? TYPE.sub.size,
            fontWeight: TYPE.sub.weight,
            letterSpacing: `${TYPE.sub.tracking}em`,
            lineHeight: TYPE.sub.leading,
            color: subC,
            maxWidth: subWidth ?? 620,
            textWrap: 'balance',
            ...lineIn(f, subAt),
          }}
        >
          {sub}
        </div>
      )}
    </div>
  );
};
