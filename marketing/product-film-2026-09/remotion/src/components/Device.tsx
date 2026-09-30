import React from 'react';
import { APP_PAGE, SCREEN_H, SCREEN_W } from '../config/screens';

export const BEZEL = 24;
export const SCREEN_RADIUS = 104;

/**
 * A slim, unbranded device body around the real screen. Placed in stage space
 * (capture pixels); the screen's top-left is (x, y). `night` 0..1 retunes the
 * shadow for the dark trust scene, where a faint rim replaces the drop shadow.
 * `bodyOpacity` lets the body arrive after the screen has opened out of the chip.
 */
export const Device: React.FC<{
  x: number;
  y: number;
  scale?: number;
  opacity?: number;
  bodyOpacity?: number;
  night?: number;
  screenBg?: string;
  children: React.ReactNode;
}> = ({ x, y, scale = 1, opacity = 1, bodyOpacity = 1, night = 0, screenBg = APP_PAGE, children }) => {
  const shadowA = 0.34 * (1 - night);
  const shadowB = 0.2 * (1 - night);
  const rim = 0.05 + 0.1 * night;
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: SCREEN_W,
        height: SCREEN_H,
        transform: `scale(${scale})`,
        transformOrigin: `${SCREEN_W / 2}px ${SCREEN_H / 2}px`,
        opacity,
      }}
    >
      {bodyOpacity > 0.001 && (
        <div
          style={{
            position: 'absolute',
            left: -BEZEL,
            top: -BEZEL,
            width: SCREEN_W + BEZEL * 2,
            height: SCREEN_H + BEZEL * 2,
            borderRadius: SCREEN_RADIUS + BEZEL,
            opacity: bodyOpacity,
            background: 'linear-gradient(150deg, #30353B 0%, #0C0E10 14%, #0B0D0F 86%, #2A2F35 100%)',
            boxShadow: [
              `0 110px 190px -50px rgba(18,22,26,${shadowA})`,
              `0 40px 80px -24px rgba(18,22,26,${shadowB})`,
              `0 8px 18px rgba(18,22,26,${0.1 * (1 - night)})`,
              `0 0 0 2px rgba(245,243,239,${rim})`,
              `inset 0 0 0 2px rgba(255,255,255,0.07)`,
            ].join(','),
          }}
        />
      )}
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: SCREEN_W,
          height: SCREEN_H,
          borderRadius: SCREEN_RADIUS,
          overflow: 'hidden',
          background: screenBg,
          isolation: 'isolate',
        }}
      >
        {children}
      </div>
    </div>
  );
};
