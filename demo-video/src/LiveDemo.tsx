import React from "react";
import {
  AbsoluteFill,
  Img,
  OffthreadVideo,
  Series,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { theme } from "./theme";
import { TitleCard } from "./components/Overlays";

// Source footage: real screen recording of LatexTerm, 1512x948 points, 30fps proxy.
// Comp is 1512x828 — the bottom 120pt (statuslines) fall off at zoom 1.
const SRC_W = 1512;
const SRC_H = 948;
export const COMP_W = 1512;
export const COMP_H = 772;

type Cam = { cx: number; cy: number; z: number };
const WIDE: Cam = { cx: SRC_W / 2, cy: COMP_H / 2, z: 1 };

// Maps a source point (cx,cy) to the comp center at zoom z
const camStyle = (cam: Cam): React.CSSProperties => ({
  position: "absolute",
  width: SRC_W,
  height: SRC_H,
  transformOrigin: "0 0",
  transform: `translate(${COMP_W / 2 - cam.cx * cam.z}px, ${
    COMP_H / 2 - cam.cy * cam.z
  }px) scale(${cam.z})`,
});

const lerpCam = (a: Cam, b: Cam, t: number): Cam => ({
  cx: a.cx + (b.cx - a.cx) * t,
  cy: a.cy + (b.cy - a.cy) * t,
  z: a.z + (b.z - a.z) * t,
});

// One statement at a time, bottom-center, premium lower-third
const Statement: React.FC<{ text: string; appearFrame?: number }> = ({
  text,
  appearFrame = 8,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (frame < appearFrame) return null;
  const s = spring({ frame: frame - appearFrame, fps, config: { damping: 15 } });
  return (
    <div
      style={{
        position: "absolute",
        bottom: 44,
        left: 0,
        right: 0,
        display: "flex",
        justifyContent: "center",
        transform: `translateY(${(1 - s) * 26}px)`,
        opacity: s,
      }}
    >
      <div
        style={{
          fontFamily: theme.uiFont,
          fontSize: 40,
          fontWeight: 700,
          letterSpacing: -0.5,
          color: "#fff",
          background: "rgba(10,8,8,0.72)",
          border: "1px solid rgba(255,255,255,0.12)",
          backdropFilter: "blur(14px)",
          borderRadius: 16,
          padding: "14px 30px",
          boxShadow: "0 12px 40px rgba(0,0,0,0.45)",
          maxWidth: "88%",
          textAlign: "center",
        }}
      >
        {text}
      </div>
    </div>
  );
};

// A video shot: plays [srcFrom, srcFrom+dur] while the camera moves from->to
const Shot: React.FC<{
  srcFrom: number; // seconds in source
  from?: Cam;
  to?: Cam;
  moveStart?: number; // frame at which the camera starts moving
  moveDur?: number;
  caption?: string;
  captionAt?: number;
}> = ({
  srcFrom,
  from = WIDE,
  to,
  moveStart = 6,
  moveDur = 22,
  caption,
  captionAt = 10,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = to
    ? spring({
        frame: frame - moveStart,
        fps,
        config: { damping: 18, mass: 0.9 },
        durationInFrames: moveDur,
      })
    : 0;
  const cam = to ? lerpCam(from, to, t) : from;
  return (
    <AbsoluteFill style={{ background: "#000", overflow: "hidden" }}>
      <OffthreadVideo
        src={staticFile("take1.mp4")}
        startFrom={Math.round(srcFrom * 30)}
        style={camStyle(cam)}
        muted
      />
      {caption && <Statement text={caption} appearFrame={captionAt} />}
    </AbsoluteFill>
  );
};

// A frozen prompt moment rendered from a crisp PNG still (same coordinate space)
const Hold: React.FC<{ img: string; cam: Cam; caption?: string }> = ({
  img,
  cam,
  caption,
}) => {
  const frame = useCurrentFrame();
  const pulse = 1 + 0.006 * Math.sin(frame / 6); // subtle life so it doesn't feel stuck
  return (
    <AbsoluteFill style={{ background: "#000", overflow: "hidden" }}>
      <Img
        src={staticFile(img)}
        style={camStyle({ ...cam, z: cam.z * pulse })}
      />
      {caption && <Statement text={caption} appearFrame={2} />}
    </AbsoluteFill>
  );
};

// Camera targets measured from the footage (1512x948 point space)
const CAM = {
  prompt2: { cx: 1023, cy: 566, z: 2.0 }, // pane 2 prompt line at t≈15
  prompt3: { cx: 1260, cy: 593, z: 2.0 }, // pane 3 prompt line at t≈30
  prompt4: { cx: 1321, cy: 580, z: 2.0 }, // pane 4 prompt line at t≈46.5
  testsFixed: { cx: 952, cy: 150, z: 1.9 }, // pane 3 "Verified both assertions pass"
  snakeWrite: { cx: 1323, cy: 400, z: 1.9 }, // pane 4 Write(snake.py) streaming at t≈90
  browser: { cx: 756, cy: 501, z: 1.0 }, // full-screen Safari, chrome + bookmarks cropped
};

export const LiveDemo: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Series>
        {/* Cold open: real window, second pane tiles in */}
        <Series.Sequence durationInFrames={120}>
          <Shot
            srcFrom={3}
            caption="One agent orchestrates your terminal."
            captionAt={14}
          />
        </Series.Sequence>

        {/* Delegation 1: push into the landing-page prompt, freeze */}
        <Series.Sequence durationInFrames={120}>
          <Shot srcFrom={11} from={WIDE} to={CAM.prompt2} moveStart={40} />
        </Series.Sequence>
        <Series.Sequence durationInFrames={55}>
          <Hold
            img="still_a.png"
            cam={CAM.prompt2}
            caption="It delegates — in plain language."
          />
        </Series.Sequence>

        {/* Delegation 2 */}
        <Series.Sequence durationInFrames={90}>
          <Shot srcFrom={27} from={WIDE} to={CAM.prompt3} moveStart={30} />
        </Series.Sequence>
        <Series.Sequence durationInFrames={50}>
          <Hold
            img="still_b.png"
            cam={CAM.prompt3}
            caption="Another pane. Another agent."
          />
        </Series.Sequence>

        {/* Delegation 3 */}
        <Series.Sequence durationInFrames={90}>
          <Shot srcFrom={43.5} from={WIDE} to={CAM.prompt4} moveStart={30} />
        </Series.Sequence>
        <Series.Sequence durationInFrames={50}>
          <Hold
            img="still_c.png"
            cam={CAM.prompt4}
            caption="Three tasks. Zero copy-paste."
          />
        </Series.Sequence>

        {/* Parallel work, wide */}
        <Series.Sequence durationInFrames={170}>
          <Shot
            srcFrom={50}
            caption="They work in parallel — for real."
            captionAt={16}
          />
        </Series.Sequence>

        {/* Results */}
        <Series.Sequence durationInFrames={120}>
          <Shot
            srcFrom={62}
            from={WIDE}
            to={CAM.testsFixed}
            moveStart={8}
            caption="Tests: fixed — and verified."
            captionAt={40}
          />
        </Series.Sequence>
        <Series.Sequence durationInFrames={130}>
          <Shot
            srcFrom={90}
            from={WIDE}
            to={CAM.snakeWrite}
            moveStart={8}
            caption="182 lines of snake, incoming."
            captionAt={40}
          />
        </Series.Sequence>

        {/* The kicker: the real browser pops with the finished page */}
        <Series.Sequence durationInFrames={160}>
          <Shot
            srcFrom={78.5}
            from={CAM.browser}
            caption="It didn't just write it. It shipped it."
            captionAt={20}
          />
        </Series.Sequence>

        {/* Calm outro on the cockpit */}
        <Series.Sequence durationInFrames={110}>
          <Shot
            srcFrom={120}
            caption="LatexTerm — the cockpit for your agents."
            captionAt={12}
          />
        </Series.Sequence>

        <Series.Sequence durationInFrames={90}>
          <TitleCard
            small
            title="LatexTerm"
            subtitle="github.com/MatsLuca/LatexTerm — panes on demand · live status · notifications · KaTeX"
          />
        </Series.Sequence>
      </Series>
    </AbsoluteFill>
  );
};
