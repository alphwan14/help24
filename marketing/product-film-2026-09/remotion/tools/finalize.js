/**
 * Finalizes a render for delivery, losslessly (stream copy, no re-encode):
 *
 *  1. Removes the AAC encoder's priming from the timeline. Remotion's AAC
 *     encoder puts 2048 samples of priming (42.7 ms at 48 kHz) at the start
 *     of the track but writes no edit list to skip them, so every player
 *     plays the music ~1.3 frames behind the picture. Shifting the audio
 *     back by exactly that much makes the muxer write the edit list, and
 *     the beats land on the frames they were choreographed to.
 *     (Measured with ../../audio/verify_sync.py: +42.3 ms before, ~0 ms after.)
 *  2. Moves the index to the front of the file (+faststart) so it starts
 *     playing on the web before it has fully downloaded.
 *
 *   node tools/finalize.js <in.mp4> <out.mp4>
 */
const { execFileSync } = require('child_process');
const path = require('path');

const FF = path.join(__dirname, '..', 'node_modules', '@remotion', 'compositor-win32-x64-msvc', 'ffmpeg.exe');
const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('usage: node tools/finalize.js <in.mp4> <out.mp4>');
  process.exit(1);
}
const PRIMING_SAMPLES = 2048;
const SAMPLE_RATE = 48000;
const shift = (PRIMING_SAMPLES / SAMPLE_RATE).toFixed(7);

execFileSync(
  FF,
  [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-i', input,
    '-itsoffset', `-${shift}`, '-i', input,
    '-map', '0:v:0', '-map', '1:a:0',
    '-c', 'copy',
    '-movflags', '+faststart',
    output,
  ],
  { stdio: 'inherit' },
);
console.log(`finalized ${path.basename(output)} (audio pulled forward ${(shift * 1000).toFixed(2)} ms, faststart)`);
