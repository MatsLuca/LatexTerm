# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

**LatexTerm** — a native macOS terminal emulator that renders LaTeX formulas live as KaTeX
overlays, positioned directly over the source characters between `$...$`, `$$...$$`, `\(...\)`,
`\[...\]`. Successor to LatexTerminalLive (which used ScreenCaptureKit + Vision OCR). Here we
*own* the terminal: a vendored SwiftTerm fork gives us the VT parser, the buffer grid, and exact
cell metrics, so formula positions come from grid coordinates — no OCR.

## Build & run

No CLI dev workflow beyond `xcodebuild`; normally open in Xcode and `Cmd+R`.

```bash
open LatexTerm.xcodeproj                       # then Cmd+R

# CLI build:
xcodebuild -project LatexTerm.xcodeproj -scheme LatexTerm -configuration Debug \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
open .build/Build/Products/Debug/LatexTerm.app
```

- **Requires macOS 14+, Xcode 26+ with Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`).
  SwiftTerm bundles `Shaders.metal` as a processed resource even though the CPU renderer is used;
  a missing Metal toolchain breaks the build.
- **App Sandbox is intentionally OFF** (`ENABLE_APP_SANDBOX = NO`). The terminal needs unrestricted
  PTY/process-spawn rights. Do not re-enable it.
- **Tests**: the `LatexTermTests` target is a *logic* unit-test bundle (no test host → the app
  never launches, no PTY/SwiftTerm/Metal needed for the bundle itself). It compiles the two pure
  source files (`LaTeXDetector.swift`, `LaTeXReadable.swift`) directly and asserts against
  fixture tables. Run with
  `xcodebuild test -project LatexTerm.xcodeproj -scheme LatexTerm -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
  The target was wired in via `scripts/add_test_target.rb` (the app target is a
  `PBXFileSystemSynchronizedRootGroup`, so adding it by GUI is awkward); the script is idempotent.
- `SwiftTermLocal/Package.swift` is reduced to a library-only manifest (no executables, no tests,
  no external deps).

## Testing formulas in the running terminal

zsh `echo` interprets escapes like `\f` and mangles LaTeX. Use `printf` or a here-doc:

```sh
printf '%s\n' '$E=mc^2$ und $\int_0^\infty e^{-x^2}dx$'
cat <<'EOF'
Bruch: $\frac{n(n+1)(2n+1)}{6}$
EOF
```

## Architecture

Pipeline: **PTY (login shell) → SwiftTerm VT parser → buffer grid → OverlayController scans
visible rows → LaTeXDetector extracts delimited formulas → one shared FormulaLayer (single
WKWebView + KaTeX) renders each as a positioned `<div>`**, grid coords → pixel coords.

### Files (`LatexTerm/`)

| File | Role |
|---|---|
| `LatexTermApp.swift` | `@main`; `WindowGroup` + "Terminal" `CommandMenu` (toggle, color, line spacing, scale) + `Settings`-Szene (⌘,). Forces `.dark`, dark `#171414` bg. |
| `SettingsView.swift` | Natives Einstellungen-Fenster (⌘,): alle Formel-/Terminal-Optionen als Form mit Live-Wert-Slidern & SwiftUI-ColorPickern. Schreibt über dieselben Pfade wie die Menü-Shortcuts (`FormulaSettings` bzw. `fontDidChange`-Broadcast) — keine zweite Wahrheit. |
| `TerminalContainer.swift` | 13-line `NSViewRepresentable` shim: hands the window content to `TerminalSplitView`. All real logic lives in `TerminalSplit.swift`. |
| `TerminalSplit.swift` | `TerminalPane` (per-tile shell process + `OverlayController` + settings observer; spawns the user's login shell from `/etc/passwd` via `getpwuid_r` with per-child spawn CWD, #20; focused-pane window title, adaptive-accent contrast analysis), `PaneContainerView` (Kachel-Hülle: Fokus-Rahmen/Dimmung + 4px Content-Inset — SwiftTerm zeichnet ab x=0; Fokus-Rahmen nur bei ≥2 Kacheln; Rundung nur an Innen-Steg-Ecken via `maskedCorners`, außen übernimmt die Fenster-Rundung) and `TerminalSplitView` (auto grid/masonry tiling, ⌘T/⌘W/⌘1–9, focus dimming, vibrancy gaps, ⌘T CWD inheritance #8, session restore #11). |
| `SessionStore.swift` | Session snapshot (#11): pane CWDs as JSON in `~/Library/Application Support/LatexTerm/session.json`; corrupt/missing → default layout. |
| `FormulaSettings.swift` | `ObservableObject` singleton. Persists color/enabled/lineSpacing/scale in `UserDefaults`; broadcasts `FormulaSettings.didChange` via `NotificationCenter`. `FormulaColorProxy` bridges `NSColorPanel`'s ObjC target/action. |
| `Latex/LatexTerminalView.swift` | `LocalProcessTerminalView` subclass. Hosts `OverlayHost`, overrides `rangeChanged`/`scrolled` to fire callbacks, handles `⌘+/-/0` font shortcuts (persisted as `LatexTerm.fontSize`, 6–48pt), ⌘F find bar (#9), Cmd-click link resolution, appearance-change rescan (#12). Also exposes an `AXTextArea` role whose `setAccessibilityValue` writes straight to the PTY — dictation support (SuperWhisper etc.), see SECURITY.md. |
| `Latex/FormulaImageRenderer.swift` | Composes the shareable "chip" image (rounded dark bg + padding) from a preview-WebView snapshot; PNG pasteboard + PNG data for the Markdown data-URI export (#5). |
| `Latex/OverlayController.swift` | The brain. Per-rescan diff of detected formulas → JSON `sync()`. Hover/click/pin/Esc handling via local `NSEvent` monitors. Scroll repositioning. |
| `Latex/LaTeXDetector.swift` | Pure delimiter scan of one line → `[LaTeXHit]` (body, startCol, endCol, displayMode). Handles backslash-escaping + brace-aware closing. `findWrapped(rows:continues:)` reconstructs soft-wrapped logical lines → `[LaTeXWrappedHit]` (grid-projected, multi-row spans). |
| `Latex/MathOverlayView.swift` | `FormulaLayer` (the shared WKWebView + its JS) and `FormulaPreview` (the hover/pin popover: LaTeX/Lesbar/Bild/PDF/MD export buttons #5 + inline edit loop ✎ #7). |
| `Latex/LaTeXReadable.swift` | Offline recursive LaTeX → Unicode-math converter (`\frac`→`(a)/(b)`, `\sqrt`→`√`, super/subscripts, greek, `\mathbb`→ℝ…) for the "Lesbar" copy button. |
| `katex/` | Bundled KaTeX (CSS + JS + woff2 fonts), loaded offline with `baseURL: Bundle.main.resourceURL`. |

### Single-WebView render contract

There is **one** `FormulaLayer` WKWebView for *all* formulas (not one per formula). It loads KaTeX
once; each formula is an absolutely-positioned `<div>`. The Swift→JS contract (see `pageHTML` in
`MathOverlayView.swift`):

- `setConfig({fontPx, cellH, fg, bg, userScale})` — colors/sizing.
- `sync([{key,x,y,w,h,latex,display}])` — reconciles desired state: new keys create a `<div>`,
  missing keys are removed, **surviving keys are only repositioned (no KaTeX re-render)**.
- `clearAll()` — full teardown; forces KaTeX to re-render at new size/colors.
- JS posts `bounds` messages back (real rendered pixel rects per key) → `onBounds` tightens hitboxes.

`OverlayController` only emits `clearAll()`/`setConfig()` when font size or config JSON actually
changed (`pendingClear`, `lastFontPx`, `lastConfigJSON`); otherwise just `sync()`. Each formula
is scaled (`fit()`, CSS `transform: scale()`) to fit entirely within its single row so it never
bleeds into neighbours.

### Two invariants that are easy to break

1. **Overlay keys are bound to the absolute scrollback row**, `key = "\(viewportRow + buffer.yDisp)|startCol|body"`.
   This is why scrolling *repositions* overlays instead of destroying/rebuilding them. Don't key on the
   viewport-relative row.
2. **NULL handling on scan**: empty grid cells return `code 0` = `\u{0}`, which KaTeX rejects in strict
   mode. `OverlayController.rescan()` replaces `\u{0}` with a space 1:1 to preserve column positions.

### Click-through / hit-testing model

The overlay must let normal terminal selection/scroll pass through while still catching formula
clicks and the pinned panel's buttons:

- `OverlayHost.hitTest` returns `nil` for empty area (click-through) but lets hits land on interactive
  subviews (the pinned panel's buttons).
- `FormulaLayer.hitTest` always returns `nil` (fully transparent to events).
- `FormulaPreview.hitTest` returns `nil` unless `pinned` (hover preview is purely visual).
- Formula clicks/Esc are caught by two local `NSEvent` monitors in `OverlayController`; a click on a
  formula hitbox is *swallowed* (returns `nil`) so no terminal text selection starts.

### Scroll-following overlays (#14)

Scrolling is a fast sequence of static states; the terminal scrolls uniformly by `Δrows × cellHeight`,
so every visible formula moves by the same pixel amount. Instead of repositioning the out-of-process
WebView per step (flickers) or hiding it (the old behaviour — formulas vanished while scrolling),
`scrolled` drives a *separate* path (`onScrolled → scheduleReposition`) that translates the **whole
formula container as one block** via CSS `translateY` inside the WebView (`setScroll(dy)`,
GPU-composited, no per-div `sync()`). The offset is `(lastRenderedYDisp − currentYDisp) × cellHeight` —
CSS-y is unambiguous in both directions (a negative *NSView frame origin* on the layer-backed WebView
would **not** reliably shift content up in the flipped host). Two invariants make it clean:

- **No content-rescan during scrolling.** `scrollTo` fires a `rangeChanged(0,rows)` per step (via
  `refresh`+`updateDisplay`); `armRescan` swallows it while `isScrolling` so no `sync()` fights the
  translation. The accumulated dirty range survives for the settle rescan.
- **Atomic settle.** ~150ms after the last scroll event (`scrollIdle`), `scrollSettled` runs one
  `rescan()` that emits `sync(...)` **and** `setScroll(0)` in the *same* JS string → one WebView frame:
  surviving formulas sit pixel-identical (no jump), only scrolled-out divs leave and newly-revealed
  ones appear, so no hide/reveal is needed. The 30ms `scheduleRescan` debounce still serves terminal
  output, resize, and settings changes.

## Vendored SwiftTerm fork (`SwiftTermLocal/`)

MIT fork of migueldeicaza/SwiftTerm. The patch surface we depend on (don't lose these on any re-vendor):

- `public var extraLineSpacing: CGFloat` on `TerminalView` — extra px per cell on top of natural line
  metrics; triggers `resetFont()` on change. Default `8` here for overlay headroom.
- `public var lineCellSize: CGSize` — read access to computed cell dimensions for overlay placement
  (`LatexTerminalView.cellSize()`).
- `public internal(set) var isWrapped` on `BufferLine` — read access to the soft-wrap continuation flag
  so `OverlayController` can reconstruct logical lines for wrapped-formula detection (#1). Write stays
  module-internal.
- `open func requestOpenLink(source:link:params:)` on `LocalProcessTerminalView` (in
  `MacLocalTerminalView.swift`) — promotes the link-open handler from a `TerminalViewDelegate`
  protocol-extension default to a real, overridable class member so `LatexTerminalView` can override it.
  Cmd-click link handling (relative-path resolution against the OSC 7 cwd, reveal-in-Finder) lives in
  that override; without this hook the extension default wins and bare relative paths fail with Finder
  error -50.
- `public func showFindInterface()` / `hideFindInterface()` / `isFindInterfaceVisible` on
  `TerminalView` (Mac) — public entry to the fork's built-in find bar (`TerminalFindBarView` +
  `SearchEngine`), which is otherwise only reachable via the AppKit Find-menu responder actions
  that a SwiftUI app doesn't wire up. `LatexTerminalView` calls this from its ⌘F handler (#9).
- **Behaviour fix in `Terminal.swift` (`canJoinImplicitRows` / `seamIsTightPathContinuation`)** —
  the Ghostty-style implicit-link detector reconstructs a hard-wrapped path/URL by joining adjacent
  rows when the seam forms a link. Its strict seam test requires a `.` inside the local 96-char seam
  window (the regex's dotted-path lookahead), so a path wrapping across **three or more rows** lost the
  chain at any *interior* seam with no nearby dot (e.g. `…/3_Studium/` ⟂ `2026_SoSe/…`) and only
  fragments stayed cmd-clickable — visible in LatexTerm's narrow tiled panes. `seamIsTightPathContinuation`
  is an additive fallback: when the upper row is filled (forced wrap) and the seam is a tight,
  slash-bearing run of link chars, join it. Guards against false joins: a wrapped list item's tail row
  isn't filled (blocked by the existing threshold), and a true list of anchored paths (`/a` over `/b`)
  is rejected because *both* rows begin with a `/`/`~` anchor. Known residue: ultra-narrow panes (≲20
  cols, ≥6-row wraps) and a contrived list of absolute paths each *exactly* filling the pane width can
  still mis-detect — both rare and low-harm (a bad cmd-click just beeps). Not an API exposure, so easy
  to drop on a re-vendor — re-apply it.

## Known limitations (by design, don't "fix" silently)

- Soft-wrapped inline formulas across a line break **are** detected (logical-line reconstruction via
  `isWrapped` → `LaTeXDetector.findWrapped`; rendered in the widest row-segment, others masked). Out of
  scope: a formula whose opener is scrolled off above the viewport, or one that wraps off the bottom edge.
- No display-mode `$$..$$` typesetting — `display:false` is hardcoded in the layer sync so overlays stay
  one row tall. The hover/pin `FormulaPreview` is the only place that renders true `displayMode:true`.
- No live theme sync after launch; background is captured per rescan.
- Inline `$…$` detection has brace-awareness (an inner `$` inside `{…}` no longer closes early), but a
  bare shell-variable *pair* on one line (`echo $PATH and $HOME`) still greedily matches `$…$`. A safe
  heuristic to suppress this can't be found without breaking legit math (`$(a+b)$`, `$n$th`, `$X$ … $Y$`),
  so it's left as-is by design — math correctness wins.
- `LaTeXReadable`'s 2D matrix/`cases` output is **monospace + left-aligned by construction** (column
  alignment is space-padding, the bracket glyphs only stack in a fixed-width font). It's built for the
  copy target that matters — terminal, code block, monospace notes — and degrades in proportional/centred
  text. A single-line `[a b; c d]` form would be paste-robust everywhere but less matrix-like; the 2D form
  was chosen deliberately. Single-line outputs (fractions, accents, sub/superscripts) are unaffected.

## Aktueller Stand (2026-07-03)

**Voll-Review + UI-Polish-Session — Commit `1450380` direkt auf main gepusht, 34 Tests grün.**
Gesamturteil des Reviews: Architektur & Code solide, keine strukturellen Umbauten nötig. Änderungen:
- **Einstellungen-Fenster (⌘,)**: neue `SettingsView.swift` (SwiftUI `Settings`-Szene) — alle Optionen
  als Form mit Live-Slidern/ColorPickern; schreibt über dieselben Pfade wie die Menü-Shortcuts.
- **Kachel-Hülle `PaneContainerView`** (in `TerminalSplit.swift`): 4px Content-Inset (Text klebte
  am Rahmen — SwiftTerm zeichnet ab x=0, Inset bewusst NICHT im Fork wegen Overlay-/Maus-Mathematik);
  Fokus-Rahmen nur bei ≥2 Kacheln; Rundung nur an Innen-Steg-Ecken via `maskedCorners` (eigener
  8px-Radius kollidierte außen mit der Fenster-Rundung → „Doppelabrundung").
- **Fix Scrollback-Zerhackung**: `animator().frame` setzt Frames pro Animations-Tick → ~13 PTY-Resizes
  pro Kachel-Umsortierung; SwiftTerm reflowt bei jeder Spaltenänderung verlustbehaftet + SIGWINCH-Sturm
  für TUIs. Jetzt: `pinContent(forTargetSize:)` pinnt das Terminal VOR der Animation auf die Zielgröße
  → genau ein Resize pro Umsortierung. (Hart umbrochene TUI-Ausgaben reflowen prinzipbedingt nie.)
- **Fix ⌘⇧-Shortcuts (deutsches Layout)**: die Font-Shortcuts schluckten ⌘⇧+/−/0 (Zeilenabstand),
  weil Shift generell toleriert wurde (US braucht es für `+`). Jetzt Shift nur noch beim `=`-Zeichen.
- Kleinkram: `relayout()`-Frame-Berechnung entdoppelt; `LaTeXReadable`-Cache auf 512 gedeckelt;
  Tooltips auf den Pin-Panel-Buttons.

**Maschinen-Setup-Nebenfund:** Die Metal-Toolchain fehlte in Xcode (Build brach ab) —
`xcodebuild -downloadComponent MetalToolchain` einmalig ausgeführt, dauerhaft behoben.

**Neue Roadmap: Codex-Integration — Tracking-Issue #29** (Label `Codex`, Issues #24–#28).
LatexTerm wird fast nur für Codex genutzt → gezielt darauf optimieren. Architektur-Grundsatz
(in #29 ausformuliert): CC-**Hooks/Statusline** für Events Richtung Terminal (fertig/braucht Input/
Status/Farbe — kein Terminal-Text-Parsing), lokaler **Socket + `latexterm`-CLI** für Steuerung
Richtung Terminal (Panes öffnen/prompten), MCP-Server nur als spätere zweite Fassade; Bindeglied
ist eine `LATEXTERM_PANE_ID`-Env-Var je Shell. Empfohlener Einstieg: **#26 Pane-Zoom** (kein
Integrations-Aufwand), dann #24 v1 (passive Farbextraktion), dann Infra (#28) → #27/#25.
- [ ] Nichts in Arbeit — bei Wiederaufnahme: Reihenfolge aus #29.

---

### Vorheriger Stand (2026-06-12)

**Issue-Sweep 2026-06-12 — gemergt (PR #23, rebase auf main) und manuell verifiziert.**
Damit ist die Roadmap aus Tracking-Issue #13 **vollständig abgeschlossen** (Tier 1–4 + beide
Audit-Blöcke); alle Issues inkl. #13 sind zu. Die Einzelpunkte des Sweeps, ein Commit pro Issue:
- **#19** Gepinntes Panel überlebt Rescan & Scroll (Option A: nur Esc/Klick-daneben/Formel-Toggle schließen).
- **#21** Kleinkram: Hitbox-Tests rechnen die Scroll-Block-Translation heraus; `setScroll(0)` vor `sync()` (Bounds nicht mehr transient verschoben); toter `"leftarrow "`-Eintrag weg; Fenstertitel nur von der fokussierten Pane (unfokussierte merken ihn, Fokuswechsel holt nach).
- **#5** Export im Pin-Panel: „PDF" (Vektor via `WKWebView.createPDF`) + „MD" (PNG-Chip als `![…](data:image/png;base64,…)`); PNG bleibt; SVG = Stretch-Goal (KaTeX kann kein SVG).
- **#7** Editier-Loop: „✎" im Pin-Panel → Inline-Textfeld + Live-KaTeX-Vorschau (150 ms Debounce), Enter schreibt den Ausdruck in die Prompt-Zeile (Variante a; Scrollback immutable), Fokus zurück ans Terminal. Auch bei KaTeX-Fehlern (kaputte Formel direkt fixen).
- **#8/#20** ⌘T erbt das OSC-7-CWD der fokussierten Kachel; Spawn-CWD geht via `startProcess(currentDirectory:)` an den Kindprozess (prozessweites `changeCurrentDirectoryPath` entfernt). Fallback Home bei fehlendem/gelöschtem Verzeichnis.
- **#9** ⌘F-Suche: Fork hatte Engine **und** Find-Bar-UI komplett — nur über AppKit-Find-Menü-Responder erreichbar; neuer Fork-Hook `showFindInterface()` + ⌘F-Handler in `LatexTerminalView` (Fokus-Weiterreichung wie ⌘W).
- **#11** Session-Restore: `SessionStore` (JSON, Application Support) speichert Pane-CWDs bei `willTerminate`, Restore beim Start, sauberer Default-Fallback.
- **#12** `viewDidChangeEffectiveAppearance` → Rescan → `setConfig()`-Restyle ohne KaTeX-Rebuild (volle Wirkung erst mit echtem Theming, Farben sind weiter hartkodiert).
- **#22** Diese Doku, Root-AGENTS.md (Test-Target-Satz), SECURITY.md (AX-PTY-Injection + Cmd-Klick als dokumentierte, bewusste Flächen).

---

### Vorheriger Stand (2026-06-11)

Roadmap-Quelle ist GitHub-Tracking-Issue **#13** (Tier 1–4 + Audit-Block). **Tier 1 ist vollständig abgeschlossen.**

**Code-Audit 2026-06-11 (Voll-Review aller ~3.300 Zeilen App-Code):** Ergebnisse als Issues #15–#22 angelegt (Label `audit-2026-06`), Tracking #13 neu strukturiert (erledigte Häkchen gesetzt, vertauschte Tier-3/4-Verweise #8↔#9, #11↔#12 korrigiert). Die vier echten Bugs, in Abarbeitungsreihenfolge:
- **#15** WKWebView-Leak: `FormulaLayer`/`FormulaPreview` registrieren sich selbst als `WKScriptMessageHandler` → Retain-Cycle über `WKUserContentController` → pro geschlossener Pane leaken zwei WebViews + WebContent-Prozesse. Fix: Weak-Proxy-Handler.
- **#16** Kaltstart: `FormulaLayer.pendingJS` puffert nur das *letzte* JS — ein zweiter Rescan vor `didFinish` überschreibt das gepufferte `setConfig` → Seite bleibt auf JS-Defaults (`cellH:16` statt ~24) → Maske zu niedrig, dauerhaft bis zur nächsten Config-Änderung. Fix: pendingJS akkumulieren.
- **#18** `FormulaSettings.didChange` ist undifferenziert → jede `accentColor`-Änderung (adaptive Akzentfarbe!) erzwingt `invalidateAll()`+`clearAll()` = KaTeX-Full-Rebuild aller Formeln, obwohl accentColor Formeln nicht betrifft. Dazu: NSColor-`==` über Farbräume (sRGB gespeichert, calibrated geladen) fragil.
- **#17** `userShell()`: Pointer-Leak + fehlender `result != nil`-Check nach `getpwuid_r`.

Weitere Befunde: #19 (gepinntes Panel stirbt bei jedem Rescan — **Blocker für #7**), #20 (prozessweites `changeCurrentDirectoryPath` beim Spawn — erledigt sich mit #8), #21 (Kleinkram-Sammler), #22 (Doku-Drift: die Dateitabelle oben beschreibt `TerminalContainer` veraltet; die ganze Pane-/Tiling-/Adaptive-Accent-Logik lebt in `TerminalSplit.swift`, AX-Dictation-Support in `LatexTerminalView` — wird mit #22 nachgezogen). Security-Posture insgesamt solide (JSON-Escaping konsequent, KaTeX ohne `trust`).

Alt-Issues neu bewertet: #9 ist **billiger als gedacht** (vendored Fork hat komplette Search-Engine: `findNext`/`findPrevious`/`findAll` public auf `TerminalView` — nur UI fehlt). #5: KaTeX kann **kein SVG** — PDF via `WKWebView.createPDF` ist der einfache Vektor-Pfad, SVG → Stretch-Goal (Kommentar im Issue). #12 ist blockiert auf nicht-existentes Theming (Farben 4× hartkodiert) — als Letztes oder schließen.

**Erledigt & gepusht (main):**
- #10 Test-Suite, #2 inkrementelle Detection (frühere Sessions).
- #3 Detector Brace-Awareness — `ffa5ed8`.
- #1 Wrapped-Inline-Formeln — `1e72876` (`LaTeXDetector.findWrapped`, Fork-`isWrapped` public, breitestes-Segment-Render + Masken-Items).
- #4 KaTeX-Fehler sichtbar — `7c57f77` (`errors`-Kanal Layer→Swift, rotes Underline, Fehler im Hover/Pin, bei Fehler nur „LaTeX"-Button = kopiert Quelle+Meldung).
- #14 Scroll-Mitlauf — Block-Translation per CSS-`translateY` in der WebView (`setScroll`), Rescan-Suppression während `isScrolling`, atomarer Settle (`setScroll(0)`+`sync()` in einem JS-Aufruf). Kein Hide/Reveal mehr. Siehe „Scroll-following overlays (#14)" oben.
- #6 LaTeXReadable Tier 2 — Matrizen/`cases` als 2D mit Klammer-Glyphen (brace-/env-tiefen-bewusstes `parseGrid`), Akzente als Unicode-Combining-Marks, griechische Sub/Superscripts, Memoisierung. Monospace-Annahme der 2D-Form als Known-Limitation dokumentiert.
- WebView-Vorwärmung — Overlay- und Popover-WebView rendern beim Load einmal off-screen (`x^2`), zieht KaTeX-Init + Fonts vor die erste Nutzung; behebt das sekundenlang unsichtbare erste Hover beim Kaltstart.
- Tests: **34** grün (`xcodebuild test … -scheme LatexTerm -destination 'platform=macOS'`).

**Wichtiger Nebenfund (in #4 behoben):** `FormulaPreview.show` re-evaluierte das Render-JS bei *jeder* `mouseMoved`-Iteration → out-of-process-WebView geflutet, `size`-Callback kam nie zurück → Hover-Popover blieb **generell** unsichtbar (vorbestehender Bug). Fix = `renderedKey`-Dedup: nur bei echtem Inhaltswechsel neu rendern. Click→Pin setzt voraus, dass Hover das Popover schon sichtbar gemacht hat.

**Nächster Schritt:** nichts offen — Roadmap komplett. Mögliche neue Issues bei Bedarf (Stretch):
- Feinschliff #14: am ein-/ausscrollenden Rand sind frisch reinkommende Formeln erst nach dem Settle gerendert (während des Scrollens leer) — ließe sich durch Rendern eines Viewport-Randes (± ein Screen) vorab mildern.
- Stretch-Goal aus #5: echter SVG-Export (KaTeX-HTML in `<foreignObject>` mit Font-Embedding oder MathJax als Export-Renderer).
- Echtes Theming (Farben sind 4× hartkodiert) — schaltet die volle Wirkung von #12 frei.

**Verifikations-Workflow (manuelles UI-Testen):** ⚠️ **Codex läuft selbst in einem LatexTerm-Fenster** — `pkill -f LatexTerm` killt den eigenen Host und die Instanzen-Jonglierung ist wertlos. Außerdem dedupliziert LaunchServices über die Bundle-ID, d.h. ein direkt gestartetes `.build`-Binary wird von einer bereits via Xcode laufenden Instanz verdrängt (→ Env-Vars wie `LATEXTERM_SCAN_LOG` greifen nicht). **Robuster Weg:** der User baut+startet selbst per **Xcode Cmd+R**; Diagnose-Logging in `#if DEBUG` *immer an* (kein Env-Gate) und **direkt in eine Datei** schreiben (`FileHandle`, z.B. `/tmp/…`) statt NSLog/os_log, dann die Datei auslesen. Der Standalone-`.build`-Run wirft harmlose WebContent-Sandbox-Fehler — kein echtes Problem.
