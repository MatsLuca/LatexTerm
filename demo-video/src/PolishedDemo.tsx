import React from "react";
import {
  AbsoluteFill,
  Series,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { theme } from "./theme";
import { Formula } from "./components/Formula";
import {
  NotificationBanner,
  ShortcutBadge,
  TitleCard,
} from "./components/Overlays";

// ————————————————————————————— Layout math —————————————————————————————
// Comp 1280x800. Window 88%/84% → content box (inside titlebar + 8px inset):
const W = 1280;
const H = 800;
const WIN = { x: 77, y: 64, w: 1126, h: 672 };
const CBOX = { x: WIN.x + 8, y: WIN.y + 44, w: WIN.w - 16, h: WIN.h - 52 };
const GAP = 8;

type Rect = { x: number; y: number; w: number; h: number };

// Top-heavy masonry like TerminalSplitView: 1-3 → one row, 4 → 2x2, 5 → 3+2, 6 → 3+3
const layout = (n: number): Rect[] => {
  const rows: number[] = n <= 3 ? [n] : n === 4 ? [2, 2] : n === 5 ? [3, 2] : [3, 3];
  const rh = (CBOX.h - GAP * (rows.length - 1)) / rows.length;
  const rects: Rect[] = [];
  rows.forEach((cols, r) => {
    const cw = (CBOX.w - GAP * (cols - 1)) / cols;
    for (let c = 0; c < cols; c++) {
      rects.push({
        x: CBOX.x + c * (cw + GAP),
        y: CBOX.y + r * (rh + GAP),
        w: cw,
        h: rh,
      });
    }
  });
  return rects;
};

const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  w: a.w + (b.w - a.w) * t,
  h: a.h + (b.h - a.h) * t,
});

// Grid states over the cockpit scene (local frames).
// Panes are opened BY THE ORCHESTRATOR (pane 0) — births follow its tool calls.
type GridState = { f: number; n: number; zoom?: number };
const GRID: GridState[] = [
  { f: 0, n: 1 },
  { f: 140, n: 2 }, // latexterm new-pane → coffee
  { f: 275, n: 3 }, // latexterm new-pane → tests
  { f: 405, n: 4 }, // latexterm new-pane → snake
  { f: 560, n: 5 },
  { f: 590, n: 6 },
  { f: 620, n: 6, zoom: 2 }, // ⌘⏎ on the tests pane
  { f: 710, n: 6 },
];
const BORN = [0, 140, 275, 405, 560, 590];

const gridAt = (frame: number, fps: number) => {
  let cur = GRID[0];
  let prev = GRID[0];
  for (const g of GRID) {
    if (frame >= g.f) {
      prev = cur;
      cur = g;
    }
  }
  const t = spring({
    frame: frame - cur.f,
    fps,
    config: { damping: 17, mass: 0.8 },
    durationInFrames: 14,
  });
  return { cur, prev, t };
};

const rectAt = (
  pane: number,
  frame: number,
  fps: number
): { rect: Rect; visible: boolean; dim: number; onTop: boolean } => {
  const { cur, prev, t } = gridAt(frame, fps);
  const rNow = (g: GridState): Rect | null => {
    if (g.zoom !== undefined && g.zoom === pane) return CBOX;
    const rects = layout(g.n);
    return pane < g.n ? rects[pane] : null;
  };
  const a = rNow(prev);
  const b = rNow(cur);
  if (!a && !b) return { rect: CBOX, visible: false, dim: 0, onTop: false };
  const rect = a && b ? lerpRect(a, b, t) : (b ?? a)!;
  const zoomActive = cur.zoom !== undefined;
  const isZoomed = cur.zoom === pane;
  return {
    rect,
    visible: Boolean(b) || Boolean(a),
    dim: zoomActive && !isZoomed ? 0.35 * t : 0,
    onTop: isZoomed,
  };
};

// ————————————————————————————— Camera —————————————————————————————
type Cam = { cx: number; cy: number; z: number };
const WIDE: Cam = { cx: W / 2, cy: H / 2, z: 1 };
const CAM_KEYS: { f: number; cam: Cam }[] = [
  { f: 0, cam: WIDE },
  { f: 30, cam: { cx: 370, cy: 245, z: 2.2 } }, // orchestrator input (full-width pane)
  // medium shot: orchestrator's latexterm commands left, new pane tiling in right
  { f: 116, cam: { cx: 500, cy: 340, z: 1.5 } },
  { f: 190, cam: { cx: 919, cy: 245, z: 2.0 } }, // coffee pane: prompt arrives by itself
  { f: 245, cam: WIDE },
  { f: 262, cam: { cx: 420, cy: 380, z: 1.55 } }, // orchestrator opens + prompts pane 3
  { f: 338, cam: { cx: 1012, cy: 245, z: 2.0 } }, // tests pane: prompt arrives
  { f: 392, cam: WIDE },
];

const camAt = (frame: number, fps: number): Cam => {
  let cam = CAM_KEYS[0].cam;
  for (let i = 1; i < CAM_KEYS.length; i++) {
    const k = CAM_KEYS[i];
    if (frame < k.f) break;
    const t = spring({
      frame: frame - k.f,
      fps,
      config: { damping: 19, mass: 0.9 },
      durationInFrames: 26,
    });
    cam = {
      cx: cam.cx + (k.cam.cx - cam.cx) * t,
      cy: cam.cy + (k.cam.cy - cam.cy) * t,
      z: cam.z + (k.cam.z - cam.z) * t,
    };
  }
  return cam;
};

// ————————————————————————————— Claude Code TUI —————————————————————————————
const MONO = { fontFamily: theme.font };

const WelcomeBox: React.FC<{ cwd: string; at: number }> = ({ cwd, at }) => {
  const frame = useCurrentFrame();
  if (frame < at) return null;
  return (
    <div
      style={{
        border: "1px solid rgba(232,120,87,0.55)",
        borderRadius: 8,
        padding: "8px 12px",
        marginBottom: 10,
        flexShrink: 0,
      }}
    >
      <div style={{ color: theme.accentClaude, fontWeight: 600 }}>
        ✻ Welcome to Claude Code
      </div>
      <div style={{ color: theme.textDim, fontSize: "0.85em", marginTop: 2 }}>
        Sonnet 5 · Claude Max
      </div>
      <div style={{ color: theme.textDim, fontSize: "0.85em" }}>{cwd}</div>
    </div>
  );
};

const Spinner: React.FC<{ start: number; verb: string }> = ({ start, verb }) => {
  const frame = useCurrentFrame();
  const glyphs = ["✻", "✶", "✳", "✽", "∗"];
  const g = glyphs[Math.floor(frame / 6) % glyphs.length];
  const secs = Math.max(0, Math.floor((frame - start) / 30));
  const toks = ((frame - start) * 21).toLocaleString("en-US");
  return (
    <div style={{ color: theme.accentClaude, marginTop: 8 }}>
      {g} {verb}…{" "}
      <span style={{ color: theme.textDim }}>
        ({secs}s · {toks} tokens · esc to interrupt)
      </span>
    </div>
  );
};

type ToolLine = { at: number; head: string; sub?: string; subAfter?: number };
const Tool: React.FC<ToolLine> = ({ at, head, sub, subAfter = 10 }) => {
  const frame = useCurrentFrame();
  if (frame < at) return null;
  return (
    <div style={{ marginTop: 8 }}>
      <div>
        <span style={{ color: theme.green }}>● </span>
        <span style={{ color: theme.text }}>{head}</span>
      </div>
      {sub && frame > at + subAfter && (
        <div style={{ color: theme.textDim, paddingLeft: 18 }}>⎿ {sub}</div>
      )}
    </div>
  );
};

// A scripted Claude session. The prompt either gets TYPED (a human) or PASTED
// (delegated by the orchestrator via `latexterm send` — lands in one piece).
const ClaudeSession: React.FC<{
  boot: number;
  cwd: string;
  prompt?: string;
  typeStart?: number;
  pasteAt?: number;
  tools?: ToolLine[];
  doneAt?: number;
  doneText?: string;
  verb?: string;
  fontSize: number;
}> = ({
  boot,
  cwd,
  prompt,
  typeStart,
  pasteAt,
  tools = [],
  doneAt,
  doneText,
  verb = "Pondering",
  fontSize,
}) => {
  const frame = useCurrentFrame();
  let inputText = "";
  let submitFrame = 1e9;
  if (prompt && typeStart !== undefined) {
    const typeEnd = typeStart + Math.ceil(prompt.length / 1.6);
    inputText = prompt.slice(0, Math.max(0, Math.floor((frame - typeStart) * 1.6)));
    submitFrame = typeEnd + 6;
  } else if (prompt && pasteAt !== undefined) {
    inputText = frame >= pasteAt ? prompt : "";
    submitFrame = pasteAt + 14;
  }
  const submitted = frame >= submitFrame;
  const isDone = doneAt !== undefined && frame >= doneAt;
  const working = submitted && !isDone;
  return (
    <div
      style={{
        ...MONO,
        fontSize,
        lineHeight: 1.75,
        color: theme.text,
        display: "flex",
        flexDirection: "column",
        height: "100%",
        overflow: "hidden",
      }}
    >
      <WelcomeBox cwd={cwd} at={boot + 6} />
      {submitted && prompt && (
        <div
          style={{
            background: "rgba(255,255,255,0.07)",
            padding: "2px 8px",
            borderRadius: 4,
            flexShrink: 0,
          }}
        >
          <span style={{ color: theme.textDim }}>{">"} </span>
          {prompt}
        </div>
      )}
      {submitted && tools.map((t, i) => <Tool key={i} {...t} />)}
      {working && <Spinner start={submitFrame} verb={verb} />}
      {isDone && doneText && (
        <div style={{ color: theme.green, marginTop: 8 }}>{doneText}</div>
      )}
      <div style={{ marginTop: 10, flexShrink: 0 }}>
        <div
          style={{
            border: `1px solid ${
              submitted ? "rgba(255,255,255,0.25)" : "rgba(232,120,87,0.7)"
            }`,
            borderRadius: 6,
            padding: "3px 10px",
            // pasted prompts flash highlighted for a beat, like a real paste
            background:
              pasteAt !== undefined && frame >= pasteAt && !submitted
                ? "rgba(232,120,87,0.14)"
                : "transparent",
          }}
        >
          <span style={{ color: theme.textDim }}>{">"} </span>
          {!submitted && inputText}
          {!submitted && Math.floor(frame / 14) % 2 === 0 && (
            <span
              style={{
                display: "inline-block",
                width: "0.55em",
                height: "1.1em",
                background: theme.accentClaude,
                verticalAlign: "text-bottom",
              }}
            />
          )}
          {submitted && (
            <span style={{ color: theme.textDim, opacity: 0.6 }}>
              Try "explain this codebase"
            </span>
          )}
        </div>
        <div
          style={{
            color: "#c4587a",
            opacity: 0.75,
            fontSize: "0.8em",
            padding: "3px 2px 0",
          }}
        >
          ⏵⏵ bypass permissions on{" "}
          <span style={{ color: theme.textDim }}>(shift+tab to cycle)</span>
        </div>
      </div>
    </div>
  );
};

const ShellSession: React.FC<{ fontSize: number }> = ({ fontSize }) => (
  <div style={{ ...MONO, fontSize, lineHeight: 1.75, color: theme.text }}>
    <span style={{ color: theme.textDim }}>~ </span>
    <span style={{ color: theme.green }}>❯ </span>
    <span
      style={{
        display: "inline-block",
        width: "0.55em",
        height: "1.1em",
        background: theme.accent,
        verticalAlign: "text-bottom",
      }}
    />
  </div>
);

// ————————————————————————————— Desktop & window chrome —————————————————————————————
const MenuBar: React.FC = () => (
  <div
    style={{
      position: "absolute",
      top: 0,
      left: 0,
      right: 0,
      height: 26,
      display: "flex",
      alignItems: "center",
      padding: "0 14px",
      gap: 18,
      background: "rgba(18,18,21,0.75)",
      backdropFilter: "blur(20px)",
      borderBottom: "1px solid rgba(255,255,255,0.06)",
      fontFamily: theme.uiFont,
      fontSize: 13,
      color: "rgba(255,255,255,0.85)",
      zIndex: 20,
    }}
  >
    <span></span>
    <span style={{ fontWeight: 700 }}>LatexTerm</span>
    {["File", "Edit", "View", "Terminal", "Formeln", "Window", "Help"].map((m) => (
      <span key={m} style={{ opacity: 0.75 }}>
        {m}
      </span>
    ))}
    <span style={{ marginLeft: "auto", opacity: 0.75 }}>Mon 6 Jul 14:32</span>
  </div>
);

// ————————————————————————————— Window chrome —————————————————————————————
const WindowChrome: React.FC<{ dotPulse?: number; zoomBadge?: boolean }> = ({
  dotPulse,
  zoomBadge,
}) => (
  <div
    style={{
      position: "absolute",
      left: WIN.x,
      top: WIN.y,
      width: WIN.w,
      height: WIN.h,
      borderRadius: 14,
      background: theme.windowBgTranslucent,
      border: "1px solid rgba(255,255,255,0.12)",
      boxShadow: "0 30px 80px rgba(0,0,0,0.55)",
    }}
  >
    <div
      style={{
        height: 44,
        display: "flex",
        alignItems: "center",
        padding: "0 18px",
        gap: 8,
      }}
    >
      {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
        <div key={c} style={{ width: 13, height: 13, borderRadius: "50%", background: c }} />
      ))}
      <div
        style={{
          flex: 1,
          textAlign: "center",
          color: theme.textDim,
          fontFamily: theme.uiFont,
          fontSize: 15,
          display: "flex",
          justifyContent: "center",
          alignItems: "center",
          gap: 8,
        }}
      >
        claude — LatexTerm
        {zoomBadge && (
          <span
            style={{
              fontSize: 12,
              border: "1px solid rgba(255,255,255,0.25)",
              borderRadius: 5,
              padding: "1px 7px",
            }}
          >
            ⤢ zoomed
          </span>
        )}
        {dotPulse !== undefined && (
          <span
            style={{
              width: 9,
              height: 9,
              borderRadius: "50%",
              background: theme.accentClaude,
              opacity: 0.35 + 0.65 * dotPulse,
              boxShadow: `0 0 ${6 + 6 * dotPulse}px ${theme.accentClaude}`,
            }}
          />
        )}
      </div>
      <div style={{ width: 55 }} />
    </div>
  </div>
);

// ————————————————————————————— Intro: clean desktop, app launches —————————————————————————————
const IntroScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const open = spring({
    frame: frame - 14,
    fps,
    config: { damping: 16, mass: 0.8 },
    durationInFrames: 20,
  });
  const textIn = spring({ frame: frame - 30, fps, config: { damping: 16 } });
  const out =
    frame > durationInFrames - 12 ? (durationInFrames - frame) / 12 : 1;
  return (
    <AbsoluteFill style={{ background: theme.desktop }}>
      <MenuBar />
      <div
        style={{
          position: "absolute",
          width: W,
          height: H,
          opacity: open,
          transform: `scale(${0.9 + 0.1 * open})`,
          transformOrigin: "50% 55%",
        }}
      >
        <WindowChrome />
        <div
          style={{
            position: "absolute",
            left: CBOX.x,
            top: CBOX.y,
            width: CBOX.w,
            height: CBOX.h,
            borderRadius: 10,
            background: theme.paneBg,
            border: `1px solid ${theme.paneBorder}`,
            padding: 12,
          }}
        >
          <ShellSession fontSize={15} />
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          bottom: 70,
          left: 0,
          right: 0,
          textAlign: "center",
          opacity: textIn * out,
          transform: `translateY(${(1 - textIn) * 12}px)`,
          fontFamily: theme.uiFont,
        }}
      >
        <div
          style={{
            fontSize: 34,
            fontWeight: 600,
            letterSpacing: -0.5,
            color: "rgba(255,255,255,0.96)",
          }}
        >
          LatexTerm
        </div>
        <div style={{ fontSize: 18, color: theme.textDim, marginTop: 4 }}>
          A native macOS terminal, built as a cockpit for Claude Code.
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ————————————————————————————— The cockpit scene —————————————————————————————
// Pane 0 is the ORCHESTRATOR: the human gives it one prompt; it opens panes
// via `latexterm new-pane` and prompts each worker via `latexterm send`.
const PANES = [
  {
    boot: 8,
    cwd: "~/dev",
    prompt: "Spin up three agents: landing page, failing api tests, snake game",
    typeStart: 40,
    verb: "Orchestrating",
    tools: [
      {
        at: 118,
        head: "Bash(latexterm new-pane --cwd ~/dev/coffee --exec claude)",
        sub: "pane 2 opened",
        subAfter: 16,
      },
      {
        at: 176,
        head: 'Bash(latexterm send --pane 2 "Create a landing page for a specialty coffee brand")',
        sub: "delivered",
        subAfter: 14,
      },
      {
        at: 262,
        head: "Bash(latexterm new-pane --cwd ~/dev/api --exec claude)",
        sub: "pane 3 opened",
        subAfter: 16,
      },
      {
        at: 322,
        head: 'Bash(latexterm send --pane 3 "Fix the failing tests")',
        sub: "delivered",
        subAfter: 14,
      },
      {
        at: 400,
        head: "Bash(latexterm new-pane --cwd ~/dev/snake --exec claude)",
        sub: "pane 4 opened",
        subAfter: 16,
      },
      {
        at: 438,
        head: 'Bash(latexterm send --pane 4 "Build a playable retro snake game in Python")',
        sub: "delivered",
        subAfter: 14,
      },
    ],
    doneAt: 545,
    doneText: "✔ Three agents running — I'll watch their status",
  },
  {
    boot: 145,
    cwd: "~/dev/coffee",
    prompt: "Create a landing page for a specialty coffee brand",
    pasteAt: 196,
    verb: "Designing",
    tools: [
      { at: 280, head: "Write(index.html)", sub: "Wrote 104 lines to index.html" },
      { at: 430, head: "Write(style.css)", sub: "Wrote 193 lines to style.css" },
    ],
  },
  {
    boot: 280,
    cwd: "~/dev/api",
    prompt: "Fix the failing tests",
    pasteAt: 342,
    verb: "Debugging",
    tools: [
      { at: 400, head: "Bash(pytest -q)", sub: "1 failed, 1 passed — price_with_tax" },
      { at: 470, head: "Update(api.py)", sub: "net * rate → net * (1 + rate)" },
      { at: 520, head: "Bash(pytest -q)", sub: "2 passed in 0.31s" },
    ],
    doneAt: 645,
    doneText: "✔ Tests fixed — 2 passed · 1 file changed",
  },
  {
    boot: 410,
    cwd: "~/dev/snake",
    prompt: "Build a playable retro snake game in Python",
    pasteAt: 452,
    verb: "Building",
    tools: [
      { at: 505, head: "Bash(pip install pygame)", sub: "Done in 4.8s" },
      { at: 535, head: "Write(snake.py)", sub: "Wrote 182 lines to snake.py" },
    ],
  },
] as const;

const CockpitScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cam = camAt(frame, fps);
  const pulse = (Math.sin(frame / 8) + 1) / 2;
  const { cur } = gridAt(frame, fps);
  const fontSize = cur.n >= 4 && cur.zoom === undefined ? 12 : 15;
  const focusIdx = cur.zoom !== undefined ? cur.zoom : cur.n - 1;

  return (
    <AbsoluteFill style={{ background: theme.desktop }}>
      <MenuBar />
      <div
        style={{
          position: "absolute",
          width: W,
          height: H,
          transformOrigin: "0 0",
          transform: `translate(${W / 2 - cam.cx * cam.z}px, ${
            H / 2 - cam.cy * cam.z
          }px) scale(${cam.z})`,
        }}
      >
        <WindowChrome
          dotPulse={frame > 90 ? pulse : undefined}
          zoomBadge={cur.zoom !== undefined}
        />
        {[0, 1, 2, 3, 4, 5].map((i) => {
          const { rect, visible, dim, onTop } = rectAt(i, frame, fps);
          if (!visible) return null;
          const p = PANES[i as 0 | 1 | 2 | 3] as (typeof PANES)[number] | undefined;
          const appear = spring({
            frame: frame - BORN[i],
            fps,
            config: { damping: 15 },
            durationInFrames: 14,
          });
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                left: rect.x,
                top: rect.y,
                width: rect.w,
                height: rect.h,
                borderRadius: 10,
                background: theme.paneBg,
                border:
                  i === focusIdx
                    ? `2px solid ${theme.accent}`
                    : `1px solid ${theme.paneBorder}`,
                padding: 12,
                overflow: "hidden",
                opacity: appear * (1 - dim),
                transform: `scale(${0.9 + 0.1 * appear})`,
                zIndex: onTop ? 10 : 1,
              }}
            >
              {p ? (
                <ClaudeSession
                  boot={p.boot}
                  cwd={p.cwd}
                  prompt={p.prompt}
                  typeStart={"typeStart" in p ? (p as any).typeStart : undefined}
                  pasteAt={"pasteAt" in p ? (p as any).pasteAt : undefined}
                  verb={p.verb}
                  tools={[...p.tools]}
                  doneAt={"doneAt" in p ? (p as any).doneAt : undefined}
                  doneText={"doneText" in p ? (p as any).doneText : undefined}
                  fontSize={fontSize}
                />
              ) : (
                <ShellSession fontSize={fontSize} />
              )}
            </div>
          );
        })}
      </div>

      {/* Direction layer */}
      <ShortcutBadge keys="●" label="One prompt. The rest is delegation." appearFrame={86} hideFrame={140} />
      <ShortcutBadge keys="$" label="The agent opens panes itself — latexterm CLI" appearFrame={150} hideFrame={244} />
      <ShortcutBadge keys="→" label="…and prompts every new agent" appearFrame={330} hideFrame={400} />
      <ShortcutBadge keys="✻" label="One orchestrator. Three workers." appearFrame={465} hideFrame={550} />
      <ShortcutBadge keys="⌘1–9" label="The grid grows with you" appearFrame={565} hideFrame={615} />
      <ShortcutBadge keys="⌘⏎" label="Zoom any pane to full screen" appearFrame={630} hideFrame={705} />
      <NotificationBanner
        title="Claude ist fertig"
        body="Fix the failing tests · 2 passed"
        appearFrame={650}
      />
    </AbsoluteFill>
  );
};

// ————————————————————————————— LaTeX scene —————————————————————————————
// The real use case: Claude explains uni material, formulas arrive as raw
// LaTeX — unreadable — until ⌘L turns on the overlays. Then a scroll pass
// shows them glued to their source lines.
const LATEX_TOGGLE = 190; // ⌘L moment (scene-local frame)

type ExplainBlock =
  | { at: number; kind: "text"; text: string }
  | { at: number; kind: "formula"; raw: string; latex: string; display?: boolean };

const EXPLAIN: ExplainBlock[] = [
  { at: 30, kind: "text", text: "We want to evaluate the Gaussian integral:" },
  {
    at: 46,
    kind: "formula",
    raw: "$$\\int_0^\\infty e^{-x^2}\\,dx$$",
    latex: "\\int_0^\\infty e^{-x^2}\\,dx",
    display: true,
  },
  { at: 72, kind: "text", text: "The trick: square it and switch to polar coordinates —" },
  {
    at: 92,
    kind: "formula",
    raw: "$I^2 = \\int_0^\\infty\\!\\int_0^\\infty e^{-(x^2+y^2)}\\,dx\\,dy = \\int_0^{\\pi/2}\\!\\int_0^\\infty e^{-r^2}\\,r\\,dr\\,d\\theta$",
    latex: "I^2 = \\int_0^\\infty\\!\\!\\int_0^\\infty e^{-(x^2+y^2)}\\,dx\\,dy = \\int_0^{\\pi/2}\\!\\!\\int_0^\\infty e^{-r^2}\\,r\\,dr\\,d\\theta",
  },
  { at: 122, kind: "text", text: "The r makes both factors elementary, so:" },
  {
    at: 140,
    kind: "formula",
    raw: "$$I^2 = \\frac{\\pi}{4} \\;\\Rightarrow\\; I = \\frac{\\sqrt{\\pi}}{2}$$",
    latex: "I^2 = \\frac{\\pi}{4}\\;\\Rightarrow\\; I = \\frac{\\sqrt{\\pi}}{2}",
    display: true,
  },
];

const LatexScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pulse = (Math.sin(frame / 8) + 1) / 2;
  // scroll pass after the reveal: drift down, settle, nudge back up
  const scrollY = interpolate(
    frame,
    [252, 292, 316, 356],
    [0, -118, -118, -34],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
  );
  const lit = frame >= LATEX_TOGGLE;
  return (
    <AbsoluteFill style={{ background: theme.desktop }}>
      <MenuBar />
      <WindowChrome dotPulse={frame < 160 ? pulse : undefined} />
      <div
        style={{
          position: "absolute",
          left: CBOX.x,
          top: CBOX.y,
          width: CBOX.w,
          height: CBOX.h,
          borderRadius: 10,
          background: theme.paneBg,
          border: `2px solid ${theme.accent}`,
          padding: "12px 16px",
          ...MONO,
          fontSize: 16,
          lineHeight: 1.85,
          color: theme.text,
          overflow: "hidden",
        }}
      >
        <div style={{ transform: `translateY(${scrollY}px)` }}>
          <div
            style={{
              background: "rgba(255,255,255,0.07)",
              padding: "2px 8px",
              borderRadius: 4,
              marginBottom: 6,
            }}
          >
            <span style={{ color: theme.textDim }}>{">"} </span>
            Explain how to solve the Gaussian integral
          </div>
          {EXPLAIN.map((b, i) => {
            if (frame < b.at) return null;
            if (b.kind === "text") {
              return (
                <div key={i} style={{ marginTop: 8 }}>
                  {b.text}
                </div>
              );
            }
            const flip = LATEX_TOGGLE + 4 + i * 3;
            const showRendered = frame >= flip;
            return (
              <div
                key={i}
                style={{
                  marginTop: 8,
                  display: "flex",
                  justifyContent: b.display ? "center" : "flex-start",
                }}
              >
                {showRendered ? (
                  <Formula
                    latex={b.latex}
                    display={b.display}
                    appearFrame={flip}
                    fontSize={b.display ? 24 : 19}
                  />
                ) : (
                  <span style={{ color: "#d7ba7d", wordBreak: "break-all" }}>
                    {b.raw}
                  </span>
                )}
              </div>
            );
          })}
          {frame >= 168 && (
            <div style={{ color: theme.textDim, marginTop: 12 }}>
              ✻ Done — ask me anything else about it.
            </div>
          )}
          {frame < 168 && frame >= 34 && <Spinner start={20} verb="Explaining" />}
        </div>
      </div>
      <ShortcutBadge
        keys="$…$"
        label="Raw LaTeX. Not exactly readable."
        appearFrame={150}
        hideFrame={LATEX_TOGGLE - 4}
      />
      <ShortcutBadge
        keys="⌘L"
        label="Formula overlays: on"
        appearFrame={LATEX_TOGGLE}
        hideFrame={244}
      />
      <ShortcutBadge
        keys="↕"
        label="Overlays stay glued to their source — even while scrolling"
        appearFrame={256}
      />
    </AbsoluteFill>
  );
};

// ————————————————————————————— Assembly —————————————————————————————
export const PolishedDemo: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: theme.desktop }}>
      <Series>
        <Series.Sequence durationInFrames={80}>
          <IntroScene />
        </Series.Sequence>
        <Series.Sequence durationInFrames={760}>
          <CockpitScene />
        </Series.Sequence>
        <Series.Sequence durationInFrames={55}>
          <TitleCard small title="And it renders LaTeX. Live." />
        </Series.Sequence>
        <Series.Sequence durationInFrames={380}>
          <LatexScene />
        </Series.Sequence>
        <Series.Sequence durationInFrames={80}>
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
