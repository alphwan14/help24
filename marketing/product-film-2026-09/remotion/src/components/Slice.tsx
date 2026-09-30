import React from 'react';
import { Img, staticFile } from 'remotion';
import { Rect, SCREEN_H, SCREEN_W } from '../config/screens';

/**
 * A rectangle cut from a real capture, drawn at (x, y) in the current
 * coordinate space (capture pixels). Nothing is redrawn: the pixels are the app's.
 */
export const Slice: React.FC<{
  shot: string;
  r: Rect;
  x?: number;
  y?: number;
  radius?: number;
  style?: React.CSSProperties;
  children?: React.ReactNode;
}> = ({ shot, r, x = r.x, y = r.y, radius, style, children }) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      width: r.w,
      height: r.h,
      overflow: 'hidden',
      borderRadius: radius,
      ...style,
    }}
  >
    <Img
      src={staticFile(`screens/${shot}.png`)}
      style={{
        position: 'absolute',
        left: -r.x,
        top: -r.y,
        width: SCREEN_W,
        height: SCREEN_H,
        maxWidth: 'none',
      }}
    />
    {children}
  </div>
);

/** The whole capture. */
export const Shot: React.FC<{ shot: string; style?: React.CSSProperties }> = ({ shot, style }) => (
  <Img
    src={staticFile(`screens/${shot}.png`)}
    style={{ position: 'absolute', left: 0, top: 0, width: SCREEN_W, height: SCREEN_H, maxWidth: 'none', ...style }}
  />
);
