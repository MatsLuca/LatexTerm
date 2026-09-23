// Clip — plays the kept segments of a real take (rig/cut.py → public/takes/NAME.cuts.json)
// inside a floating window on a quiet backdrop, with camera moves and captions.
// Times in a ClipSpec are TAKE seconds (what the state log and the recorder share);
// the edit maps them to output frames, so a camera move sticks to its moment even
// when the cut list changes.
import React from "react";
import {
  AbsoluteFill,
  Easing,
  Freeze,
  interpolate,
  OffthreadVideo,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { ui } from "./style";

export type Rect = { x: number; y: number; w: number; h: number }; // window points
// Every time below is TAKE seconds of `take` (default: the part's take / the clip's first take).
export type Cam = { take?: string; at: number; rect: Rect | null }; // null = whole window
export type Caption = { take?: string; at: number; until?: number; untilTake?: string; text: string; sub?: string };
export type Badge = { take?: string; at: number; keys: string; label?: string };
export type Edl = { fps: number; scenes: { name: string; segments: [number, number][] }[] };
export type Edls = Record<string, Edl>;

// A part = the kept segments of one scene (by name or index), optionally clipped to `range`;
// or just `range` of the raw take (for moments the cutter has no scene for).
export type Part = { take: string; scene?: string | number; range?: [number, number] };

export type ClipSpec = {
  parts: Part[];
  speed?: { take: string; from: number; to: number; rate: number }[]; // e.g. typing at 1.6×
  cams?: Cam[];
  captions?: Caption[];
  badges?: Badge[];
  tail?: number; // hold the last frame (s)
};

export const takesOf = (spec: ClipSpec) => [...new Set(spec.parts.map((p) => p.take))];

export const WIN = { w: 1512, h: 948 }; // recorded window, points
export const COMP = { w: 1600, h: 1040 };
const PAD = 26;
const FADE = 5; // frames of cross-dissolve at each jump cut
const FPS = 30;

// ——— edit: parts → output timeline ——————————————————————————————————
export type Piece = { take: string; from: number; to: number; rate: number; out: number; frames: number };

const partSegments = (edls: Edls, p: Part): [number, number][] => {
  if (p.scene === undefined) return p.range ? [p.range] : [];
  const scenes = edls[p.take].scenes;
  const sc = typeof p.scene === "number" ? scenes[p.scene] : scenes.find((s) => s.name === p.scene);
  if (!sc) throw new Error(`no scene ${p.scene} in ${p.take}`);
  if (!p.range) return sc.segments;
  const [a, b] = p.range;
  return sc.segments.map(([x, y]) => [Math.max(x, a), Math.min(y, b)] as [number, number]).filter(([x, y]) => y - x > 0.05);
};

export const buildPieces = (edls: Edls, spec: ClipSpec): Piece[] => {
  const pieces: Piece[] = [];
  let out = 0;
  for (const part of spec.parts) {
    const speeds = (spec.speed ?? []).filter((s) => s.take === part.take);
    for (const [a, b] of partSegments(edls, part)) {
      const cuts = [a, b, ...speeds.flatMap((s) => [s.from, s.to]).filter((t) => t > a && t < b)].sort((x, y) => x - y);
      for (let i = 0; i < cuts.length - 1; i++) {
        const from = cuts[i], to = cuts[i + 1];
        const sp = speeds.find((s) => from >= s.from - 1e-3 && to <= s.to + 1e-3);
        const rate = sp?.rate ?? 1;
        const frames = Math.max(1, Math.round(((to - from) / rate) * FPS));
        pieces.push({ take: part.take, from, to, rate, out, frames });
        out += frames;
      }
    }
  }
  return pieces;
};

export const clipFrames = (edls: Edls, spec: ClipSpec) => {
  const p = buildPieces(edls, spec);
  const last = p[p.length - 1];
  return (last ? last.out + last.frames : 1) + Math.round((spec.tail ?? 1.6) * FPS);
};

// take time → output frame (first piece of that take containing it, else the next piece start)
const toFrame = (pieces: Piece[], take: string, t: number) => {
  const own = pieces.filter((p) => p.take === take);
  for (const p of own) {
    if (t >= p.from && t <= p.to) return p.out + ((t - p.from) / p.rate) * FPS;
    if (t < p.from) return p.out;
  }
  const last = own[own.length - 1];
  return last ? last.out + last.frames : 0;
};

// ——— camera ——————————————————————————————————————————————————————————
const FULL: Rect = { x: 0, y: 0, w: WIN.w, h: WIN.h };
const camAt = (keys: { f: number; rect: Rect }[], frame: number): Rect => {
  if (!keys.length) return FULL;
  let prev = { f: -1e9, rect: FULL };
  for (const k of keys) {
    if (frame < k.f) {
      const t = interpolate(frame, [k.f, k.f + 24], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.bezier(0.45, 0, 0.2, 1) });
      // move starts AT the keyed moment: starting earlier would reframe the previous shot (jump cuts)
      if (t <= 0) return prev.rect;
      return lerp(prev.rect, k.rect, t);
    }
    prev = k;
  }
  return prev.rect;
};
const lerp = (a: Rect, b: Rect, t: number): Rect => ({
  x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, w: a.w + (b.w - a.w) * t, h: a.h + (b.h - a.h) * t,
});

// ——— the clip ————————————————————————————————————————————————————————
export const Clip: React.FC<{ spec: ClipSpec; edls: Edls }> = ({ spec, edls }) => {
  const frame = useCurrentFrame();
  const fps = FPS;
  const pieces = buildPieces(edls, spec);
  const first = spec.parts[0].take;
  const at = (take: string | undefined, t: number) => toFrame(pieces, take ?? first, t);

  // window box on the canvas (fit, centred, room for captions below)
  const capH = 66;
  const availW = COMP.w - PAD * 2, availH = COMP.h - PAD * 2 - capH;
  const s = Math.min(availW / WIN.w, availH / WIN.h);
  const box = { w: WIN.w * s, h: WIN.h * s, x: (COMP.w - WIN.w * s) / 2, y: PAD };

  // camera keys in output frames; the tail holds the last camera
  const keys = (spec.cams ?? []).map((c) => ({ f: at(c.take, c.at), rect: c.rect ?? FULL }));
  const cam = camAt(keys, frame);
  // zoom: the whole rect fits (both axes) with a margin; centred on it, clamped to the window
  const MARGIN = 0.94;
  const k = Math.max(1, Math.min(WIN.w / cam.w, WIN.h / cam.h) * (cam.w >= WIN.w - 1 ? 1 : MARGIN));
  const camW = WIN.w / k, camH = WIN.h / k;
  const cx = Math.min(Math.max(cam.x + cam.w / 2 - camW / 2, 0), WIN.w - camW);
  const cy = Math.min(Math.max(cam.y + cam.h / 2 - camH / 2, 0), WIN.h - camH);

  const lastPiece = pieces[pieces.length - 1];

  return (
    <AbsoluteFill style={{ background: ui.backdrop, fontFamily: ui.font }}>
      <div style={{ position: "absolute", inset: 0, background: ui.glow }} />
      <div
        style={{
          position: "absolute", left: box.x, top: box.y, width: box.w, height: box.h,
          borderRadius: 14 * s + 4, overflow: "hidden", boxShadow: ui.shadow,
          outline: "1px solid rgba(255,255,255,0.09)", background: "#171414",
        }}
      >
        <div
          style={{
            position: "absolute", width: WIN.w, height: WIN.h, transformOrigin: "0 0",
            transform: `scale(${s * k}) translate(${-cx}px, ${-cy}px)`,
          }}
        >
          {pieces.map((p, i) => (
            <Sequence key={i} from={p.out} durationInFrames={p.frames + (i < pieces.length - 1 ? FADE : Math.round((spec.tail ?? 1.6) * fps) + 2)} layout="none">
              <PieceVideo src={staticFile(`takes/${p.take}.mp4`)} piece={p} fps={fps} fadeIn={i > 0} hold={i === pieces.length - 1} />
            </Sequence>
          ))}
          <TitlebarPatch />
        </div>
      </div>
      {(spec.captions ?? []).map((c, i) => (
        <CaptionView key={i} c={c} from={at(c.take, c.at)} until={c.until !== undefined ? at(c.untilTake ?? c.take, c.until) : lastPiece ? lastPiece.out + lastPiece.frames + 60 : 1e9} top={box.y + box.h + 14} />
      ))}
      {(spec.badges ?? []).map((b, i) => (
        <BadgeView key={i} b={b} from={at(b.take, b.at)} box={box} />
      ))}
    </AbsoluteFill>
  );
};

const PieceVideo: React.FC<{ src: string; piece: Piece; fps: number; fadeIn: boolean; hold: boolean }> = ({ src, piece, fps, fadeIn, hold }) => {
  const f = useCurrentFrame();
  const opacity = fadeIn ? interpolate(f, [0, FADE], [0, 1], { extrapolateRight: "clamp" }) : 1;
  const start = Math.round(piece.from * fps);
  const end = Math.round(piece.to * fps);
  // hold: after the last piece ends, freeze on its last frame
  const video = <OffthreadVideo src={src} startFrom={start} endAt={end + FADE * 2} playbackRate={piece.rate} muted transparent />; // transparent = PNG frames, no JPEG step
  return (
    <AbsoluteFill style={{ opacity }}>
      {hold && f >= piece.frames - 1 ? <Freeze frame={piece.frames - 1}>{video}</Freeze> : video}
    </AbsoluteFill>
  );
};

// The recorder's purple capture indicator sits on the traffic lights: paint them back.
const TitlebarPatch: React.FC = () => (
  <div style={{ position: "absolute", left: 0, top: 0, width: 110, height: 26, background: "#212121" }}>
    {["#ff5f57", "#febc2e", "#28c840"].map((c, i) => (
      <div key={c} style={{ position: "absolute", left: 10 + i * 20, top: 7, width: 12, height: 12, borderRadius: 6, background: c }} />
    ))}
  </div>
);

const CaptionView: React.FC<{ c: Caption; from: number; until: number; top: number }> = ({ c, from, until, top }) => {
  const f = useCurrentFrame();
  const inT = interpolate(f, [from, from + 10], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const outT = interpolate(f, [until - 8, until], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const o = Math.min(inT, outT);
  if (o <= 0) return null;
  return (
    <div style={{ position: "absolute", left: 0, right: 0, top, textAlign: "center", opacity: o, transform: `translateY(${(1 - inT) * 8}px)` }}>
      <div style={{ fontSize: 30, fontWeight: 650, color: ui.text, letterSpacing: -0.3 }}>{c.text}</div>
      {c.sub && <div style={{ fontSize: 19, color: ui.dim, marginTop: 6 }}>{c.sub}</div>}
    </div>
  );
};

const BadgeView: React.FC<{ b: Badge; from: number; box: { x: number; y: number; w: number; h: number } }> = ({ b, from, box }) => {
  const f = useCurrentFrame();
  const o = interpolate(f, [from - 4, from + 4, from + 40, from + 50], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  if (o <= 0) return null;
  return (
    <div style={{ position: "absolute", left: box.x + box.w / 2, top: box.y + box.h - 90, transform: `translateX(-50%) scale(${0.96 + 0.04 * o})`, opacity: o, display: "flex", gap: 10, alignItems: "center", padding: "10px 16px", borderRadius: 14, background: "rgba(20,20,22,0.82)", backdropFilter: "blur(12px)", border: "1px solid rgba(255,255,255,0.12)", boxShadow: "0 10px 30px rgba(0,0,0,0.4)" }}>
      {b.keys.split(" ").map((k) => (
        <span key={k} style={{ fontSize: 22, fontWeight: 600, color: "#fff", padding: "4px 10px", borderRadius: 8, background: "rgba(255,255,255,0.1)", border: "1px solid rgba(255,255,255,0.16)" }}>{k}</span>
      ))}
      {b.label && <span style={{ fontSize: 19, color: ui.dim, marginLeft: 4 }}>{b.label}</span>}
    </div>
  );
};
