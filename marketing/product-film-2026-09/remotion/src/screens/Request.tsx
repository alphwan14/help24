import React from 'react';
import { CUE } from '../config/cues';
import { APP_PAGE, COMPOSER as C, DETAIL as DT, MYPOSTS as M, r, Rect } from '../config/screens';
import { E, mix, ramp, track } from '../lib/anim';
import { Shot, Slice } from '../components/Slice';
import { StatusBar } from '../components/StatusBar';
import { pressScale, Ripple, Veil } from '../components/Press';

const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({
  x: mix(a.x, b.x, t),
  y: mix(a.y, b.y, t),
  w: mix(a.w, b.w, t),
  h: mix(a.h, b.h, t),
});

/* ============================================================ Ask: the composer */

/** a sheet rising: ease-out, not emphasized-decelerate, which would cover half the screen in its first frame */
export const composerRise = (f: number) => ramp(f, CUE.composerIn - 2, CUE.composerIn + 22, E.out);
/** composer card -> "Emergency Dog Trainer" card (Material container transform) */
export const toMyPostsT = (f: number) => ramp(f, CUE.toMyPosts, CUE.toMyPosts + 28, E.move);

export const ComposerScreen: React.FC<{ f: number }> = ({ f }) => {
  const rise = composerRise(f);
  const leave = ramp(f, CUE.toMyPosts, CUE.toMyPosts + 12, E.exit);
  const cardIn = (i: number) => ramp(f, CUE.composerIn + 5 + i * 3, CUE.composerIn + 27 + i * 3, E.out);
  const reqScale = pressScale(f, CUE.requestDown, CUE.requestUp, 0.022);
  const cards: Array<[Rect, number]> = [
    [C.offer, 1],
    [C.job, 2],
    [C.cont, 3],
  ];
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        background: APP_PAGE,
        transform: `translateY(${(1 - rise) * 2400}px)`,
        opacity: 1 - leave,
      }}
    >
      <Slice shot="post-composer" r={C.head} />
      {f < CUE.toMyPosts && (
        <Slice
          shot="post-composer"
          r={C.request}
          style={{
            transform: `translateY(${(1 - cardIn(0)) * 70}px) scale(${reqScale})`,
            transformOrigin: '50% 50%',
            opacity: cardIn(0),
          }}
        />
      )}
      <Ripple
        f={f}
        down={CUE.requestDown}
        rect={C.request}
        at={{ x: 470, y: 560 }}
        radius={C.cardRadius}
        color="18,22,26"
        strength={0.07}
      />
      {cards.map(([rect, i]) => (
        <Slice
          key={i}
          shot="post-composer"
          r={rect}
          style={{ transform: `translateY(${(1 - cardIn(i)) * 70}px)`, opacity: cardIn(i) }}
        />
      ))}
      <Slice shot="post-composer" r={r(0, 2330, 1080, 70)} />
      <StatusBar />
    </div>
  );
};

/* ============================================================ The request card in My posts */

export const MyPostsScreen: React.FC<{ f: number }> = ({ f }) => {
  const t = toMyPostsT(f);
  const appear = ramp(f, CUE.toMyPosts + 4, CUE.toMyPosts + 22, E.move);
  // focus: this card is the job the film follows; the rest of the list recedes
  const veil = ramp(f, CUE.toMyPosts + 14, CUE.toMyPosts + 40, E.move);
  const cardScale = pressScale(f, CUE.cardDown, CUE.cardUp, 0.018);
  const landed = t >= 1;
  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE, opacity: appear }}>
      <Shot shot="myposts" />
      {/* while the card is in flight its slot is empty page */}
      <div
        style={{
          position: 'absolute',
          left: M.dogCard.x - 2,
          top: M.dogCard.y - 2,
          width: M.dogCard.w + 4,
          height: M.dogCard.h + 4,
          background: APP_PAGE,
        }}
      />
      <Veil rect={M.dogCard} amount={veil} radius={M.cardRadius} max={0.9} />
      {landed && f < CUE.toDetail && (
        <Slice
          shot="myposts"
          r={M.dogCard}
          style={{ transform: `scale(${cardScale})`, transformOrigin: '50% 50%' }}
        />
      )}
      {landed && (
        <Ripple
          f={f}
          down={CUE.cardDown}
          rect={M.dogCard}
          at={{ x: 520, y: 1210 }}
          radius={M.cardRadius}
          color="18,22,26"
          strength={0.07}
        />
      )}
      <StatusBar />
    </div>
  );
};

/** The card in flight from the composer to My posts. */
export const ComposerToMyPostsFlyer: React.FC<{ f: number }> = ({ f }) => {
  const t = toMyPostsT(f);
  if (t <= 0 || t >= 1) return null;
  const rect = lerpRect(C.request, M.dogCard, t);
  const aOut = 1 - ramp(t, 0.0, 0.32, E.linear);
  const bIn = ramp(t, 0.34, 0.86, E.linear);
  return (
    <div
      style={{
        position: 'absolute',
        left: rect.x,
        top: rect.y,
        width: rect.w,
        height: rect.h,
        borderRadius: C.cardRadius,
        overflow: 'hidden',
        background: '#FFFFFF',
        boxShadow: `0 0 0 2px rgba(227,224,217,${1 - bIn}), 0 ${24 * Math.sin(Math.PI * t)}px ${
          60 * Math.sin(Math.PI * t)
        }px rgba(18,22,26,${0.14 * Math.sin(Math.PI * t)})`,
      }}
    >
      <Slice shot="post-composer" r={C.request} x={0} y={0} style={{ opacity: aOut }} />
      <Slice shot="myposts" r={M.dogCard} x={0} y={0} style={{ opacity: bIn }} />
    </div>
  );
};

/* ============================================================ The request, in full */

/** card -> detail screen (container transform) */
export const toDetailT = (f: number) => ramp(f, CUE.toDetail, CUE.toDetail + 30, E.move);

export const detailScroll = (f: number) =>
  track(
    [
      { f: CUE.scroll1, v: 0 },
      { f: CUE.scroll1 + 34, v: 300, ease: E.move },
      { f: CUE.scroll2, v: 300, ease: E.linear },
      { f: CUE.scroll2 + 40, v: DT.scrollMax, ease: E.move },
    ],
    f,
  );

export const DetailScreen: React.FC<{ f: number }> = ({ f }) => {
  const s = detailScroll(f);
  const btnScale = pressScale(f, CUE.secureDown, CUE.secureUp, 0.024);
  const titleInFlight = f < CUE.toDetail + 30;
  return (
    <div style={{ position: 'absolute', inset: 0, background: APP_PAGE }}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: DT.viewport.y,
          width: 1080,
          height: DT.viewport.h,
          overflow: 'hidden',
        }}
      >
        {DT.content.map((p) => (
          <Slice key={p.shot} shot={p.shot} r={r(0, p.srcY, 1080, p.h)} x={0} y={p.contentY - s - DT.viewport.y} />
        ))}
        {titleInFlight && (
          <div
            style={{
              position: 'absolute',
              left: DT.title.x - 4,
              top: DT.title.y - DT.viewport.y - 4,
              width: DT.title.w + 8,
              height: DT.title.h + 8,
              background: APP_PAGE,
            }}
          />
        )}
      </div>
      <Slice shot="detail-top" r={DT.appBar} />
      <Slice shot="detail-top" r={DT.bottomBar} />
      <Slice
        shot="detail-top"
        r={DT.button}
        radius={DT.buttonRadius}
        style={{ transform: `scale(${btnScale})`, transformOrigin: '50% 50%' }}
      />
      <Ripple
        f={f}
        down={CUE.secureDown}
        rect={DT.button}
        at={{ x: 560, y: 2256 }}
        radius={DT.buttonRadius}
        color="255,255,255"
        strength={0.18}
      />
      <StatusBar />
    </div>
  );
};

/** The detail screen growing out of the tapped card, with the job title carried across. */
export const CardToDetail: React.FC<{ f: number; children: React.ReactNode }> = ({ f, children }) => {
  const t = toDetailT(f);
  if (t <= 0) return null;
  if (t >= 1) return <>{children}</>;
  const full = r(0, 0, 1080, 2400);
  const rect = lerpRect(M.dogCard, full, t);
  const radius = mix(M.cardRadius, 0, t);
  const cardOut = 1 - ramp(t, 0.0, 0.3, E.linear);
  const pageIn = ramp(t, 0.16, 0.58, E.linear);
  return (
    <div
      style={{
        position: 'absolute',
        left: rect.x,
        top: rect.y,
        width: rect.w,
        height: rect.h,
        borderRadius: radius,
        overflow: 'hidden',
        background: '#FFFFFF',
        boxShadow: `0 30px 80px rgba(18,22,26,${0.16 * (1 - t)})`,
      }}
    >
      <div style={{ position: 'absolute', left: -rect.x, top: -rect.y, width: 1080, height: 2400, opacity: pageIn }}>
        {children}
      </div>
      <Slice shot="myposts" r={M.dogCard} x={M.dogCard.x - rect.x} y={M.dogCard.y - rect.y} style={{ opacity: cardOut }}>
        {/* the title is travelling on its own (TitleToDetailFlyer) */}
        <div
          style={{
            position: 'absolute',
            left: M.dogTitle.x - M.dogCard.x - 4,
            top: M.dogTitle.y - M.dogCard.y - 4,
            width: M.dogTitle.w + 8,
            height: M.dogTitle.h + 8,
            background: '#FFFFFF',
          }}
        />
      </Slice>
    </div>
  );
};

/** "Emergency Dog Trainer": My posts title -> detail title. */
export const TitleToDetailFlyer: React.FC<{ f: number }> = ({ f }) => {
  const t = toDetailT(f);
  if (t <= 0 || t >= 1) return null;
  const a = M.dogTitle;
  const b = DT.title;
  const sB = b.h / a.h;
  const k = mix(1, sB, t);
  const x = mix(a.x, b.x, t);
  const y = mix(a.y, b.y, t);
  const cross = ramp(t, 0.35, 0.65, E.linear);
  return (
    <div style={{ position: 'absolute', left: x, top: y, transform: `scale(${k})`, transformOrigin: '0 0' }}>
      <Slice shot="myposts" r={a} x={0} y={0} style={{ opacity: 1 - cross }} />
      <Slice
        shot="detail-top"
        r={b}
        x={0}
        y={0}
        style={{ opacity: cross, transform: `scale(${1 / sB})`, transformOrigin: '0 0' }}
      />
    </div>
  );
};
