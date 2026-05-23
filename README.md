# LatexTerm

Native macOS terminal that renders LaTeX formulas live as KaTeX overlays — positioned directly over the source characters between `$...$`, `$$...$$`, `\(...\)` and `\[...\]`.

## Why

The predecessor project [LatexTerminalLive](https://github.com/MatsLuca/LatexTerminalLive) used ScreenCaptureKit + Vision OCR to read Ghostty's output. Worked, but OCR was unreliable (greek glyphs, fractions, subtle artifacts). This project is a full terminal emulator instead — we own the text stream, the grid model, and the render pipeline, so formula positions come from the cell grid directly. No OCR.

## How it works

```
PTY (zsh) → SwiftTerm VT parser → Buffer grid
                                    ↓
                          OverlayController scans visible rows
                                    ↓
                          LaTeXDetector finds delimited formulas
                                    ↓
                          One FormulaLayer (single WKWebView + KaTeX)
                          renders every formula as a positioned <div>,
                          grid coords → pixel coords
```

- **Terminal**: vendored fork of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) at `SwiftTermLocal/`. Fork adds a public `extraLineSpacing` property on `TerminalView` so we can introduce vertical gaps between rows without modifying glyph rendering.
- **Detection**: per-row buffer text scan after every SwiftTerm `rangeChanged` update. Inline segments (`$..$`, `\(..\)`) and single-line `$$..$$` / `\[..\]` are found line by line; **multi-line display blocks** (`$$` / `\[` … `\]` with each delimiter alone on its own line) are detected across rows by `LaTeXDetector.findBlocks`. Requiring the delimiters to stand alone keeps prose `$$` (or the shell PID `$$`) from forming false blocks. Wrapped *inline* formulas are still not detected.
- **Rendering**: a single `FormulaLayer` (one `WKWebView`) hosts *all* formulas — KaTeX is loaded offline once (CSS + JS + woff2 fonts bundled) and each formula is an absolutely-positioned `<div>`. Inline formulas get a tight 1-cell background box over the raw `$..$` text and scale (`transform: scale()`) to fit entirely within that single row so they never bleed into neighbouring lines. **Display formulas render with true `displayMode`** and are centred in both axes: single-line `$$..$$` is fit into its row, while a multi-line block spans its full source row range (the rows are already reserved by the source text) so the formula gets real vertical room.
- **Hover preview**: large formulas shrink to fit their row, so a hover "view mode" (`FormulaPreview`) blows the formula back up at full size when the pointer rests over it. Hitboxes start as the source-text box and are tightened to the real rendered bounds reported back from the WebView; hover tracking is mouse-move only, so plain selection/scroll still pass through to the terminal.
- **Click to pin + copy**: clicking a formula pins the preview and reveals three buttons — **LaTeX** copies the raw expression, **Lesbar** copies a readable Unicode-math form (e.g. `(-b ± √(b²-4ac))/(2a)`, via `LaTeXReadable`), and **Bild** copies the formula as a PNG image — a dark rounded "chip" composed from a `takeSnapshot` of the (already-painted) preview WebView at retina resolution via `FormulaImageRenderer`. Clicking away, `Esc`, scrolling, or new output dismisses it. Two local `NSEvent` monitors drive pinning/dismissal; `OverlayHost.hitTest` lets clicks land *inside* the pinned panel (the buttons) while staying click-through everywhere else.
- **Overlay lifecycle**: keyed by `(absoluteBufferRow, startCol, body)` where `absoluteBufferRow = viewportRow + buffer.yDisp`. On rescan the desired state is sent to the layer as JSON and reconciled in JS (`sync()`): new keys create a `<div>`, missing keys are removed, surviving keys are only repositioned (no KaTeX re-render). Binding the key to the absolute scrollback row means scrolling repositions overlays instead of destroying and rebuilding them. Font-size and settings changes trigger `clearAll()` so KaTeX re-renders at the new size/colors.
- **Split-screen tiling**: `⌘T` adds a pane, each with its own login shell and its own `OverlayController` (independent formula overlays). `TerminalSplitView` lays panes out by direct frame math (no `NSSplitView`), choosing the grid shape from the *window's* width **and** height: it picks the row count whose resulting cell aspect ratio is closest to a target (`idealCellAspect ≈ 0.82`), so a wide window stays single-row longer (up to ~3 across) and wraps into a balanced grid as it fills (4 → 2×2, then toward 3×3). Rows are equal height and each row divides its width independently (top-heavy masonry: e.g. 5 panes → 3 over 2). An 8px strut between cells shows the slightly-lighter container background. `⌘W` closes the focused pane, `⌘1…9` grows to N panes.
- **Flicker-free scrolling**: scrolling is a rapid sequence of static states, and repositioning the out-of-process WebView on every intermediate step flickers. SwiftTerm's `scrolled` event drives a separate path (`onScrolled` → `scheduleReposition`) that hides the overlay layer on the first scroll event and arms an idle timer. While events keep flowing (including trackpad momentum) the overlays stay hidden; ~150 ms after the last event the layer is repositioned and revealed only once the WebView has painted the new positions (gated on the first `onBounds` report). The 30 ms `scheduleRescan` debounce now only serves terminal output, resize, and settings changes.

## Requirements

- macOS 14+
- Xcode 26+ with Metal Toolchain installed (`xcodebuild -downloadComponent MetalToolchain` — SwiftTerm ships Metal shaders even when the Metal renderer is off)

## Build

Open in Xcode:

```bash
open LatexTerm.xcodeproj
```

`Cmd+R` to run. App Sandbox is intentionally disabled — the terminal needs free PTY/process spawn rights.

Or build from CLI:

```bash
xcodebuild -project LatexTerm.xcodeproj -scheme LatexTerm -configuration Debug \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
open .build/Build/Products/Debug/LatexTerm.app
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘T` | New terminal pane (auto-tiled into the grid) |
| `⌘W` | Close the focused pane (closes the window if it was the last) |
| `⌘1` … `⌘9` | Grow the grid to N panes (grow-only — never closes panes) |
| `⌘+` / `⌘=` | Increase font size by 1pt (all panes) |
| `⌘-` | Decrease font size by 1pt (all panes) |
| `⌘0` | Reset font size to 13pt (default, all panes) |
| `⌘L` | Toggle formula overlays on/off |
| `⌘⇧+` / `⌘⇧-` | Increase/decrease line spacing by 2px |
| `⌘⇧0` | Reset line spacing to default (8px) |
| `⌥⌘+` / `⌥⌘-` | Increase/decrease formula render scale by 0.1× |
| `⌥⌘0` | Reset formula scale to 1.0× |

Font size is persisted in `UserDefaults` under `LatexTerm.fontSize` (range 6–48pt) and restored on next launch. It is **global**: changing it in one pane updates all panes (broadcast via the `LatexTerminalView.fontDidChange` notification).

All formula settings (**color**, **enabled**, **line spacing**, **scale**) are also persisted and restored via `FormulaSettings` in `UserDefaults`.

## Testing formulas

`echo` in zsh interprets escapes like `\f` and breaks LaTeX in output. Use `printf` or a here-doc instead:

```sh
printf '%s\n' '$E=mc^2$ und $\int_0^\infty e^{-x^2}dx$'
cat <<'EOF'
Bruch: $\frac{n(n+1)(2n+1)}{6}$
Tief: $\frac{x+1}{\frac{a+b}{c-d}}$
EOF
```

## Project layout

```
LatexTerm.xcodeproj/         App project (SwiftUI lifecycle)
LatexTerm/
  LatexTermApp.swift         @main App definition + "Formeln" CommandMenu
  TerminalContainer.swift    NSViewRepresentable wrapping the split container
  TerminalSplit.swift        TerminalPane (shell + overlays per tile) +
                              TerminalSplitView (auto-tiling grid layout)
  FormulaSettings.swift      Settings singleton (UserDefaults + NotificationCenter)
  Latex/
    LatexTerminalView.swift  LocalProcessTerminalView subclass: overlay host,
                              font/split/close/grid shortcuts, range-change forwarding
    OverlayController.swift  Per-rescan diff of detected formulas → JSON sync
    LaTeXDetector.swift      Delimiter-based formula extraction
    LaTeXReadable.swift      LaTeX → readable Unicode-math converter (copy "Lesbar")
    FormulaImageRenderer.swift  Composes a formula snapshot into a PNG chip (copy "Bild")
    MathOverlayView.swift    FormulaLayer: shared WKWebView + FormulaPreview (pin/copy)
  katex/                     Bundled KaTeX assets (CSS, JS, woff2)
  Assets.xcassets/
  Info.plist
SwiftTermLocal/              Vendored SwiftTerm fork (patched cellHeight)
  Sources/SwiftTerm/...
  Package.swift              Library-only manifest (no executables, no tests)
```

## Known limitations

- **No wrapped-inline detection.** Inline formulas (`$..$`, `\(..\)`) must fit on one row; if they wrap across rows they are not detected. Multi-line *display* blocks (`$$` / `\[` … `\]`) are supported, but only in canonical form with each delimiter alone on its own line — a block whose delimiters share a line with other content is not detected.
- **Display mode `$$..$$` / `\[..\]` is rendered** with true KaTeX `displayMode`. Single-line display formulas are scaled into their row (so they stay one line tall); multi-line blocks span their source row range.
- **No theme sync after launch.** Background color is captured per rescan into the layer config. Changing the terminal background at runtime updates formula backgrounds on the next rescan, but is not pushed live. Formula foreground color is user-controlled via the "Formeln" menu.

## License

KaTeX assets are MIT licensed (bundled under `LatexTerm/katex/`). SwiftTerm is MIT licensed (vendored at `SwiftTermLocal/`). Project code is unlicensed for now.
