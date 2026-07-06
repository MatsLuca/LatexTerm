# demo-video

Remotion sources for the README demo. Two compositions:

- **`Live`** (the real one): a **hybrid cut of an actual screen recording** — a Claude
  session inside LatexTerm orchestrates panes via the `latexterm` CLI, real agents do
  real work, and Remotion adds the direction on top (camera zooms, freeze frames,
  statement cards, cropping away statuslines/browser chrome).
- **`Demo`**: an earlier fully-synthetic take — the terminal re-created in React with
  real KaTeX. Kept as a reference for scripted/no-recording demos.

## Commands

```bash
npm install
npm run studio                                  # preview with timeline scrubbing
npx remotion render Live out/live.mp4           # the hybrid cut
# README GIF (gifski gives ~4x better size/quality than --codec=gif):
ffmpeg -i out/live.mp4 -vf "fps=10,scale=756:-2" /tmp/f_%04d.png
gifski --fps 10 --quality 65 -o out/live_readme.gif /tmp/f_*.png
```

## Re-recording the footage

`scripts/choreo.sh` re-runs the whole live take unattended: it locates the LatexTerm
window (`scripts/winbounds.swift`), starts `screencapture -v` (150 s), opens three panes
via the `latexterm` CLI (`yolo --model sonnet`), and two-stage-sends the showcase prompts
("Create a landing page …", "Fix the failing tests", "Build a … snake game"). Demo
folders live in `~/Documents/9_Temp/demo-{coffee,api,snake}`; `demo-api` needs its
intentionally-failing test restored (`git checkout . && git clean -fd`) before a re-take.
Output lands in `recordings/take1.mov`; transcode a 30 fps proxy + freeze stills into
`public/` (see `src/LiveDemo.tsx` header comment for the coordinate space).

## Where things live

- `src/LiveDemo.tsx` — the cut: shot list (source timestamps), camera targets (`CAM`),
  statements. Comp is 1512×772 — the bottom 176pt of the 948pt-tall window (statuslines)
  fall off at zoom 1.
- `src/DemoVideo.tsx` + `src/components/` — the synthetic storyboard & its primitives.
- `src/theme.ts` — colors/fonts, lifted from the app (`LatexTermApp.swift`).
- `public/` — 30 fps proxy (`take1.mp4`) + freeze-frame stills; `recordings/` — raw takes
  (git-ignore-worthy, ~150 MB each).

## Notes

- Rebranding (#31): names/strings appear in `LiveDemo.tsx`/`DemoVideo.tsx` title cards
  and captions — one search-and-replace away.
- The final README asset goes to `docs/demo.webp` (animated WebP — full 24-bit color,
  unlike GIF's 256-color palette which bands/puddles on the desktop gradient). Encode:
  `ffmpeg -i out/polished.mp4 -vf fps=25 f_%04d.png && img2webp -o docs/demo.webp -d 40 -lossy -q 88 -m 6 f_*.png`
  (single-threaded, takes ~15 min — that's normal).
- Footage quirks to keep in mind: the orchestrator pane (left) shows the session's German
  status text; prompt zooms show the July-2026 "Fable 5 is back" banner; the Safari beat
  is cropped below the bookmarks bar.
