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
                          One MathOverlayView (WKWebView + KaTeX)
                          per detected formula, positioned via
                          grid coords → pixel coords
```

- **Terminal**: vendored fork of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) at `SwiftTermLocal/`. Fork adds a public `extraLineSpacing` property on `TerminalView` so we can introduce vertical gaps between rows without modifying glyph rendering.
- **Detection**: per-row buffer text scan after every SwiftTerm `rangeChanged` update. Single-line delimited segments only (no wrap support yet).
- **Rendering**: each formula gets its own `WKWebView` loading KaTeX offline (CSS + JS + woff2 fonts bundled). Backed by a tight 1-cell background view so the raw `$..$` text is covered, and a 2-cell tall foreground that lets fraction bars / sums extend symmetrically above and below the source row. Formulas that still overflow scale themselves down via CSS `transform: scale()`.
- **Overlay lifecycle**: keyed by `(viewportRow, startCol, body)`. On rescan, new keys get a fresh overlay, missing keys remove their overlay. Font-size changes invalidate all overlays so KaTeX re-renders at the new size.

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
| `⌘+` / `⌘=` | Increase font size by 1pt |
| `⌘-` | Decrease font size by 1pt |
| `⌘0` | Reset font size to 13pt (default) |
| `⌘L` | Toggle formula overlays on/off |
| `⌘⇧+` / `⌘⇧-` | Increase/decrease line spacing by 2px |
| `⌘⇧0` | Reset line spacing to default (8px) |
| `⌥⌘+` / `⌥⌘-` | Increase/decrease formula render scale by 0.1× |
| `⌥⌘0` | Reset formula scale to 1.0× |

Font size is persisted in `UserDefaults` under `LatexTerm.fontSize` (range 6–48pt) and restored on next launch.

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
  TerminalContainer.swift    NSViewRepresentable wrapping the terminal
  FormulaSettings.swift      Settings singleton (UserDefaults + NotificationCenter)
  Latex/
    LatexTerminalView.swift  LocalProcessTerminalView subclass: overlay host,
                              font-size shortcuts, range-change forwarding
    OverlayController.swift  Per-rescan diff of detected formulas → overlay views
    LaTeXDetector.swift      Delimiter-based formula extraction
    MathOverlayView.swift    Single WKWebView + KaTeX overlay
  katex/                     Bundled KaTeX assets (CSS, JS, woff2)
  Assets.xcassets/
  Info.plist
SwiftTermLocal/              Vendored SwiftTerm fork (patched cellHeight)
  Sources/SwiftTerm/...
  Package.swift              Library-only manifest (no executables, no tests)
```

## Known limitations

- **Single-line formulas only.** Formulas that wrap across rows are not detected.
- **No display-mode `$$..$$` typesetting.** All formulas render in inline mode; display mode delimiters are accepted as boundaries but ignored as a layout hint to keep overlays a fixed height.
- **One `WKWebView` per formula.** Cheap in our typical workload but unbounded screens with many formulas would benefit from pooling.
- **No theme sync after launch.** Background color is captured at overlay creation. Changing terminal background at runtime won’t update existing overlays until the formula is re-rendered. Formula foreground color is now user-controlled via the "Formeln" menu.

## License

KaTeX assets are MIT licensed (bundled under `LatexTerm/katex/`). SwiftTerm is MIT licensed (vendored at `SwiftTermLocal/`). Project code is unlicensed for now.
