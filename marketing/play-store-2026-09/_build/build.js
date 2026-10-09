const fs = require('fs');
const path = require('path');

const BASE = path.resolve(__dirname, '..');
const RAW = path.join(BASE, 'raw-captures');
const APP = 'C:/Users/840 g8/Desktop/Projects/help24/mobile-app';
const FONTS = APP + '/assets/fonts';

const b64 = (p) => fs.readFileSync(p).toString('base64');

const fontFace = (file, weight) =>
  '@font-face{font-family:Inter;font-style:normal;font-weight:' + weight + ';' +
  "src:url(data:font/ttf;base64," + b64(path.join(FONTS, file)) + ") format('truetype');}";

const FONT_CSS = [
  fontFace('Inter-Regular.ttf', 400),
  fontFace('Inter-Medium.ttf', 500),
  fontFace('Inter-SemiBold.ttf', 600),
  fontFace('Inter-Bold.ttf', 700),
].join('\n');

// The real Help24 lockup, verbatim from assets/brand (C2PA metadata stripped only).
const LOCKUP = fs.readFileSync(APP + '/assets/brand/help24-lockup-on-dark.svg', 'utf8')
  .replace(/<metadata>[\s\S]*?<\/metadata>/, '')
  .replace(/ width="[\d.]+" height="[\d.]+"/, '');

// Brand tokens, read off mobile-app/lib/theme/tokens.dart
const INK = '#0E1114';      // dark page
const INK_CARD = '#12161A'; // brand ink
const PAPER = '#F5F3EF';    // the lockup's own off-white
const AMBER = '#E8A33D';    // the brand crossbar

// Source capture geometry: Galaxy S20+, 1080x2400, display cutout inset top = 73px
const SRC_W = 1080, SRC_H = 2400;
const STATUS_H = 84;    // clean band drawn over OS chrome only, never over app UI
const SAMPLE_ROW = 80;  // capture row stretched to colour-match each screen background

const SCREEN_W = 624, SCREEN_H = 1386;  // 624/1386 = 0.45 = 1080/2400
const SCALE = SCREEN_W / SRC_W;
const DEVICE_TOP = 470;

const ASSETS = [
  {
    file: '01-discover.png', label: '01 &middot; Marketplace',
    h: 'One feed for every kind of help',
    s: 'Requests, offers and jobs &mdash; from fundis to tutors &mdash; posted by people nearby.',
  },
  {
    file: '02-post.png', label: '02 &middot; Post a need',
    h: 'Ask for it, or offer it',
    s: 'Request a service, list a skill you have, or hire for a job.',
  },
  {
    file: '03-secure-service.png', label: '03 &middot; Payment protection',
    h: 'Payment held until the work is done',
    s: 'Service cost, platform fee and total &mdash; all shown before you pay.',
  },
  {
    file: '04-job-status.png', label: '04 &middot; Job progress',
    h: 'Know exactly where a job stands',
    s: 'Payment and completion tracked step by step, for both sides.',
  },
  {
    file: '05-messages.png', label: '05 &middot; Messaging',
    h: 'Every conversation stays with its job',
    s: 'Agree the details in one thread &mdash; and see when they arrive.',
  },
  {
    file: '06-service-records.png', label: '06 &middot; Service records',
    h: 'A record of every job you finish',
    s: 'Completed work, payment status and a receipt for each one.',
  },
];

const STATUS_BAR = [
  '<div class="statusfill"></div>',
  '<div class="statusbar">',
  '  <span class="clock">10:30</span>',
  '  <span class="sysicons">',
  '    <svg width="42" height="42" viewBox="0 0 24 24" fill="none">',
  '      <path d="M12 18.6a1.45 1.45 0 100-2.9 1.45 1.45 0 000 2.9z" fill="currentColor"/>',
  '      <path d="M8.2 14.2a5.6 5.6 0 017.6 0M4.9 10.8a10.3 10.3 0 0114.2 0M1.9 7.5a14.8 14.8 0 0120.2 0"',
  '            stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/>',
  '    </svg>',
  '    <svg width="40" height="40" viewBox="0 0 24 24" fill="currentColor">',
  '      <rect x="2" y="15" width="3.2" height="5" rx="1"/>',
  '      <rect x="7" y="12" width="3.2" height="8" rx="1"/>',
  '      <rect x="12" y="8.5" width="3.2" height="11.5" rx="1"/>',
  '      <rect x="17" y="5" width="3.2" height="15" rx="1"/>',
  '    </svg>',
  '    <svg width="46" height="46" viewBox="0 0 28 24" fill="none">',
  '      <rect x="1.9" y="7.2" width="21" height="10.6" rx="3.1" stroke="currentColor" stroke-width="1.7"/>',
  '      <rect x="4.2" y="9.5" width="14.2" height="6" rx="1.7" fill="currentColor"/>',
  '      <path d="M24.9 10.9v3.2" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
  '    </svg>',
  '  </span>',
  '</div>',
].join('\n');

function page(a) {
  const shot = 'data:image/png;base64,' + b64(path.join(RAW, a.file));
  return [
    '<!doctype html>',
    '<html lang="en"><head><meta charset="utf-8"><title>' + a.label + '</title>',
    '<style>',
    FONT_CSS,
    '*{margin:0;padding:0;box-sizing:border-box}',
    'html,body{width:1080px;height:1920px;overflow:hidden;background:' + INK + '}',
    'body{font-family:Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased;position:relative}',
    // one warm light source behind the device, one cool lift under the headline.
    // These two are the only gradients in the system.
    '.glow{position:absolute;inset:0;background:' +
      'radial-gradient(ellipse 66% 34% at 50% 52%,rgba(232,163,61,.30) 0%,' +
        'rgba(232,163,61,.10) 44%,rgba(232,163,61,0) 74%),' +
      'radial-gradient(ellipse 80% 30% at 22% 6%,rgba(245,243,239,.075) 0%,' +
        'rgba(245,243,239,0) 70%)}',
    '.vignette{position:absolute;inset:0;background:radial-gradient(ellipse 112% 72% at 50% 46%,' +
      'rgba(0,0,0,0) 40%,rgba(0,0,0,.30) 76%,rgba(0,0,0,.58) 100%)}',
    '.copy{position:absolute;top:76px;left:72px;right:72px}',
    '.lockup svg{height:36px;width:auto;display:block}',
    '.eyebrow{margin-top:58px;font-size:18px;font-weight:600;letter-spacing:.2em;' +
      'text-transform:uppercase;color:' + AMBER + '}',
    'h1{margin-top:20px;font-size:58px;line-height:1.08;letter-spacing:-.022em;' +
      'font-weight:700;color:' + PAPER + ';max-width:900px;text-wrap:balance}',
    '.sub{margin-top:20px;font-size:25px;line-height:1.46;font-weight:400;' +
      'color:rgba(245,243,239,.58);max-width:812px;text-wrap:balance}',
    '.device{position:absolute;left:50%;transform:translateX(-50%);top:' + DEVICE_TOP + 'px;' +
      'width:' + (SCREEN_W + 18) + 'px;height:' + (SCREEN_H + 18) + 'px;border-radius:49px;' +
      'background:linear-gradient(160deg,#252A30 0%,#0A0C0E 34%,#0A0C0E 70%,#1E2328 100%);' +
      'padding:9px;box-shadow:0 74px 132px -34px rgba(0,0,0,.88),0 20px 54px rgba(0,0,0,.5),' +
      '0 0 0 1px rgba(245,243,239,.11),inset 0 0 0 1px rgba(245,243,239,.06)}',
    '.screen{position:relative;width:' + SCREEN_W + 'px;height:' + SCREEN_H + 'px;' +
      'border-radius:40px;overflow:hidden;background:#FAF9F7}',
    // authored in source pixels, scaled once - keeps the overlay maths exact
    '.inner{position:absolute;top:0;left:0;width:' + SRC_W + 'px;height:' + SRC_H + 'px;' +
      'transform:scale(' + SCALE + ');transform-origin:0 0}',
    '.shot{position:absolute;inset:0;width:' + SRC_W + 'px;height:' + SRC_H + 'px;display:block}',
    // OS chrome only: the band is colour-matched by stretching row SAMPLE_ROW of the
    // capture itself, so it is the screen's own real background, never a guessed hex.
    '.statusfill{position:absolute;top:0;left:0;width:' + SRC_W + 'px;height:' + STATUS_H + 'px;' +
      'background-image:url(' + shot + ');background-size:100% ' + (SRC_H * 80) + 'px;' +
      'background-position:0 -' + (SAMPLE_ROW * 80) + 'px}',
    '.statusbar{position:absolute;top:0;left:0;width:' + SRC_W + 'px;height:' + STATUS_H + 'px;' +
      'display:flex;align-items:center;justify-content:space-between;padding:0 46px;' +
      'color:' + INK_CARD + '}',
    '.clock{font-size:38px;font-weight:500;letter-spacing:.01em}',
    '.sysicons{display:flex;align-items:center;gap:11px}',
    '.sysicons svg{display:block}',
    '</style></head>',
    '<body>',
    '<div class="glow"></div><div class="vignette"></div>',
    '<div class="copy">',
    '  <div class="lockup">' + LOCKUP + '</div>',
    '  <div class="eyebrow">' + a.label + '</div>',
    '  <h1>' + a.h + '</h1>',
    '  <p class="sub">' + a.s + '</p>',
    '</div>',
    '<div class="device"><div class="screen"><div class="inner">',
    '  <img class="shot" src="' + shot + '" alt="">',
    STATUS_BAR,
    '</div></div></div>',
    '</body></html>',
  ].join('\n');
}

const outDir = path.join(BASE, '_build', 'html');
fs.mkdirSync(outDir, { recursive: true });
ASSETS.forEach((a) => {
  const name = a.file.replace('.png', '.html');
  fs.writeFileSync(path.join(outDir, name), page(a));
  console.log('wrote', name);
});
