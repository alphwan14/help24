/**
 * Writes ../CUE_SHEET.md from src/config/cues.ts: every cue with its frame,
 * time, and position on the music's grid, plus the comment written beside it.
 * The notes are generated from the code, so they cannot drift from the film.
 *
 *   node tools/cuesheet.js
 */
const fs = require('fs');
const path = require('path');
const esbuild = require('esbuild');

const SRC = path.join(__dirname, '..', 'src', 'config', 'cues.ts');
const tmp = path.join(__dirname, '.cues.cjs');
esbuild.buildSync({ entryPoints: [SRC], bundle: true, platform: 'node', format: 'cjs', outfile: tmp, logLevel: 'error' });
const { CUE } = require(tmp);
const T = require(tmp); // timing is bundled in too, but read the constants from source for clarity
fs.unlinkSync(tmp);

const FPS = 30;
const FIRST_BEAT_F = 15; // 0.5 s
const BEAT_F = 18; // 100 BPM at 30 fps
const PHASE = 3; // beat index (mod 4) carrying the downbeat

// comments beside each key, and the section headers they sit under
const src = fs.readFileSync(SRC, 'utf8').split('\n');
const notes = {};
const section = {};
let current = '';
for (const line of src) {
  const h = line.match(/\/\*\s*-+\s*(.+?)\s*-+\s*\*\//);
  if (h) current = h[1];
  const m = line.match(/^\s+(\w+):\s*[^,]+,\s*\/\/\s*(.*)$/);
  if (m) {
    notes[m[1]] = m[2].replace(/^\d+\s*/, '').trim();
    section[m[1]] = current;
  }
}

const grid = (f) => {
  const k = Math.round((f - FIRST_BEAT_F) / BEAT_F);
  const off = f - (FIRST_BEAT_F + k * BEAT_F);
  const barN = Math.floor((k + (4 - PHASE)) / 4);
  const beatInBar = (((k + (4 - PHASE)) % 4) + 4) % 4 + 1;
  return { bar: barN, beat: beatInBar, off };
};

const rows = Object.entries(CUE)
  .filter(([, v]) => typeof v === 'number')
  .sort((a, b) => a[1] - b[1]);

let out = `# Help24 product film: cue sheet

Generated from \`remotion/src/config/cues.ts\` by \`node tools/cuesheet.js\`. Do not edit by hand.

The music runs at 100 BPM, so at 30 fps one beat is 18 frames and one bar is 72. Beat 1 of bar *n* falls on frame 72*n* − 3.
Bars 7, 16 and 22 are the one-bar breaks, and bars 8, 17 and 23 are the returns.
Each grid position is the nearest beat, with an offset in frames: **−2f** means the event lands two frames before that beat.

| Frame | Time | Bar · beat | Cue | What happens |
|---:|---:|---|---|---|
`;
let lastSection = '';
for (const [key, f] of rows) {
  const g = grid(f);
  const sec = section[key] || '';
  if (sec && sec !== lastSection) {
    out += `| | | | **${sec}** | |\n`;
    lastSection = sec;
  }
  const pos = `${g.bar} · ${g.beat}${g.off ? ` (${g.off > 0 ? '+' : ''}${g.off}f)` : ''}`;
  out += `| ${f} | ${(f / FPS).toFixed(2)} s | ${pos} | \`${key}\` | ${notes[key] || ''} |\n`;
}
fs.writeFileSync(path.join(__dirname, '..', '..', 'CUE_SHEET.md'), out);
console.log(`wrote CUE_SHEET.md (${rows.length} cues)`);
void T;
