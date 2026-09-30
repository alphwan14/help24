/**
 * The film's clock.
 *
 * Everything is placed on the grid of the music, measured in ../../audio/
 * (analyze_audio.py + grid_fit.py): 100.00 BPM, beat k at 0.5 s + 0.6 s·k, and
 * bar downbeats on the beats where k ≡ 3 (mod 4). At 30 fps a beat is exactly
 * 18 frames and a bar is 72, so every cue below lands on a whole frame.
 *
 * Swapping the track: re-run the analysis, then change FIRST_BEAT_S / BPM /
 * DOWNBEAT_PHASE and the section constants. Every scene is written against
 * bar()/beat(), so it moves with them.
 */
export const FPS = 30;

export const BPM = 100;
export const BEAT_S = 60 / BPM;
export const FIRST_BEAT_S = 0.5;
/** beat index (mod 4) that carries the bar downbeat */
export const DOWNBEAT_PHASE = 3;

export const sec = (s: number) => Math.round(s * FPS);
export const beatS = (k: number) => FIRST_BEAT_S + k * BEAT_S;
/** frame of beat k */
export const beat = (k: number) => sec(beatS(k));
/** frame of the downbeat of bar n (bar 1 = 2.3 s; bar 0 starts just before the audio) */
export const bar = (n: number) => beat(4 * n - (4 - DOWNBEAT_PHASE));
/** frame of beat b (0-3) inside bar n */
export const barBeat = (n: number, b: number) => bar(n) + b * sec(BEAT_S);

/** The one-bar drop-outs, and the full-band returns that follow them. */
export const BREAK_1 = bar(7); //  16.7 s
export const DROP_1 = bar(8); //   19.1 s  (the main arrival)
export const BREAK_2 = bar(16); // 38.3 s
export const DROP_2 = bar(17); //  40.7 s
export const BREAK_3 = bar(22); // 52.7 s
export const DROP_3 = bar(23); //  55.1 s

/** The track is a trim: its last hit is on 59.3 s and it stops dead at 59.42 s. */
export const MUSIC_LAST_HIT = sec(59.3);
export const MUSIC_END = sec(59.42);

export const DURATION_S = 60.5;
export const DURATION = sec(DURATION_S);
