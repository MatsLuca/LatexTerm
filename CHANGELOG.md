# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Rendering-Architektur: ein WKWebView statt einer pro Formel.** `MathOverlayView` (ein WebView je Formel) wurde durch `FormulaLayer` ersetzt – ein einzelnes, einmalig KaTeX ladendes WebView, das jede Formel als absolut positioniertes `<div>` hält. Der gewünschte Zustand wird pro Scan als JSON übergeben und in JS abgeglichen (`sync()`): neue Keys erzeugen ein `<div>`, fehlende werden entfernt, überlebende nur neu positioniert (kein KaTeX-Re-Render).
- **Overlay-Keys an die absolute Scrollback-Zeile gebunden** (`viewportRow + buffer.yDisp`). Scrollen positioniert Overlays jetzt neu, statt sie zu zerstören und neu aufzubauen.
- **Flackerfreies Scrollen.** Scrollen ist eine schnelle Folge statischer Zustände – beim Repositionieren pro Zwischenschritt flackerte die out-of-process WebView. Jetzt feuert SwiftTerms `scrolled`-Event einen separaten Pfad (`onScrolled` → `scheduleReposition`), der die Overlays beim ersten Event ausblendet und einen Idle-Timer armt. Solange Scroll-Events fließen (inkl. Trackpad-Momentum) bleiben sie aus; erst ~150 ms nach dem letzten Event = "wieder statisch" wird neu positioniert und – nach dem ersten `onBounds`-Report, also wenn die WebView die neuen Positionen gezeichnet hat – sauber wieder eingeblendet. Der bisherige 30 ms-Debounce (`scheduleRescan`) bleibt nur noch für Terminal-Output/Resize/Settings.
- **Formel-Span auf 1 Zelle reduziert.** Jede Formel wird in ihre eigene Zeile skaliert und ragt nie in Nachbarzeilen; große Formeln werden klein und sind über die Hover-Vorschau in voller Größe lesbar.
- **Premium UI & Farbschema-Optimierung**:
  - Der Standard-Terminal-Hintergrund wurde auf ein tieferes, moderneres Dunkelgrau (`#171414`) und die Standard-Text-/Formelfarbe auf ein passendes warmes Weiß (`#E6E1E1`) angepasst.
  - Die Cursor-Farbe (Caret) wurde für bessere Ästhetik und Kontrast von Systemgrün zu einem lebendigen Orange-Rot (`#E85E3E`) geändert.
  - Das Terminal-Fenster besitzt nun einen konsistenten ZStack-Hintergrund mit 12px horizontalem Padding und erzwingt das `.dark` Farbschema.
  - Die Bildlaufleiste (Scroller) wurde vollständig ausgeblendet und ihre Breite auf `0` reduziert, um ein rahmenloses, minimalistisches und unterbrechungsfreies Erscheinungsbild zu gewährleisten.
- **Neues App-Icon.** Echtglas-Neon-`$` (smaragdgrün, weiß-glühender Kern, grüne Bodenreflexion) auf near-black Squircle ersetzt das bisherige `E=mc²`-Icon – doppeldeutig als Shell-Prompt-Zeichen *und* LaTeX-Inline-Delimiter. Vollständiges `AppIcon.appiconset` (16–512 @1×/@2×); die Ecken sind passgenau zum Apple-Squircle (Superellipse n≈5) freigestellt.

### Added
- **Echtes Display-Math für `$$..$$` / `\[..\]`.** Display-Delimiter werden jetzt mit echtem KaTeX-`displayMode` gerendert statt inline. Zwei Fälle: (a) **mehrzeilige Blöcke** in kanonischer Form – Öffnungs- und Schluss-Delimiter stehen *jeweils allein auf ihrer Zeile* (`$$` bzw. `\[` … `\]`) – werden via neuem `LaTeXDetector.findBlocks` zeilenübergreifend erkannt und als *ein* Overlay über den gesamten Quell-Zeilenbereich gerendert (die Zeilen sind im Quelltext schon belegt, die Formel bekommt also echte vertikale Höhe statt in eine Zeile geschrumpft zu werden); (b) **einzeiliges `$$x$$`** rendert weiterhin in seiner Zeile, jetzt aber displaystyle. Display-Formeln werden in beiden Achsen zentriert, ihr maskierender Hintergrund deckt bei Blöcken die volle Höhe ab. Die Forderung *Delimiter allein auf der Zeile* verhindert Falschtreffer durch Prosa-`$$` oder die Shell-PID `$$`; ein verwaister Delimiter spannt höchstens `maxBlockRows` (12) weit. `OverlayController.rescan` liest das sichtbare Grid einmal ein, erkennt Blöcke, maskiert deren Quellzellen und scannt erst dann inline weiter (kein Doppeltreffer); `display` wird pro Item an die Layer-`sync()` durchgereicht. Inline-`$..$`/`\(..\)` bleibt unverändert.
- **Split-Screen mit automatischem Grid-Tiling.** `⌘T` öffnet eine neue Terminal-Kachel (eigener Login-Shell-Prozess, eigener `OverlayController` mit unabhängigen Formel-Overlays), `⌘W` schließt die fokussierte Kachel (bzw. das Fenster, wenn es die letzte war), `⌘1…9` füllt das Grid direkt auf N Kacheln auf (nur erweitern, nie schließen). Layout in der neuen `TerminalSplit.swift`: `TerminalPane` kapselt Shell + Overlays je Kachel, `TerminalSplitView` kachelt per direktem Frame-Layout (kein `NSSplitView`). Die Grid-Form wird aus Fensterbreite **und** -höhe gewählt – es gewinnt die Reihenzahl, deren Zellen-Seitenverhältnis dem Ziel (`idealCellAspect ≈ 0.82`) am nächsten kommt: breite Fenster bleiben länger einreihig (bis ~3 nebeneinander) und brechen dann ausgewogen um (4 → 2×2, dann Richtung 3×3). Reihen sind gleich hoch, jede Reihe teilt ihre Breite unabhängig auf (top-heavy Masonry, z. B. 5 → 3 über 2); 8px-Steg zwischen den Kacheln über einen leicht helleren Container-Hintergrund.
- **Schriftgröße global über alle Kacheln.** `⌘±`/`⌘0` ändern die Schrift jetzt in allen Kacheln gleichzeitig – die ändernde Kachel persistiert die Größe und broadcastet sie via `LatexTerminalView.fontDidChange`; alle Kacheln übernehmen sie und scannen ihre Overlays neu.
- **Klickbares Formel-Panel mit Copy-Buttons.** Ein Klick auf eine Formel pinnt die Hover-Vorschau (`FormulaPreview`) und blendet zwei Buttons ein: **LaTeX** kopiert den Rohausdruck, **Lesbar** eine Unicode-Math-Form (z. B. `(-b ± √(b²-4ac))/(2a)`). Klick daneben, `Esc`, Scrollen oder neuer Output schließt das Panel. Realisiert über zwei lokale `NSEvent`-Monitore (Mouse-Down zum Pinnen/Schließen, `Esc`); `OverlayHost.hitTest` lässt jetzt selektiv Treffer *innerhalb* des gepinnten Panels durch (Buttons), bleibt aber sonst klick-durchlässig fürs Terminal.
- **`LaTeXReadable` – LaTeX→Unicode-Konverter.** Nativer, offline rekursiver Parser: Brüche (`\frac` → `(a)/(b)`), Wurzeln (`\sqrt` → `√`, `\sqrt[n]` → `ⁿ√`), Hoch-/Tiefstellung via Unicode-Super/Subscript mit `^(…)`/`_(…)`-Fallback, Griechisch, Operatoren/Relationen/Pfeile, `\mathbb` → ℝ/ℕ/…, Akzente/Stile entkleidet. Heuristisch: exotische Konstrukte degradieren lesbar.
- **Hover-Vorschau ("Ansichts-Modus", `FormulaPreview`).** Da große Formeln in ihre Zeile geschrumpft werden, blendet das Überfahren mit der Maus die Formel in voller Größe über ihrer Position ein. Hitboxen starten als Quelltext-Box und werden auf die echten gerenderten Bounds (zurückgemeldet vom WebView via `onBounds`) eng nachgezogen. Hover-Tracking ist reines mouse-move – Klicks und Textselektion bleiben beim Terminal.
- **NULL-Zeichen-Behandlung beim Scan.** Leere Grid-Zellen liefern als `code 0` ein `\u{0}`, das KaTeX im Strict-Mode ablehnt; diese werden 1:1 in Leerzeichen gewandelt, um Spaltenpositionen zu erhalten.
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
- **"Formeln" menu** in the macOS menu bar (`CommandMenu`) with live-updating titles:
  - Toggle **Formeln anzeigen** (`⌘L`) — removes all overlays immediately when disabled, re-renders on re-enable.
  - **Formelfarbe…** — opens the native `NSColorPanel` color picker; selected color is applied to all KaTeX overlays live.
  - **Zeilenabstand** controls (`⌘⇧+` / `⌘⇧-` / `⌘⇧0`) — adjusts `extraLineSpacing` on the terminal view in 2 px steps (0–40 px range).
  - **Formelgröße** controls (`⌥⌘+` / `⌥⌘-` / `⌥⌘0`) — scales KaTeX renders by a user factor (0.5×–2.0×, step 0.1×), composed with the existing overflow-fit scale so overlays never exceed their bounding box.
- `FormulaSettings` singleton (`ObservableObject`) persisting all four settings in `UserDefaults`; broadcasts `FormulaSettings.didChange` via `NotificationCenter` so `OverlayController` and `TerminalContainer` react without polling.
- `invalidateAll()` helper on `OverlayController` — efficiently tears down all overlay views and resets `lastFontPx`, used on settings change and font size change.

### Notes
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) — required for PTY/process spawn.
- Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) needs to be installed; SwiftTerm ships Metal shaders even though the CPU renderer is used.
