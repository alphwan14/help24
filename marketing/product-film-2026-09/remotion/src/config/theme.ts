/**
 * Colour and type, taken from the product rather than invented for the film.
 * Brand marks carry exactly three colours (mobile-app/lib/theme/tokens.dart):
 * ink #12161A, amber #E8A33D, paper #F5F3EF. The app page is #FAF9F7.
 */
export const COLOR = {
  /** the stage: a shade under the app's own page so the screen reads as an object */
  paper: '#EFEBE4',
  paperLight: '#F7F4EF',
  paperEdge: '#E2DCD1',
  /** the trust scene: the room darkens and the lit screen becomes the light */
  night: '#0E1114',
  nightLight: '#1A1917',
  nightEdge: '#07090B',

  ink: '#12161A',
  amber: '#E8A33D',
  brandPaper: '#F5F3EF',

  textOnPaper: '#12161A',
  subOnPaper: '#5A6067',
  textOnNight: '#F5F3EF',
  subOnNight: '#CBD0D5',
};

export const FONT = 'Inter, "Helvetica Neue", Arial, sans-serif';

export const TYPE = {
  headline: { size: 66, weight: 600, tracking: -0.028, leading: 1.06 },
  sub: { size: 36, weight: 400, tracking: -0.01, leading: 1.34 },
};

/** Mix two #RRGGBB colours. */
export const mixColor = (a: string, b: string, t: number) => {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  const c = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
};
