// One entry per README clip. Times are take seconds (rig/cut.py prints the scenes; cut points
// inside scenes were read off contact sheets, rig/sheet.sh). Pane rects are window points.
import type { ClipSpec, Rect } from "./Clip";

// Pane geometry (window points): 2 panes → 0–752 | 760–1512; 3 panes → 0–500 | 508–1004 | 1012–1512;
// panes start below the title bar at y≈60. The camera fits a rect on both axes (5 % margin), so a rect
// that spans a whole pane width keeps the pane whole. Prompt boxes of a single pane span the full width:
// never zoom on them (rect null).
const SKETCH: Rect = { x: 760, y: 150, w: 752, h: 480 };
const LEFT_PROMPT: Rect = { x: 0, y: 470, w: 752, h: 478 }; // left pane of two, lower half
const PDF_LOW: Rect = { x: 760, y: 420, w: 752, h: 471 };
export const SPECS: Record<string, ClipSpec> = {
  hero: {
    parts: [
      { take: "hero2", scene: 1, range: [52.0, 57.5] }, // ask
      { take: "hero2", scene: 1, range: [66.95, 70.0] }, // the answer lands already rendered
      { take: "hero2", scene: "plot" }, // web pane appears
      { take: "hero3", scene: "slider" },
    ],
    speed: [
      { take: "hero2", from: 52.7, to: 57.5, rate: 1.7 },
      { take: "hero2", from: 116.6, to: 121.8, rate: 1.7 },
    ],
    cams: [
      // no zoom on the web pane: its stats at the bottom would be cut (the pane has to stay whole)
    ],
    captions: [
      { take: "hero2", at: 52.8, until: 116.6, text: "Ask in plain words. Math renders as math." },
      { take: "hero2", at: 116.6, until: 35.3, untilTake: "hero3", text: "Claude opens what it builds, right beside you." },
      { take: "hero3", at: 35.3, text: "Live, local, interactive." },
    ],
  },
  scratchpad: {
    parts: [
      { take: "scratch2", scene: "open" },
      { take: "scratch2", scene: "sketch" },
      { take: "scratch2", range: [25.0, 26.05] }, // ➤
      { take: "scratch2", range: [27.6, 28.8] }, // sketch lands in the prompt
      { take: "scratch2", scene: "hand", range: [39.6, 70] },
    ],
    speed: [
      { take: "scratch2", from: 5.4, to: 25.8, rate: 1.8 },
      { take: "scratch2", from: 39.6, to: 44.9, rate: 1.6 },
    ],
    cams: [
      { take: "scratch2", at: 5.6, rect: SKETCH },
      { take: "scratch2", at: 25.1, rect: null },
      { take: "scratch2", at: 39.7, rect: LEFT_PROMPT },
      { take: "scratch2", at: 61.4, rect: null },
      { take: "scratch2", at: 63.0, rect: SKETCH },
    ],
    captions: [
      { take: "scratch2", at: 2.7, until: 25.0, text: "Sketch it — badly is fine." },
      { take: "scratch2", at: 25.0, until: 61.3, text: "Hand it over with ➤." },
      { take: "scratch2", at: 61.3, text: "Claude draws it clean, right on the pad." },
    ],
  },
  preview: {
    parts: [
      { take: "preview1", scene: "compile" },
      { take: "preview1", range: [58.0, 61.0] },
      { take: "preview1", range: [72.8, 77.6] },
      { take: "preview2", scene: "fix" },
    ],
    speed: [
      { take: "preview1", from: 2.7, to: 6.4, rate: 1.7 },
      { take: "preview1", from: 72.8, to: 77.6, rate: 1.5 },
    ],
    cams: [
      { take: "preview1", at: 58.2, rect: PDF_LOW },
      { take: "preview2", at: 2.3, rect: null },
      { take: "preview2", at: 21.5, rect: PDF_LOW },
    ],
    captions: [
      { take: "preview1", at: 2.8, until: 58.0, text: "Compile — the PDF opens next to the chat." },
      { take: "preview1", at: 58.0, until: 2.3, untilTake: "preview2", text: "Mark a spot, add a note, send." },
      { take: "preview2", at: 2.3, text: "Fixed, recompiled, reloaded in place." },
    ],
  },
  web: {
    parts: [
      { take: "web2", scene: "serve" },
      { take: "web2", scene: "pick" },
    ],
    speed: [
      { take: "web2", from: 2.7, to: 6.4, rate: 1.7 },
      { take: "web2", from: 33.0, to: 38.1, rate: 1.6 },
    ],
    cams: [
      { take: "web2", at: 30.5, rect: { x: 1012, y: 150, w: 500, h: 450 } }, // the pale button, its pane whole
      { take: "web2", at: 33.2, rect: { x: 0, y: 560, w: 500, h: 388 } }, // prompt of the left pane
      { take: "web2", at: 54.6, rect: null },
      { take: "web2", at: 56.5, rect: { x: 1012, y: 150, w: 500, h: 450 } }, // the new button
    ],
    captions: [
      { take: "web2", at: 2.8, until: 30.4, text: "Server and site, each in its own pane." },
      { take: "web2", at: 30.4, until: 54.5, text: "⌥-click an element, ⇧⌘⏎ hands it to Claude." },
      { take: "web2", at: 54.5, text: "The change lands live." },
    ],
  },
  agents: {
    parts: [{ take: "agents1", scene: "delegate2" }],
    cams: [
      { take: "agents1", at: 92.6, rect: null },
    ],
    speed: [{ take: "agents1", from: 92.5, to: 100.8, rate: 1.8 }],
    captions: [
      { take: "agents1", at: 92.6, until: 104.5, text: "Claude starts Claudes — side by side." },
      { take: "agents1", at: 104.5, text: "Every pane reports its state in the title bar." },
    ],
  },
  home: {
    parts: [
      { take: "home1", range: [3.2, 5.5] },
      { take: "home1", range: [15.4, 18.0] },
      { take: "home1", scene: "resume" },
      { take: "home1", range: [102.4, 104.6] },
      { take: "home1", range: [115.2, 119.5] },
    ],
    cams: [
      { take: "home1", at: 102.5, rect: { x: 700, y: 60, w: 812, h: 420 } }, // the search palette
      { take: "home1", at: 115.3, rect: null },
    ],
    captions: [
      { take: "home1", at: 3.3, until: 44.7, text: "Home: every project, every session." },
      { take: "home1", at: 44.7, until: 102.4, text: "Resume right where you left off." },
      { take: "home1", at: 102.4, text: "Search sessions, open them side by side." },
    ],
  },
};
