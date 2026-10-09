const fs = require('fs');
const path = require('path');

const BASE = path.resolve(__dirname, '..');
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

const LOCKUP = fs.readFileSync(APP + '/assets/brand/help24-lockup-on-dark.svg', 'utf8')
  .replace(/<metadata>[\s\S]*?<\/metadata>/, '')
  .replace(/ width="[\d.]+" height="[\d.]+"/, '');

const TILES = [
  ['01-discover.png', 'Marketplace'],
  ['02-post.png', 'Post a need'],
  ['03-secure-service.png', 'Payment protection'],
  ['04-job-status.png', 'Job progress'],
  ['05-messages.png', 'Messaging'],
  ['06-service-records.png', 'Service records'],
];

const TILE_W = 880, TILE_H = 1564, GAP = 56, MARGIN = 84, HEADER = 300;
const CAPTION = 48; // figcaption margin-top 22 + line box ~26
const W = TILE_W * 3 + GAP * 2 + MARGIN * 2;
const H = HEADER + (TILE_H + CAPTION) * 2 + GAP + MARGIN;

const tiles = TILES.map(([file, caption]) => {
  const src = 'data:image/png;base64,' + b64(path.join(BASE, 'final', file));
  return '<figure class="tile"><img src="' + src + '" alt="' + caption + '">' +
    '<figcaption>' + caption + '</figcaption></figure>';
}).join('\n');

const html = [
  '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Help24 store set</title>',
  '<style>',
  FONT_CSS,
  '*{margin:0;padding:0;box-sizing:border-box}',
  'html,body{width:' + W + 'px;height:' + H + 'px;overflow:hidden;background:#0E1114}',
  'body{font-family:Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased;position:relative}',
  '.glow{position:absolute;inset:0;background:radial-gradient(ellipse 70% 40% at 50% 46%,' +
    'rgba(232,163,61,.13) 0%,rgba(232,163,61,0) 72%)}',
  '.head{position:absolute;top:86px;left:' + MARGIN + 'px;right:' + MARGIN + 'px;' +
    'display:flex;align-items:flex-end;justify-content:space-between}',
  '.head svg{height:44px;width:auto;display:block}',
  '.meta{text-align:right}',
  '.meta .t{font-size:26px;font-weight:600;color:#F5F3EF;letter-spacing:-.01em}',
  '.meta .d{margin-top:7px;font-size:19px;font-weight:400;color:rgba(245,243,239,.45)}',
  '.grid{position:absolute;top:' + HEADER + 'px;left:' + MARGIN + 'px;right:' + MARGIN + 'px;' +
    'display:grid;grid-template-columns:repeat(3,' + TILE_W + 'px);gap:' + GAP + 'px}',
  '.tile img{display:block;width:' + TILE_W + 'px;height:auto;border-radius:22px;' +
    'box-shadow:0 30px 64px -18px rgba(0,0,0,.8),0 0 0 1px rgba(245,243,239,.08)}',
  '.tile figcaption{margin-top:22px;font-size:21px;font-weight:500;letter-spacing:.14em;' +
    'text-transform:uppercase;color:#E8A33D}',
  '</style></head><body>',
  '<div class="glow"></div>',
  '<div class="head">',
  '  <div>' + LOCKUP + '</div>',
  '  <div class="meta"><div class="t">Google Play screenshot set</div>' +
    '<div class="d">Six assets &middot; captured from the live Android build, 25 Sep 2026</div></div>',
  '</div>',
  '<div class="grid">' + tiles + '</div>',
  '</body></html>',
].join('\n');

fs.writeFileSync(path.join(BASE, '_build', 'html', 'contact-sheet.html'), html);
console.log('contact-sheet.html  ' + W + 'x' + H);
