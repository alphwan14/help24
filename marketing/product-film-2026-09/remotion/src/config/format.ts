import React from 'react';

/**
 * One film, two frames. The screens, cues and copy are shared; the camera,
 * the stage layout of the lifted cards, and the type layout are per format.
 *
 *   landscape  1920x1080  master: web, deck, YouTube / Play Store promo
 *   portrait   1080x1920  social: Reels, Shorts, Status, TikTok
 */
export type Format = 'landscape' | 'portrait';

export const FORMAT_SIZE: Record<Format, { w: number; h: number }> = {
  landscape: { w: 1920, h: 1080 },
  portrait: { w: 1080, h: 1920 },
};

export const FormatContext = React.createContext<Format>('landscape');
export const useFormat = () => React.useContext(FormatContext);

/** Where captions sit, per format (screen pixels). */
export const CAPTION_LAYOUT: Record<
  Format,
  { x: number; y: number; yTop: number; width: number; size: number; subSize: number; subWidth: number }
> = {
  // left column beside the phone; the trackers line sits above the cards
  landscape: { x: 120, y: 540, yTop: 176, width: 760, size: 66, subSize: 36, subWidth: 620 },
  // one band across the top, on paper
  portrait: { x: 84, y: 272, yTop: 272, width: 912, size: 76, subSize: 40, subWidth: 860 },
};
