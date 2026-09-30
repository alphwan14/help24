import React from 'react';
import { AbsoluteFill, Freeze, useCurrentFrame } from 'remotion';

/**
 * Camera-style motion blur with a CENTRED shutter.
 *
 * @remotion/motion-blur's CameraMotionBlur samples ahead of the current frame
 * (f+0.5 .. f+1 at 180 degrees), so blurred frames would sit up to a frame
 * early relative to their unblurred neighbours - a visible hitch wherever blur
 * switches on or off. Here the samples straddle the frame (f-0.25 .. f+0.25 at
 * 180 degrees), so blurred and sharp frames line up exactly.
 *
 * Only the moving stage is wrapped, never the backdrop, so the 8-bit
 * accumulation of samples cannot shift the paper's tone between frames.
 */
export const MotionBlur: React.FC<{ samples: number; shutterAngle?: number; children: React.ReactNode }> = ({
  samples,
  shutterAngle = 180,
  children,
}) => {
  const f = useCurrentFrame();
  if (samples <= 1) return <>{children}</>;
  const shutter = shutterAngle / 360;
  return (
    <AbsoluteFill style={{ isolation: 'isolate' }}>
      {Array.from({ length: samples }).map((_, i) => {
        const offset = ((i + 0.5) / samples - 0.5) * shutter;
        return (
          <AbsoluteFill key={i} style={{ mixBlendMode: 'plus-lighter', filter: `opacity(${1 / samples})` }}>
            <Freeze frame={f + offset}>{children}</Freeze>
          </AbsoluteFill>
        );
      })}
    </AbsoluteFill>
  );
};
