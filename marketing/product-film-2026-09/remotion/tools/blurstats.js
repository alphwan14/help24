/**
 * Reports the motion-blur sample count chosen for every frame, per format, so
 * the blur policy can be checked (and the render cost estimated) without rendering.
 *
 *   node tools/blurstats.js
 */
const path = require('path');
const esbuild = require('esbuild');

const out = path.join(__dirname, '.blurstats.cjs');
esbuild.buildSync({
  entryPoints: [path.join(__dirname, '..', 'src', 'scenes', 'choreography.ts')],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  jsx: 'automatic',
  outfile: out,
  logLevel: 'error',
});
const C = require(out);
const { DURATION } = { DURATION: 1815 };

for (const [format, W, H] of [['landscape', 1920, 1080], ['portrait', 1080, 1920]]) {
  const counts = {};
  let total = 0;
  const runs = [];
  let cur = null;
  for (let f = 0; f < DURATION; f++) {
    const n = C.blurSamplesAt(f, W, H, format);
    counts[n] = (counts[n] || 0) + 1;
    total += n;
    if (n > 1) {
      if (cur && cur.to === f - 1) {
        cur.to = f;
        cur.max = Math.max(cur.max, n);
      } else {
        cur = { from: f, to: f, max: n };
        runs.push(cur);
      }
    }
  }
  console.log(`\n${format}: ${total} sample-frames for ${DURATION} frames (${(total / DURATION).toFixed(2)}x)`);
  console.log('  histogram', counts);
  console.log('  blurred runs:', runs.map((r) => `${r.from}-${r.to}(max ${r.max})`).join('  '));
}
require('fs').unlinkSync(out);
