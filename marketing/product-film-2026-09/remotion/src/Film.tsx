import React from 'react';
import { AbsoluteFill, Audio, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { CUE } from './config/cues';
import { COPY } from './config/copy';
import { COLOR, FONT, mixColor } from './config/theme';
import { DURATION } from './config/timing';
import { E, ramp } from './lib/anim';
import { Background } from './components/Background';
import { Caption } from './components/Caption';
import { Device } from './components/Device';
import { EndMark, OpeningMark } from './components/Brand';
import { blurSamplesAt, cameraAt, captionBandAt, DEVICE_SWAP, deviceAt, markEndOf, nightAt } from './scenes/choreography';
import { CAPTION_LAYOUT, Format, FormatContext, useFormat } from './config/format';
import { MotionBlur } from './components/MotionBlur';
import { DiscoverScreen } from './screens/Discover';
import {
  CardToDetail,
  ComposerScreen,
  ComposerToMyPostsFlyer,
  DetailScreen,
  MyPostsScreen,
  TitleToDetailFlyer,
} from './screens/Request';
import { AmountFlyer, detailExit, SecureScreen } from './screens/Secure';
import { ChatScreen, TitleToBannerFlyer } from './screens/Chat';
import { Trackers } from './screens/Trackers';
import { HistoryScreen } from './screens/History';

/** What the phone shows at frame f: screens plus the elements carried between them. */
const DeviceContent: React.FC<{ f: number }> = ({ f }) => {
  if (f >= DEVICE_SWAP) return <HistoryScreen f={f} />;
  return (
    <>
      {f >= CUE.open && f < CUE.composerIn + 24 && <DiscoverScreen f={f} />}
      {f >= CUE.composerIn - 1 && f < CUE.toMyPosts + 16 && <ComposerScreen f={f} />}
      {f >= CUE.toMyPosts && f < CUE.toDetail + 32 && <MyPostsScreen f={f} />}
      {f >= CUE.toDetail && f < CUE.toSecure + 28 && (
        <div style={{ position: 'absolute', inset: 0, ...detailExit(f) }}>
          <CardToDetail f={f}>
            <DetailScreen f={f} />
          </CardToDetail>
        </div>
      )}
      {f >= CUE.toSecure && f < CUE.toChat + 28 && <SecureScreen f={f} />}
      {f >= CUE.toChat && <ChatScreen f={f} />}
      <ComposerToMyPostsFlyer f={f} />
      <TitleToDetailFlyer f={f} />
      <AmountFlyer f={f} />
      <TitleToBannerFlyer f={f} />
    </>
  );
};

/** Under the lockup, at a fixed ratio to it, so it follows the end card in every format. */
const Tagline: React.FC<{ f: number; format: Format; top: number }> = ({ f, format, top }) => {
  if (f < CUE.tagline1 - 2) return null;
  const part = (at: number): React.CSSProperties => {
    const p = ramp(f, at, at + 18, E.out);
    return {
      display: 'inline-block',
      opacity: p,
      transform: 'translateY(' + (1 - p) * 16 + 'px)',
      filter: p < 0.999 ? 'blur(' + (1 - p) * 5 + 'px)' : undefined,
    };
  };
  const portrait = format === 'portrait';
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        width: '100%',
        top,
        textAlign: 'center',
        fontFamily: FONT,
        fontSize: portrait ? 54 : 46, // keep in step with taglineSize in Film
        fontWeight: 500,
        letterSpacing: '-0.014em',
        color: mixColor(COLOR.ink, '#FFFFFF', 0.06),
      }}
    >
      <span style={part(CUE.tagline1)}>{COPY.tagline[0]}</span>
      <span style={{ display: 'inline-block', width: '0.42em' }} />
      <span style={part(CUE.tagline2)}>{COPY.tagline[1]}</span>
    </div>
  );
};

/**
 * Portrait only: a band of paper across the top that holds the copy, so type
 * always sits on paper and never over UI; the UI slides under its soft edge.
 */
const CopyBand: React.FC<{ f: number; night: number }> = ({ f, night }) => {
  const a = captionBandAt(f);
  if (a <= 0.001) return null;
  const c = mixColor(COLOR.paper, COLOR.night, night);
  return (
    <AbsoluteFill style={{ opacity: a, pointerEvents: 'none' }}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: '100%',
          height: 700,
          background: c,
          maskImage: 'linear-gradient(180deg, #000 0%, #000 56%, transparent 100%)',
          WebkitMaskImage: 'linear-gradient(180deg, #000 0%, #000 56%, transparent 100%)',
        }}
      />
    </AbsoluteFill>
  );
};

/** Everything that lives on the stage and moves with the camera. Reads its own frame so MotionBlur can resample it. */
const Stage: React.FC = () => {
  const f = useCurrentFrame();
  const format = useFormat();
  const { width: W, height: H } = useVideoConfig();
  const cam = cameraAt(f, format);
  const s = H / cam.span;
  const tx = W * (0.5 + cam.ox) - cam.cx * s;
  const ty = H * (0.5 + cam.oy) - cam.cy * s;
  const night = nightAt(f);
  const dev = deviceAt(f, format);
  // the device: its edges arrive as the mark's two bars, its body completes as the screen blooms;
  // at the end it steps back and fades while its last chip lifts off
  const bodyIn = ramp(f, CUE.opened - 10, CUE.opened + 4, E.move);
  const endFade = f >= DEVICE_SWAP ? 1 - ramp(f, CUE.chipLift + 8, CUE.chipLift + 44, E.move) : 1;
  const endScale = f >= DEVICE_SWAP ? 1 - 0.035 * ramp(f, CUE.chipLift, CUE.chipLift + 50, E.move) : 1;
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        transformOrigin: '0 0',
        transform: 'translate(' + tx + 'px, ' + ty + 'px) scale(' + s + ')',
      }}
    >
      {f >= CUE.open && endFade > 0.001 && (
        <Device
          x={dev.x}
          y={dev.y}
          night={night}
          bodyOpacity={bodyIn}
          opacity={endFade}
          scale={endScale}
          screenBg={f < CUE.opened ? 'transparent' : undefined}
        >
          <DeviceContent f={f} />
        </Device>
      )}
      <OpeningMark f={f} />
      <Trackers f={f} />
      <EndMark f={f} />
    </div>
  );
};

export const Film: React.FC<{ format?: Format }> = ({ format = 'landscape' }) => {
  const f = useCurrentFrame();
  const { width: W, height: H } = useVideoConfig();
  const cam = cameraAt(f, format);
  const night = nightAt(f);
  const L = CAPTION_LAYOUT[format];
  const portrait = format === 'portrait';
  const cap = { x: L.x, width: L.width, size: L.size, subSize: L.subSize, subWidth: L.subWidth };
  // the tagline hangs under the app-icon tile of the end lockup
  const end = markEndOf(format);
  const lockupUnit = (56 * end.unit) / 35.84;
  const camScale = H / cam.span;
  const markY = H * (0.5 + cam.oy) + (end.cy - cam.cy) * camScale;
  const taglineSize = portrait ? 54 : 46;
  const taglineTop = markY + 32 * lockupUnit * camScale + 1.77 * taglineSize;
  return (
    <FormatContext.Provider value={format}>
      <AbsoluteFill style={{ backgroundColor: COLOR.paper }}>
        <Background night={night} lightX={portrait ? 0.5 : 0.5 + cam.ox * 0.9} lightY={portrait ? 0.5 : 0.48} />
        <MotionBlur samples={blurSamplesAt(f, W, H, format)}>
          <Stage />
        </MotionBlur>
        {portrait && <CopyBand f={f} night={night} />}

        <Caption f={f} lines={COPY.discover} inAt={CUE.capDiscover} outAt={CUE.fabDown - 6} y={L.y} {...cap} />
        <Caption f={f} lines={COPY.ask} inAt={CUE.capAsk} outAt={CUE.toMyPosts + 18} y={L.y} {...cap} />
        <Caption
          f={f}
          lines={COPY.secure}
          sub={COPY.secureSub}
          subAt={CUE.capSecureSub}
          inAt={CUE.capSecure}
          outAt={CUE.capSecureOut}
          y={portrait ? L.y + 20 : L.y}
          night={night}
          {...cap}
        />
        <Caption f={f} lines={COPY.chat} inAt={CUE.capChat} outAt={CUE.m4 + 26} y={L.y} {...cap} />
        <Caption f={f} lines={COPY.progress} inAt={CUE.capProgress} outAt={CUE.capProgressOut} y={L.yTop} {...cap} />
        <Caption f={f} lines={COPY.record} inAt={CUE.capRecord} outAt={CUE.capRecordOut} y={L.y} {...cap} />
        <Tagline f={f} format={format} top={taglineTop} />

        <Audio
          src={staticFile('audio/help24_audiomarketing.wav')}
          volume={(af) => {
            // de-click both ends of a track that starts mid-phrase and is trimmed at 59.42 s
            const fadeIn = ramp(af, 0, 3, E.linear);
            const fadeOut = 1 - ramp(af, CUE.musicEnd - 3, CUE.musicEnd, E.linear);
            return Math.max(0, Math.min(fadeIn, fadeOut));
          }}
          endAt={DURATION}
        />
      </AbsoluteFill>
    </FormatContext.Provider>
  );
};
