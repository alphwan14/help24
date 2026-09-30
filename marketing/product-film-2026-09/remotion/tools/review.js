/**
 * Review a render without a video player.
 *
 *   node tools/review.js <video.mp4> <outDir> [everyNFrames=15] [frames=comma,list]
 *
 * Writes contact sheets (6x5 tiles, one tile every N frames, labelled with the
 * frame number and time) and full-resolution PNGs of any listed frames.
 * Uses the ffmpeg that ships with Remotion's compositor.
 */
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const FF = path.join(__dirname, '..', 'node_modules', '@remotion', 'compositor-win32-x64-msvc', 'ffmpeg.exe');
const [video, outDir, nArg, framesArg] = process.argv.slice(2);
const N = Number(nArg || 15);
const FPS = 30;
// portrait videos get tall tiles, eight to a row
const probe = execFileSync(FF.replace('ffmpeg.exe', 'ffprobe.exe'), ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', video]).toString().trim().split(',').map(Number);
const PORTRAIT = probe[1] > probe[0];
const TW = PORTRAIT ? 270 : 480, TH = PORTRAIT ? 480 : 270, COLS = PORTRAIT ? 8 : 6;
fs.mkdirSync(outDir, { recursive: true });

// 1) contact sheets
const tilesDir = path.join(outDir, 'tiles');
fs.mkdirSync(tilesDir, { recursive: true });
for (const f of fs.readdirSync(tilesDir)) fs.unlinkSync(path.join(tilesDir, f));
// Remotion's ffmpeg is a minimal build (no select/fps filters): dump every frame
// small, then keep every Nth.
execFileSync(FF, [
  '-hide_banner', '-loglevel', 'error', '-y', '-i', video,
  '-vf', 'scale=' + TW + ':' + TH, '-start_number', '0',
  path.join(tilesDir, 't_%04d.png'),
]);
for (const f of fs.readdirSync(tilesDir)) {
  const n = Number(f.slice(2, 6));
  if (n % N !== 0) fs.unlinkSync(path.join(tilesDir, f));
}
const tiles = fs.readdirSync(tilesDir).filter((f) => f.endsWith('.png')).sort();
const perSheet = PORTRAIT ? 24 : 30;
const sheets = Math.ceil(tiles.length / perSheet);
for (let s = 0; s < sheets; s++) {
  const chunk = tiles.slice(s * perSheet, (s + 1) * perSheet);
  const cells = chunk
    .map((t, i) => {
      const idx = s * perSheet + i;
      const frame = idx * N;
      const src = encodeURI('file:///' + path.resolve(tilesDir, t).split(path.sep).join('/'));
      return `<figure><img src="${src}"><figcaption>f${frame} &nbsp; ${(frame / FPS).toFixed(2)}s</figcaption></figure>`;
    })
    .join('');
  const html = `<!doctype html><html><head><style>
    body{margin:0;background:#111;font:15px/1 Arial;color:#ddd;width:${COLS * (TW + 8) + 8}px}
    .g{display:grid;grid-template-columns:repeat(${COLS},${TW}px);gap:8px;padding:8px}
    figure{margin:0} img{display:block;width:${TW}px;height:${TH}px}
    figcaption{padding:4px 2px 6px}</style></head><body><div class="g">${cells}</div></body></html>`;
  const htmlPath = path.join(outDir, `sheet_${String(s + 1).padStart(2, '0')}.html`);
  fs.writeFileSync(htmlPath, html);
  const rows = Math.ceil(chunk.length / COLS);
  const chrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  execFileSync(chrome, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
    `--user-data-dir=${path.resolve(outDir, '.chrome')}`, `--window-size=${COLS * (TW + 8) + 8},${rows * (TH + 32) + 16}`,
    `--screenshot=${path.resolve(outDir, `sheet_${String(s + 1).padStart(2, '0')}.png`)}`,
    encodeURI('file:///' + path.resolve(htmlPath).split(path.sep).join('/')),
  ], { stdio: 'ignore' });
}
console.log(`${tiles.length} tiles -> ${sheets} sheets in ${outDir}`);

// 2) full-resolution frames
if (framesArg) {
  for (const fr of framesArg.split(',').map(Number)) {
    const t = (fr + 0.5) / FPS;
    execFileSync(FF, [
      '-hide_banner', '-loglevel', 'error', '-y', '-ss', t.toFixed(4), '-i', video,
      '-frames:v', '1', path.join(outDir, `f${String(fr).padStart(4, '0')}.png`),
    ]);
  }
  console.log('frames:', framesArg);
}
