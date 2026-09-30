import React from 'react';
import { Composition } from 'remotion';
import './lib/fonts';
import { Film } from './Film';
import { DURATION, FPS } from './config/timing';

export const Root: React.FC = () => (
  <>
    {/* Master: 16:9, 1080p. The captures are 1080 px wide, so 1080p keeps every close-up at native resolution. */}
    <Composition
      id="Help24Film"
      component={Film}
      durationInFrames={DURATION}
      fps={FPS}
      width={1920}
      height={1080}
      defaultProps={{ format: 'landscape' as const }}
    />
    {/* Social cut: 9:16. Same screens, cues and copy; its own camera, stacked trackers, copy band. */}
    <Composition
      id="Help24Film-Vertical"
      component={Film}
      durationInFrames={DURATION}
      fps={FPS}
      width={1080}
      height={1920}
      defaultProps={{ format: 'portrait' as const }}
    />
  </>
);
