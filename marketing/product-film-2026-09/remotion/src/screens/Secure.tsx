import React from 'react';
import { CUE } from '../config/cues';
import { APP_PAGE, DETAIL as DT, r, Rect, SECURE as S } from '../config/screens';
import { E, mix, ramp } from '../lib/anim';
import { Slice } from '../components/Slice';
import { StatusBar } from '../components/StatusBar';
import { Veil } from '../components/Press';
import { nightAt } from '../scenes/choreography';

/**
 * "Secure this service", in its IDLE state: nothing is paid in this film.
 * The Pay button is never pressed; no M-Pesa prompt, success or receipt appears.
 */

/** detail -> secure: shared X axis (the next step in a sequence) */
export const toSecureT = (f: number) => ramp(f, CUE.toSecure, CUE.toSecure + 26, E.move);

const ELEMENTS: Rect[] = [S.header, S.breakdown, S.mpesa, S.protection, S.pay, S.caption];

/** Focus window: breakdown first, then the protection note, then released. */
const focus = (f: number) => {
  const toNote = ramp(f, CUE.readNote, CUE.readNote + 34, E.cam);
  const rect: Rect = {
    x: mix(S.breakdownCard.x, S.protectionCard.x, toNote),
    y: mix(S.breakdownCard.y, S.protectionCard.y, toNote),
    w: mix(S.breakdownCard.w, S.protectionCard.w, toNote),
    h: mix(S.breakdownCard.h, S.protectionCard.h, toNote),
  };
  const amount =
    Math.min(ramp(f, CUE.readBreakdown + 8, CUE.readBreakdown + 36, E.move), 1 - ramp(f, CUE.pullBack, CUE.pullBack + 26, E.move)) *
    mix(0.62, 1, toNote);
  return { rect, amount, toNote };
};

export const SecureScreen: React.FC<{ f: number }> = ({ f }) => {
  const t = toSecureT(f);
  const leave = ramp(f, CUE.toChat, CUE.toChat + 22, E.move);
  const x = (1 - t) * 240 - leave * 240;
  const opacity = ramp(t, 0.2, 0.75, E.linear) * (1 - ramp(leave, 0, 0.4, E.linear));
  // the screen is populated almost at once (no blank phone on the drop), settling top-down
  const settle = (i: number) => ramp(f, CUE.toSecure + 2 + i * 2.5, CUE.toSecure + 18 + i * 2.5, E.out);
  const { rect, amount, toNote } = focus(f);
  // in the dark room the rest of the screen dims, like a lamp on one card; by day it recedes to paper
  const night = nightAt(f);
  const veilRGB = [250, 249, 247].map((v, i) => Math.round(mix(v, [14, 17, 20][i], night))).join(',');
  const lift = amount * toNote;
  const amountLanded = f >= CUE.secureSettled;
  const titleGone = f >= CUE.toChat;
  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE, transform: `translateX(${x}px)`, opacity }}>
      <Slice shot="secure" r={S.appBar} />
      {ELEMENTS.map((el, i) => {
        const p = settle(i);
        return (
          <Slice
            key={i}
            shot="secure"
            r={el}
            style={{ transform: `translateY(${(1 - p) * 28}px)`, opacity: p }}
          >
            {el === S.breakdown && !amountLanded && (
              <div
                style={{
                  position: 'absolute',
                  left: S.total.x - el.x - 4,
                  top: S.total.y - el.y - 4,
                  width: S.total.w + 8,
                  height: S.total.h + 8,
                  background: '#FFFFFF',
                }}
              />
            )}
            {el === S.header && titleGone && (
              <div
                style={{
                  position: 'absolute',
                  left: S.headerTitle.x - el.x - 4,
                  top: S.headerTitle.y - el.y - 4,
                  width: S.headerTitle.w + 8,
                  height: S.headerTitle.h + 8,
                  background: '#FFFFFF',
                }}
              />
            )}
          </Slice>
        );
      })}
      <Slice shot="secure" r={S.rest} />
      <Veil rect={rect} amount={amount} radius={S.cardRadius} max={mix(0.74, 0.54, night)} color={veilRGB} />
      {/* the protection note, lifted a touch toward the viewer while it is read */}
      {lift > 0.001 && (
        <Slice
          shot="secure"
          r={S.protectionCard}
          radius={S.cardRadius}
          style={{
            transform: `scale(${1 + 0.018 * lift})`,
            transformOrigin: '50% 50%',
            boxShadow: `0 ${26 * lift}px ${60 * lift}px rgba(18,22,26,${0.16 * lift})`,
          }}
        />
      )}
      <StatusBar />
    </div>
  );
};

/** The detail screen stepping aside for "Secure this service". */
export const detailExit = (f: number) => {
  const t = toSecureT(f);
  return {
    transform: `translateX(${-t * 240}px)`,
    opacity: 1 - ramp(t, 0, 0.4, E.linear),
  };
};

/** "KES 2,545" carried from the button into "Total to secure". */
export const AmountFlyer: React.FC<{ f: number }> = ({ f }) => {
  const t = ramp(f, CUE.toSecure, CUE.secureSettled, E.inOut);
  if (f < CUE.toSecure || f >= CUE.secureSettled) return null;
  const a = DT.buttonAmount;
  const b = S.total;
  const sB = b.w / a.w;
  const k = mix(1, sB, t);
  const cross = ramp(t, 0.3, 0.62, E.linear);
  const x = mix(a.x, b.x, t);
  const y = mix(a.y, b.y, t);
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        transform: `scale(${k})`,
        transformOrigin: '0 0',
      }}
    >
      <Slice shot="detail-top" r={a} x={0} y={0} radius={14} style={{ opacity: 1 - cross }} />
      <Slice
        shot="secure"
        r={r(b.x, b.y, b.w, b.h)}
        x={0}
        y={0}
        style={{ opacity: cross, transform: `scale(${1 / sB})`, transformOrigin: '0 0' }}
      />
    </div>
  );
};
