import React from 'react';
import { AbsoluteFill, staticFile } from 'remotion';
import { COLOR } from '../config/theme';

/**
 * The room the product sits in. Warm paper by day; for the trust scene the
 * room darkens (`night` -> 1) and the lit screen becomes the only light, with
 * a faint warm pool behind it. No glows, shields or shapes - just light.
 * Grain lives on the backdrop only, so UI text is never dirtied.
 */
export const Background: React.FC<{ night: number; lightX?: number; lightY?: number }> = ({
  night,
  lightX = 0.64,
  lightY = 0.48,
}) => {
  const at = `${(lightX * 100).toFixed(2)}% ${(lightY * 100).toFixed(2)}%`;
  return (
    <AbsoluteFill>
      <AbsoluteFill
        style={{
          background: `radial-gradient(ellipse 78% 92% at ${at}, ${COLOR.paperLight} 0%, ${COLOR.paper} 52%, ${COLOR.paperEdge} 100%)`,
        }}
      />
      {night > 0.001 && (
        <AbsoluteFill
          style={{
            opacity: night,
            background: [
              `radial-gradient(ellipse 34% 44% at ${at}, rgba(232,163,61,0.075) 0%, rgba(232,163,61,0) 100%)`,
              `radial-gradient(ellipse 70% 85% at ${at}, ${COLOR.nightLight} 0%, ${COLOR.night} 58%, ${COLOR.nightEdge} 100%)`,
            ].join(','),
          }}
        />
      )}
      <AbsoluteFill
        style={{
          backgroundImage: `url(${staticFile('texture/grain.png')})`,
          backgroundSize: '256px 256px',
          mixBlendMode: 'overlay',
          opacity: 0.07 + 0.05 * night,
        }}
      />
    </AbsoluteFill>
  );
};
