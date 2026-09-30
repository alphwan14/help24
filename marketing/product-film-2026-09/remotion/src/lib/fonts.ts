import { continueRender, delayRender, staticFile } from 'remotion';

/**
 * Inter, from the same files the app bundles (mobile-app/assets/fonts, OFL).
 * Rendering waits until every weight is loaded, so no frame is ever set in a fallback.
 */
const WEIGHTS: Array<[string, string]> = [
  ['Inter-Regular.ttf', '400'],
  ['Inter-Medium.ttf', '500'],
  ['Inter-SemiBold.ttf', '600'],
  ['Inter-Bold.ttf', '700'],
];

if (typeof document !== 'undefined') {
  const handle = delayRender('Loading Inter');
  Promise.all(
    WEIGHTS.map(([file, weight]) =>
      new FontFace('Inter', `url(${staticFile(`fonts/${file}`)}) format('truetype')`, { weight }).load(),
    ),
  )
    .then((faces) => {
      faces.forEach((face) => document.fonts.add(face));
      continueRender(handle);
    })
    .catch((err) => {
      console.error('Inter failed to load', err);
      continueRender(handle);
    });
}
