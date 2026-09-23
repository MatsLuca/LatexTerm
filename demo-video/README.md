# demo-video

The README clips (`docs/media/*.webp`) are **real screen recordings** of LatexTerm with real Claude
sessions. Remotion only edits them: it drops the waiting while Claude thinks, moves the camera to what
matters and adds a caption. Older compositions (`Polished`, `Live`, `Demo`) are the synthetic takes from July.

## Pipeline

```
rig/take.sh start NAME      record the demo window (rig/record, ScreenCaptureKit)
                            + log pane states every 100 ms (rig/statelog.py)
rig/mark.sh in:SCENE / out  stage directions into the same log
rig/say.sh / input / sketch.py / wait.sh    act like a person: type, click, drag, draw, wait for Claude
rig/take.sh stop
rig/cut.py recordings/takes/NAME   → NAME.cuts.json: per scene the kept segments — `working` stretches
                                     shrink to their start, pane births and the finished answer
rig/sheet.sh TAKE FROM TO FPS OUT  contact sheet, for cut points inside a scene
src/clips/specs.ts          one ClipSpec per clip: parts (take + scene/range), speed-ups, camera, captions
npx remotion render clip-NAME out/clip-NAME.mp4
rig/webp.sh NAME 1400 15 74 → docs/media/NAME.webp (animated WebP, loops on GitHub)
```

Proxies for Remotion: `ffmpeg -i recordings/takes/NAME.mov -c:v libx264 -crf 18 -g 15 -pix_fmt yuv420p
public/takes/NAME.mp4` plus `NAME.cuts.json` next to it. `rig/record` and `rig/input` are built with
`swiftc -O -o record record.swift` (same for `input`); they need Screen Recording and Accessibility for the
terminal that runs them.

## The stage

Recordings are public, so they run on a clean stage, not on anyone's real setup:

- A separate Claude profile (`CLAUDE_CONFIG_DIR`, `claudeMdExcludes` for the real `~/.claude`), its own short
  `CLAUDE.md` (short answers, formulas on their own `$$` line) and only the `latexterm` MCP server.
- Demo projects outside any folder with its own `CLAUDE.md` (Claude loads ancestor `CLAUDE.md` files).
- The demo runs in its own window (Window → Move Tab to New Window); `rig/newtab.sh` sets that up.
- For Home, `projekte` points at a shim that runs the launcher with a demo `HOME` and `PROJEKTE_CONFIG`.

Scenes are English; the app UI is German.
