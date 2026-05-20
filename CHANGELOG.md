# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial macOS app: SwiftUI `WindowGroup` hosting a `LocalProcessTerminalView` via `NSViewRepresentable`, launching the user's login shell from `/etc/passwd`.
- SwiftTerm integration as Swift Package dependency (initially remote, later vendored).
- Live LaTeX overlay pipeline:
  - `LaTeXDetector` for delimiter-based scan of `$...$`, `$$...$$`, `\(...\)`, `\[...\]` segments, with backslash-escape handling.
  - `OverlayController` rescanning all visible buffer rows after every SwiftTerm `rangeChanged` event, diffing overlays by `(row, startCol, body)` key.
  - `MathOverlayView` rendering a single formula in a `WKWebView` with bundled KaTeX assets (CSS + JS + woff2 fonts). Opaque background view covers exactly the source row; transparent foreground extends above and below to fit tall constructs (fractions, square roots, sums).
- Cap-and-scale strategy for overflow: KaTeX-rendered content larger than 2× cell height is shrunk via CSS `transform: scale()` so overlays never exceed a fixed envelope and never overlap distant rows.
- Vendored SwiftTerm fork at `SwiftTermLocal/` exposing:
  - `public var extraLineSpacing: CGFloat` on `TerminalView` — extra pixels added to each cell's height on top of the font's natural line metrics. Triggers `resetFont()` on change.
  - `public var lineCellSize: CGSize` — read access to the computed cell dimensions for external overlay placement.
  - `Package.swift` reduced to a library-only target (no executables, no tests, no external deps).
- `extraLineSpacing = 8` applied by default for visible breathing room between text rows and overlay headroom.
- Keyboard shortcuts for font size, persisted in `UserDefaults`:
  - `⌘+` / `⌘=` — increase 1pt
  - `⌘-` — decrease 1pt
  - `⌘0` — reset to 13pt
  - Range clamped to 6–48pt. Overlays are invalidated and re-rendered when the font size changes.

### Notes
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) — required for PTY/process spawn.
- Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) needs to be installed; SwiftTerm ships Metal shaders even though the CPU renderer is used.
