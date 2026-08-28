# HISTORIE — LatexTerm

Erledigt-Verlauf der Arbeitssessions, 1:1 aus der Projekt-`CLAUDE.md` ausgelagert (Welle 5 der
CLAUDE.md-Verfassung, 2026-08-22). Neueste Einträge oben. Der aktuelle Stand und die offenen
Punkte stehen in `CLAUDE.md`; die Feature-Sicht (was ist drin, seit wann) im `CHANGELOG.md`.
Hier liegen die Arbeits-Erkenntnisse: Debug-Funde, Entscheidungen mit Begründung, Sackgassen.

---

## Stand (2026-08-29, spät — Fullscreen-TUI: Mausrad/Trackpad-Reporting, 120 Hz)

Anlass: Claude Codes `/tui fullscreen` (Alt-Screen, Research Preview). Alles in LatexTerm war kompatibel
(Prompt-Stil scannt den aktiven Buffer, Overlay/`yDisp` = 0, Vorhang hängt an Enter) — **außer dem Rad**:
`MacTerminalView.scrollWheel` bewegte nur SwiftTerms Scrollback und meldete nie Wheel-Events; im Alt-Screen
gibt es keinen Scrollback → totes Rad. Fix `reportWheel`: bei `mouseMode != .off` Rad **und** Trackpad als
Buttons 64/65 (`encodeButton` 4/5) senden; Trackpad-Deltas (Punkte) in Zeilenhöhe akkumulieren, Rest
behalten, beim Gestenstart ¾ Zeile in Bewegungsrichtung vorladen (sonst ~18 px Totzone). Dazu
`AppleTerminalView.displayFrameDelayNanos`: Repaint-Throttle an `maximumFramesPerSecond` des Screens statt
fix 60 fps (MBP ProMotion → 8,3 ms). Claude-Seite in `~/.claude/settings.json`: `CLAUDE_CODE_SCROLL_SPEED=1`
+ `wheelScrollAccelerationEnabled=false` → eine Fingerzeile = eine Textzeile. Grenze: Alt-Screen-Scrollen
ist zeilenquantisiert, Pixel-Interpolation gibt das Protokoll nicht her (gilt für Ghostty/iTerm ebenso).
Nebenwirkung, gewollt: `less`/vim reagieren jetzt auch aufs Trackpad. Von Mats live abgenommen.

---

## Stand (2026-08-29 — Launcher Runden 27+28: Pfeiltasten, Home-Kopf entrümpelt)

R27 (`HomePaneView.treeKey/listKey`): → / ← wechseln nur noch die Spalte, ⏎ im Baum klappt Ordner auf/zu,
rechts führt es aus; Tastenhilfe ⌘/ angepasst. R28: `lastLine` (letzter Prompt unter dem Untertitel) entfernt —
bleibt Tooltip auf „↻ Weiter"; Untertitel und Kontingente (`renderLimits`) hängen an `showMore`: zugeklappt nur
`aktiv …` und das 5h-Fenster (4-Zellen-Balken, kein ↻), aufgeklappt alles; Woche/Modell ab 70 % immer.
Lehren in `claude-werkstatt/launcher/HISTORIE.md` (Runden 27, 28). Sicht-Check durch Mats steht aus.

## Stand (2026-08-28, Nacht — Launcher Runde 26: Vorhang schützt Folgebefehle)

Mats' erstes Tippen fiel in den noch offenen `/color`-Folgebefehl („cyanist es“). Ursache in
`TerminalPane.launch`: Reveal + Fokus sofort bei `status=ready`, Folgebefehl 1 s später, Enter 1 s danach.
Jetzt `sendFollowUps` unter dem Vorhang (Text +0,4 s, Enter +0,6 s, nächster +1 s; Reveal 0,4 s nach dem
letzten Enter), `DispatchWorkItem`s mit `isStarted`-Guard, `terminate()` bricht ab. Ring-ETA misst weiter bis
„bereit“, Log-Zeile `bereit=…/vorhang=…`. Lehren in `claude-werkstatt/launcher/HISTORIE.md` (Runde 26).

## Stand (2026-08-28, Nacht — Einstellungen neu, Runden 31–34)

Kontext: Werkstatt-Plan `claude-werkstatt/plans/settings-neu_2026-08-28.md`. Nach R26–R30 war
`SettingsView.swift` ein einziges Form mit ~25 Elementen in drei falsch benannten Sektionen; die
nächste Option hätte keinen Platz gehabt.

- **Gerüst:** `Settings/` mit `SettingsPage` (Enum = Seitenliste), `SettingsWindow` (TabView in der
  `Settings`-Szene → macOS zeichnet Toolbar-Tabs), `Controls/` (`SliderRow`, `ColorRow`, `SettingsGroup`
  mit Footer-Hilfetext), sechs Seiten. Fenster-Höhe steht pro Seite im Enum — SwiftUIs Settings-Fenster
  passt sich nicht selbst an den Tab-Inhalt an.
- **Modell:** Schrift/Zeilenabstand/Akzent aus `FormulaSettings` + `LatexTerminalView`-Statics nach
  `ThemeStore`; `didChange` bekam ein `Change`-Enum, damit die Kachel bei adaptiver Akzentfarbe nicht das
  Theme neu installiert (der alte `affectsFormulas`-Trick, jetzt an der richtigen Stelle). Neu
  `CockpitSettings` (Notifications, Home-Befehle). Keys unverändert → keine Migration.
- **Fallen:** (1) Stores laden jetzt über `load()` (für den Reset) — die Setter dürfen dabei nicht
  schreiben, sonst landet die Theme-FG als „eigene“ Formelfarbe in den Defaults (`loading`-Guard).
  (2) `@Published var x = Self.default` ist verboten („covariant Self in stored property initializer“)
  → `ThemeStore.default…`. (3) `SettingsGroup("Titel")` braucht einen expliziten `init(_:help:content:)`,
  sonst verlangt Swift das Label `title:`. (4) Home-Kachel las die Schriftgröße über
  `LatexTerminalView.storedFontSize()` — mit dem Static verschwand die Stelle im Build-Fehler, nicht im
  grep (Build als Verifikation, nicht nur grep).
- **Bewusst nicht:** Sidebar-Settings, Suchfeld, Session-Restore-Schalter (kein heutiger Bedarf),
  Vorhang-Timeout als Option.
- **Nachträge nach erstem Durchklicken:** `projekte`-Befehle von Allgemein nach Erweitert („braucht man das als
  normaler Nutzer?“ — nein); Status-Pille als Option (aus / nur Status / mit Werkzeug, `CockpitSettings.statusBadgeMode`);
  Menüleiste: „Terminal“-Menü gestrichen, neues „Kachel“-Menü als Kürzel-Nachschlagewerk (`PaneCommand` →
  `.latexTermPaneCommand` → fokussierte Kachel im Key-Fenster), „Ablage → Neue Terminal-Kachel ⌘T“. Prinzip:
  Menüs = Aktionen, ⌘, = Einstellungen. „Nur Projekte“ bleibt im Home-Menü, weil ⌘⇧B nur dort hängt. ⌘W bewusst
  ohne Menükürzel (SwiftUIs „Schließen“ trägt es schon) — Eintrag zeigt „(⌘W)“ im Titel.
- **Build-Regel seit heute:** Claude baut selbst (`xcodebuild … build` ohne `-derivedDataPath`, signiert), Mats
  startet nur neu — `~/.claude/reference/latexterm-build.md`.
- Tests: 47 grün (13 PromptBoxLocator). Abnahme durch Mats offen (⌘Q + Neustart, alle sechs Tabs + Menü „Kachel“).

## Stand (2026-08-28 — Terminal-Optik Runde 26: Theme-Modell, Dark+, xterm-256)

Kontext: Werkstatt-Plan `claude-werkstatt/plans/terminal-optik_2026-08-28.md`. Mats fand Ghostty
(Dark+, JetBrains Mono 20) „einfach geiler zum Arbeiten“; Befund vorab per Inventar aller Optik-Stellen.

- **Zwei technische Abweichungen, nicht nur Geschmack:** (1) der Fork mischte 256-Farben per
  `.base16Lab` (LAB-Interpolation aus den 16 Basisfarben) statt xterm-Würfel — Claude Codes TUI-Farben
  sahen hier anders aus als in jedem anderen Emulator; (2) `useBrightColors = true` ließ fetten Text in
  ANSI 0–7 auf die helle Palette springen. Beides jetzt Ghostty-konform (`.xterm`, Bold ≠ hell).
- **Bauweise:** `Theme/TerminalTheme.swift` (Struct: bg/fg/16 ANSI/Cursor/Auswahl + abgeleitete
  Flächen `gap`, `keyHelpBackground`, `dim`, `faint`) und `Theme/ThemeStore.swift` (Singleton, Key
  `LatexTerm.theme`, `boldIsBright`, `cursorBlink`, `didChange`). Themes im **Ghostty-Dateiformat**:
  eingebaut `Dark+` und `Ember` (das alte `#171414`-Set), dazu alle Dateien aus
  `~/.config/ghostty/themes/` und `Ghostty.app/…/themes/` (~460) — Menü „Terminal → Theme“ und
  Settings-Picker. Kein `23/255` mehr im Code: Fenster-BG, Home-Kachel, Tastenhilfe, Ring-Vorhang,
  Kachel-Steg und die Kontrastanalyse (`analyzeContrast` filterte Pixel gegen den hart codierten alten BG)
  lesen den Store. Formel-Standardfarbe = Theme-FG, solange keine eigene Wahl gespeichert ist.
- **Fallen:** `installColors` muss *nach* dem Umstellen von `terminal.options.ansi256PaletteStrategy`
  laufen — nur `installPalette` baut die 256er-Tabelle mit der Strategie neu. `Color(red8:)` im Fork ist
  internal → `swiftTermPalette` rechnet über die 16-Bit-Init. `Terminal.options` ist public settable.
- **Nachtrag (Sichtprobe Mats, Statusline „random“):** die 256-Farben waren *verschoben*, nicht
  vermischt — Fork-Bug in `AppleTerminalView.mapColor`: bei `useBrightColors = false` zog es von jedem
  Code > 7 acht ab (77 grün → 69 blau, 214 orange → 206 magenta) und setzte alles fett
  (`useBoldForBrightColor`). Gedacht war beides für die 16 Basisfarben. Jetzt: `useBrightColors` heißt
  „Bold ist hell“ (nur 0–7 + Bold → +8), sonst behält jeder Code seine Farbe; kein Bold-Ersatz mehr.
  Dazu im Fork: `TerminalOptions.default` auf `.xterm`, und `setupOptions` erhält gesetzte
  `ansi256PaletteStrategy`/`cursorStyle` statt sie mit Defaults zu überschreiben. Fork-Dateien sind
  `r--r--r--` — vor Edits `chmod u+w`.
- **Runde 27 — Schrift (28.08., nach Abnahme R26 „passt jetzt“):** JetBrains Mono **NL** v2.304
  (Regular/Bold/Italic/BoldItalic, OFL, 840 KB) in `LatexTerm/Fonts/`, zur Laufzeit per
  `CTFontManagerRegisterFontsForURL(.process)` registriert (`Theme/AppFonts.swift`) — Ressourcen der
  synchronized group landen flach in `Contents/Resources`, deshalb kein `ATSApplicationFontsPath`.
  NL statt der Ligatur-Variante: der Fork zeichnet zellgenau, `calt`-Ligaturen würden Glyphen über
  Zellgrenzen ziehen und die Formel-Overlays (Zellkoordinaten) verschieben. Probe außerhalb der App:
  `NSFontManager` löst Familie + alle vier Schnitte als echte Dateien auf (SwiftTerms Bold/Italic-Weg).
  Neue Defaults: Familie `LatexTerm.fontFamily` (leer = SF Mono), 20 pt, `extraLineSpacing` 0;
  `AppearanceMigration` setzt bestehende Installationen einmalig um (Marker-Key). Home-Kachel, Badges,
  HUD-Pille und Formel-Editfeld nutzen `AppFonts.mono` — Home-Basisgröße gedeckelt auf 18, damit der
  Baum bei 20 pt Terminal nicht mitwächst. Settings: Picker „Schrift“ (gebündelte zuerst, dann alle
  fixed-pitch-Familien, „System (SF Mono)“); Familienwechsel = `fontDidChange` ohne `size`.
- **Runde 28 — Fläche (28.08., R27 „passt auf den ersten Blick sehr gut“):** Mats fragte, ob Launcher
  und Custom-UIs „automatisch“ an der Architektur hängen — Antwort: halb; jetzt ganz. `PaneContainerView.contentInset`
  liest `ThemeStore.padding` (Key `LatexTerm.padding`, Default 12, Slider 0–24; `applyTheme` ruft
  `setFrameSize` nach, damit laufende Kacheln neu einpassen). Home-Kachel-Palette sind Computed-Statics:
  `fg/dim/faint` + `cyan/green/blue/violet/yellow/red` = helle ANSI-Farben des Themes, `orange/pink` =
  Claudes `accentPalette` aus `projekte --json` (gemerkt in `HomePaneView.claudePalette`, Fallback
  `#d97757`/`#c46686`). Adaptive Akzenterkennung wählt aus `theme.contrastCandidates` (6 helle ANSI +
  FG) statt der Neon-Palette; Status-Pille = `badgeBackground` (Grund +3 %), HUD-Fokusring = FG 0.8.
  `HomePaneView.applyTheme` färbt Titel/Untertitel/Divider/Tastenhilfe um und lädt Baum + Liste neu.
  Verbleibende feste Werte: keine (nur der Pixel-Mittelwert der Kontrastanalyse).
- **Runde 29 — Ghostty-Import + Einstellungen komplett (28.08., R28 „sieht gut aus bis hierhin“):**
  `Theme/GhosttyConfig.swift` liest `~/.config/ghostty/config` (Fallback Application Support,
  `config-file`-Includes eine Ebene, `?`-Präfix, später gewinnt) und baut einen `Plan`: `theme`
  (auch `light:X,dark:Y` → dark), `font-family` (nicht installiert → `+ " NL"` probieren, sonst Hinweis),
  `font-size`, `window-padding-x/y` (Mittel, 0–24), `cursor-style-blink`, `bold-is-bright`;
  `cursor-style ≠ block` nur als Hinweis. Direkte Farb-Overrides in der Config (background/palette …)
  ergeben ein Theme „Ghostty (Config)“ = Basis-Theme-Paare + Overrides, persistiert als Zeilen in
  `LatexTerm.customTheme` (`TerminalTheme.ghosttyPairs` ist der Rückweg). Settings: Knopf „Aus Ghostty
  übernehmen…“ mit Alert-Vorschau (Zeile je Änderung + Hinweise; „Übernehmen“ nur, wenn etwas zu tun ist),
  ohne Config ausgegraut. `apply` geht über dieselben Setter wie die Settings (Store, `AppFonts.storedFamily`,
  `fontDidChange`). Neu: Schalter „Cursor in Theme-Farbe statt Projektfarbe“ (`LatexTerm.cursorThemeColor`,
  `applyAccent` entscheidet). Nebenfund: `applyTheme` setzte die Hülle auf den nackten Grund und verlor den
  Akzent-Tint — jetzt ruft es `applyAccent()`. Auto-Folgen der Config (29b) bewusst nicht gebaut.
- **Runde 30 — Abnahme (28.08.):** `docs/optik-probe.sh` (identische Ausgabe: Kopf, Bold/Italic/…, ANSI-16,
  256er-Würfel, Statusline-Nachbau) in einem Ghostty-Fenster (`open -na Ghostty --args
  --window-save-state=never -e bash -c …` — **ohne** `--window-save-state=never` bringt jede neue Instanz
  ihre gespeicherten Fenster mit, daher vorhin die „vielen Ghosttys“) und in einer gezoomten LatexTerm-Kachel
  auf demselben Fensterrahmen, `screencapture -l <windowID>` je Fenster, Montage mit `magick +append` →
  `docs/optik-side-by-side.png`. Ergebnis: bis auf die Ligaturen (Ghostty `<=> -> =>`, LatexTerm NL) nicht
  zu unterscheiden — Zellhöhe, Farben, Statusline identisch. Zwei Fallen: (1) Bildschirmaufnahme scheiterte
  trotz grünem Schalter — der TCC-Grant klebte am alten Debug-Build (`reference/latexterm-tcc.md`), Fix
  `tccutil reset ScreenCapture com.mats.LatexTerm` + neu einschalten + Neustart; (2) das Zoomen der
  Probe-Kachel verdeckte Mats' Session — sah aus wie ein Absturz. Regel: Zoom nur angekündigt und nur
  Sekunden. Doku: README „Appearance“, CLAUDE.md-Dateitabelle `Theme/`, Fork-Abschnitt (`mapColor`).
- **Nachtrag R30 (Mats: „Schrift minimal fetter, wie eine Pixel-Outline mehr“):** Treffer — der Fork
  zeichnete mit `setShouldSmoothFonts(true)`/`setAllowsFontSmoothing(true)` (macOS-Font-Smoothing, verdickt
  Striche ~1 Subpixel); Ghostty hat `font-thicken = false`. Jetzt `public var fontSmoothing` auf
  `TerminalView` (Default aus), in LatexTerm als `ThemeStore.fontThicken` → Schalter „Schrift verstärken
  (Font-Smoothing)“ und im Ghostty-Import (`font-thicken`).
- **Nachtrag R30 (Mats: „farbige Kachel-Outlines deaktivierbar, optional wieder borderless“):** Schalter
  „Kachel-Akzentrahmen“ (`LatexTerm.paneBorders`, Default an) — aus = `borderWidth 0` in `applyFocusStyle`
  und kein Hüll-Tint in `applyAccent`; Caret, HUD-Punkt, Home-Ring und Claude-Box tragen die Projektfarbe
  weiter. Einen zweiten Schalter „Randloses Fenster“ (Ampel + HUD weg) hatte ich gebaut — Mats: „Ampel weg
  braucht's gar nicht“ → wieder entfernt, nur der Rahmen-Schalter bleibt.
- **Prompt-Tint, Schritt 1: Box-Erkennung (28.08., Mats: „erst die Infrastruktur perfektionieren“):**
  `Latex/PromptBoxLocator.swift` (reine Foundation-Logik, im Logic-Test-Target, 13 Fixture-Tests):
  Trennlinie = Zeile nur aus `─` (U+2500) ab Spalte 0 mit ≥ 90 % Breite; untere Linie = unterste im
  Fenster; obere Linie = nächste darüber, unter der eine Zeile mit `❯`/`>` als erstem Zeichen liegt;
  Inhalt = alles dazwischen (Leerzeilen, Umbrüche, bis 60 Zeilen). Mats' Sorgen abgedeckt: `--`/`-->`
  sind ASCII (U+002D) und zählen nie; eine selbst getippte `────`-Zeile in der Box hat darunter Text statt
  Marker und wird übersprungen — zusätzlich `requireStyledRules` (Claudes Linien sind gefärbt, Nutzer-Text
  ist Standard-FG); Dialog-Rahmen `╭──╮` haben Ecken ≠ `─`; Vorschlagslisten liegen unter der unteren
  Linie. Im Pane: `updatePromptBox()` nach jedem `rangeChanged` (≤ 64 Live-Zeilen), Ergebnis als absolute
  Buffer-Zeilen (`yBase + row`, dafür `Buffer.yBase` public), erst streng, dann Fallback ohne Farbprüfung;
  DEBUG-Log `BOX rows a..<b` / `BOX none` in `/tmp/latexterm-status.log`.
  **Schritt 2, Tint:** Fork-Hook `TerminalView.rowForegroundOverride(absoluteRow)` — in
  `buildAttributedString` ersetzt er die FG von Zellen mit `.defaultColor` (nicht `dim`, damit der
  Platzhalter grau bleibt); Pane liefert `effectiveAccent` für die Box-Zeilen. Schalter „Prompt-Text in
  Projektfarbe (experimentell)“ (`LatexTerm.promptTint`, Default aus). Test-Dateien per `xcodeproj`-Gem
  (nur `/usr/bin/ruby` hat es) ins Test-Target gehängt; 47 Tests grün.
- **Prompt-Stil, Schritt 3 (Mats: „krass, das funktioniert sogar“ → eigene Farbe, Glühen, Regenbogen):**
  Fork-Hook jetzt zellgenau: `TerminalView.cellStyleOverride(absoluteRow, col) -> CellStyleOverride?`
  (`color` + `glow`); `buildAttributedString` flusht den Run, sobald sich der Override ändert (nötig
  für den Farbverlauf je Spalte), Glow als `NSAttributedString.Key.latexTermGlow` → im Draw-Loop zwei
  Schatten-Pässe (`setShadow` blur 10 + 3) vor den scharfen Glyphen. `ThemeStore.promptTintMode`
  (off/accent/custom/rainbow, Migration vom alten Bool), `promptGlow`, `promptColor` (Hex). Regenbogen:
  Hue über die Spalten (Zyklus 28 Zellen), Phase per 12-Hz-Timer im Pane, nur solange Box + Modus.
  Settings: Picker „Prompt-Text“, ColorPicker (nur bei „Eigene Farbe“), Toggle „glüht“.
- **Prompt-Stil, Schritt 4 (Mats: Slash-Commands ausgenommen?):** Claude Code färbt Commands/@-Erwähnungen
  selbst (Nicht-Standard-FG) — der Tint ließ sie bewusst in Ruhe. Jetzt Schalter „Auch von Claude gefärbten
  Text übersteuern“ (+ optional eigene Farbe): Fork-Hook bekommt `isDefaultFg` und wird für alle
  Nicht-dim-Zellen gerufen; Pane übersteuert gefärbte Zellen nur ab Spalte 2 (Marker `❯` bleibt).
- **Cursor:** `steadyBlock` (Ghostty), Blinken als Schalter; Farbe bleibt Akzent/Projektfarbe (Mats:
  „wie vorgeschlagen“). Padding, Schrift (JetBrains Mono gebündelt, 20 pt, Zeilenabstand 0) und die
  Home-Palette folgen in Runden 27/28; Ghostty-Config-Import in Runde 29.

---

## Stand 2026-08-24, Zusammenfassung (aus der CLAUDE.md ausgelagert am 2026-08-28)

Roadmap #13 (LaTeX-Terminal) komplett; Cockpit-Roadmap **#29**: #24/#25/#26/#27/#30 und #28 v1
(Socket + CLI) zu, **#28 v2 offen**. Name bleibt LatexTerm (#31 zu, 12.07.). **Neu 24.08.: Home-Kachel
(⌘N, Projekt-Launcher)** — Welle 5 des Werkstatt-Plans `projekt-launcher_2026-08-24.md`; gebaut,
kompiliert, **noch nicht live verifiziert** (Claude lief selbst in LatexTerm → kein Neustart aus der
Session). Verlauf, Debug-Funde und Entscheidungen mit Begründung: `HISTORIE.md`; Feature-Sicht:
`CHANGELOG.md` (Unreleased seit 0.1.0); Nutzer-Doku: `README.md`.

- **Home-Kachel (Stand 24.08., Runden 1–10 in `HISTORIE.md`):** Fokusziel ist die Tabelle selbst
  (`focusTarget`; nie in `becomeFirstResponder` umleiten); Fokus-Optik (Dimmung, Akzentbalken, Kachel-
  Dimmung) aus **einer** Wahrheit — KVO auf `window.firstResponder` → `focusDidChange()`. Aufklapp-Zustand
  in eigener `expandedPaths`-Menge (UserDefaults `LatexTerm.homeExpanded`), `reloadData()` darf ihn nicht
  überschreiben. Tasten: ⇥ Spalte, ⇧⇥ Pin-Screen, ⌘P pin, ⌘E umbenennen, ⌘⇧N neues Projekt, ⌘⏎ Zoom,
  ⌘R reload; Tippen sucht in beiden Spalten. Mats-spezifische Befehle leben **nur** in den Templates von
  `projekte --json` (Werkstatt) — Swift kennt keine Aliase/Skills. Schreibende Aufrufe über
  `runProjekte(args)` mit `"$@"`, nie String-Interpolation. ⌘W läuft über `HomePaneView.performKeyEquivalent`;
  `list-panes` meldet Home-Kacheln mit `cwd: null`. Layouts (mehrere Kacheln je Projekt) bewusst nicht gebaut.
  Mats' Urteil nach Runde 10: „erstmal zufrieden".

- **#28 v2 — Fernsteuerung vom Handy** (Plan als Kommentar in #28): Claude-App → Cloudflare
  Worker (OAuth via `workers-oauth-provider`, nur MatsLuca) → Cloudflare Tunnel → MCP-Bridge auf
  localhost → bestehender `control.sock`. Etappen E1–E4 (lokale Bridge → Tunnel → OAuth+Connector
  → Bestätigungs-UX/Kill-Switch/Audit/SECURITY.md). Sicherheits-Kern: `send_text` = RCE auf dem
  Mac → OAuth nicht selbst bauen, Mac nie direkt im Netz, Lease-Bestätigung für schreibende
  Remote-Aktionen. Vor E3 zu entscheiden: Login-Provider, Bestätigungs-Modus, Bridge-Lebenszyklus.
- **Claude-for-OSS-Bewerbung** (07.07., Long Shot ohne erfüllte Kategorie) — Antwort ausstehend;
  Hintergrund in `HISTORIE.md` → „Nebengleis".
- **Bekannte Reste:** `list-panes`-Status hinkt bei laufender Claude-TUI sichtbar hinterher
  (Beobachtung 06.07., kein Issue). Stretch-Ideen ohne Issue: Rand-Vorrendern beim Scrollen (#14),
  echter SVG-Export (#5). Theming ist seit R26 da (`ThemeStore`) — #12 damit freigeschaltet.


---

## Stand (2026-08-24 — Home-Kachel gebaut, Welle 5 des Projekt-Launchers)

Kontext: Werkstatt-Plan `claude-werkstatt/plans/projekt-launcher_2026-08-24.md` (Datenschicht
`projekte`, Shell-Launcher `start`, Plugin-Command `/neues-projekt`). Die Home-Kachel ist die native
Präsentation darüber. Entscheidungen von Mats: ⌘N = Home, ⌘T bleibt nackte Shell; Ordner (CLAUDE.md)
ist die Projekt-Wahrheit, Aliase optional; Sortierung nach letzter Claude-Aktivität.

- **Bauweise:** kein neuer Pane-Typ — `TerminalPane` bekommt `showHome()` (HomePaneView über dem
  Container, Shell noch nicht gestartet, `isStarted=false`) und `launch(in:command:)` (Home weg,
  `start(in:)`, Befehl per `send(txt:)` wie `new-pane --exec`). Grid, HUD, Zoom, ⌘W, Notifications
  bleiben unverändert; `focusTarget` (Home-Tabelle oder Terminal) ersetzt `pane.view` an den fünf
  `makeFirstResponder`-Stellen. `terminate()` schweigt ohne Prozess.
- **Fallen:** `isFocused` (Pane und SplitView) musste auf den Container statt das Terminal schauen,
  sonst gelten Home-Kacheln nie als fokussiert (Titel, HUD-Punkt, Notification-Unterdrückung).
  `HomePaneView.becomeFirstResponder` leitet auf die Tabelle um und gibt `false` zurück — die
  Dimmung kommt aus `HomeTable.become/resignFirstResponder`. `saveSession` filtert Home-Kacheln
  (kein CWD) und speichert bei null gestarteten Shells nichts → nächster Start = Home.
- **Datenquelle bewusst extern:** `projekte --json` über `/bin/zsh -lc` (holt PATH aus `.zprofile`
  — `.local/bin`, Homebrew-Python ≥ 3.11 für `tomllib`); die App enthält keine Pfade, das Repo
  bleibt privacy-sauber. Fehlt das CLI: Hinweis in der Statuszeile, sonst nichts.
- **Runde 21 — Quickstarts auch bei geschlossener App (27.08.):** Mats: „hätte man es auf ein
  geschlossenes App-Symbol machen können". Drei Teile: (1) **URL-Scheme** `latexterm://quickstart/<key>`
  und `latexterm://home` (`CFBundleURLTypes`, `application(_:open:)` im AppDelegate) — geht auch aus
  Raycast/Spotlight/`open`. (2) **Kaltstart-Pfad:** ohne Fenster wartet der Eintrag in
  `QuickstartStore.pending`, `TerminalSplitView.viewDidMoveToWindow` holt ihn; `runQuickstart` nutzt
  die noch unberührte erste Home-Kachel statt eine zweite zu öffnen. Der Store fällt auf
  `~/.cache/projekte/quickstarts.json` zurück, solange keine Kachel geladen hat. (3) **Dock-Tile-Plugin**
  `LatexTermDockTile.docktileplugin` (neues Bundle-Target, `NSDockTilePlugIn` in der Info.plist, eingebettet
  nach `Contents/PlugIns`, CodeSignOnCopy): läuft im Dock-Prozess, liest denselben Cache, Klick öffnet
  die URL. Handarbeit in der pbxproj (IDs `D7…`). Nach jedem Plugin-Build `killall Dock`.
  **Abnahme 1 scheiterte:** Dock zeigte nur „Optionen/Öffnen". Plugin lud im Testprozess einwandfrei;
  `amfid` im Log: „adhoc signed or signed by an unknown certificate chain" — das Dock lädt nur Plugins
  mit echter Zertifikatskette. Fix: `DEVELOPMENT_TEAM = 74U49TS6SR` (Mats' Apple-Development-Identität,
  Team-ID = OU des Zertifikats, nicht die Kennung in Klammern) in allen vier Automatic-Signing-Konfigs;
  App + Plugin tragen jetzt `Authority=Apple Development`. Nebenwirkung: neue Signatur ⇒ TCC-Grants
  (Mitteilungen, Bedienungshilfen) können neu fragen. Logs lesen mit `/usr/bin/log` — `log` ist in
  Mats' Shell ein Alias.
- **Runde 20 — Dock-Menü mit Quickstarts (27.08.):** `AppDelegate` (`@NSApplicationDelegateAdaptor`)
  liefert `applicationDockMenu` — Einträge aus `QuickstartStore` (gefüllt bei jedem `projekte --json`-
  Load, weil das Dock-Menü synchron gebaut wird), Klick → `NSApp.activate` + 0,1 s → Notification
  `.latexTermQuickstart` → `TerminalSplitView` des Key-Fensters (Fallback: erstes sichtbare) legt eine
  Home-Kachel an und ruft sofort `launch(in:command:label:)`. Dazu „Neue Home-Kachel" im Dock.
  Ordner/Befehle/Prompts stehen ausschließlich in `config.toml` der Werkstatt (`quickstarts[]`).
  Ohne Fenster passiert nichts — bekannte Lücke. Nicht abgenommen (App-Neustart nötig).
- **Runde 19 — Gesamtbild (Mats: „alles, was echte Verbesserung ist"):**
  *Laufende Kacheln:* Hinweisleiste über dem Baum „● <Projekt> wartet auf dich → zur Kachel"; in der
  Aktionsspalte ist „→ Zur Kachel" die erste Zeile, sobald hier (oder darunter) eine Kachel läuft —
  ⏎ springt dann hin statt aus Gewohnheit eine zweite Session daneben zu öffnen (Wartende zuerst).
  Verdrahtung: `showHome(otherPanes:focusPane:)`, Sprung per CWD über `TerminalSplit.focusPane`.
  *Wiedervorlagen:* fällige `~/.claude/wiedervorlage/*.md` als ⏰-Hinweis und, an der Wurzel, als
  Zeilen unter „Fällig"; ⏎ startet eine Session in der Wurzel mit dem Auftrag als erstem Prompt
  (`followUp`) — der SessionStart-Hook spielt die Datei ohnehin ein, der Prompt sagt „die hier, jetzt".
  *Optik:* Knopf-Zeilen (alles bis „Nur Shell") höher, mit leiser Fläche; die Liste dahinter kleiner.
  Der Kopf rechts ist kleiner und trägt, was der Baum nicht zeigt: Alias · CLAUDE.md-Kopf ·
  `⎇ main ↑2 · 3 geändert` · „aktiv vor 2 h" und darunter „» letzter Prompt" der Weiter-Session
  (auch als Tooltip der Weiter-Zeilen). Kontingente als Mini-Balken (█░) und farblich neutral —
  cyan/violett/orange/gelb gehören dem Baum; Kontext-Badge nicht mehr orange (orange = wartet),
  „compact" heller, „critical" rot. *Suche:* trifft auch Session-Titel („Japan" → `030_Reise`).
  **Entscheidung:** „primär" ist Position, nicht Typ — alles vor der ersten Listenzeile ist Knopf,
  auch „Weiter · Unterprojekt" eines Bereichs; sonst wäre genau die wichtigste Zeile die kleine.
- **Runde 18 — Neues Projekt, zwei Wege:** Der ⌘⇧N-Dialog hat jetzt Name · Alias · Zweck (ein Satz,
  optional) · Ort. Ort = Baumauswahl, per „Ändern…" ein Finder-Picker (NSOpenPanel, Ordner, darf
  anlegen), oder der zweite Radioknopf „noch offen — mit Claude klären": dann wird *nichts* angelegt,
  die Kachel startet in der Wurzel mit dem `placeCommand` des Templates (`--einordnen Name: Zweck`),
  und Claude erörtert den Ort. Der Zweck geht als Argument mit und spart die erste Interviewfrage.
  **Bewusst:** kein Finder-Dialog als Hauptweg — der Baum links *ist* der Ortswähler. Die App füllt
  nur `{purpose}`/`{name}`/`{alias}`; Apostrophe im Zweck werden zu ’ (einfaches Shell-Quoting).
  Radiobuttons ohne gemeinsames Target gruppieren sich nicht — `RadioSink` schaltet sie von Hand.
- **Runde 17 — Kontext exakt:** Die Prozentzahl an den Sessions stimmt jetzt: die Datenschicht liest
  das Modell samt Variante aus `modelUsage` (`claude-opus-5[1m]` → 1M-Fenster) statt es aus der
  Tokenzahl zu raten. Wo das Transkript zu alt für das Feld ist, bleibt es geschätzt und die Kachel
  schreibt „≈" vor die Zahl — lieber sichtbar unscharf als falsch genau.
- **Runde 16 — Reduzierter Baum:** „Nur Projekte" (⌘⇧B, Menü Home, Häkchen) blendet jeden Ordner
  aus, der weder Projekt/Bereich ist noch je eine Session hatte. Regel: sichtbar bleibt, was in
  `projekte --json` als Projekt steht — plus alle Ordner auf dem Weg dorthin (`relevantPaths`,
  Projektpfad + Elternpfade), sonst wäre nichts mehr erreichbar. Wurzel 13 → 3 Ordner,
  `01_Aktiv` 19 → 11. Dazu „Alles ausklappen" (⌘⇧A), das bewusst nur den relevanten Pfaden folgt
  — im vollen Baum zöge es sonst das halbe Dateisystem auf. Die Einstellung liegt in `UserDefaults`
  (`LatexTerm.homeOnlyProjects`, gilt für alle Home-Kacheln; Umschalten kommt als Notification),
  der Wurzelknoten trägt dann den Hinweis „nur Projekte" — sonst sucht man ausgeblendete Ordner.
  Tippen sucht weiterhin im *ganzen* Baum: der Reduktionsmodus ist eine Sicht, kein Käfig.
  Nachtrag: „Alles einklappen" (⌘⇧E) als Gegenstück — zwei Knöpfe statt eines Häkchens, weil
  Aus-/Einklappen Handlungen sind und keine Zustände: nach einem manuellen Aufklappen wäre ein
  Häkchen schlicht falsch. Der Aufklapp-Zustand bleibt in allen Fällen die Wahrheit auf Platte
  (`expandedPaths` → UserDefaults): die Knöpfe schreiben ihn mit, das Umschalten von ⌘⇧B nicht
  (dort `suppressExpansionSave`, sonst würde das Neuzeichnen die Handarbeit löschen) — im
  reduzierten Baum ausgeblendete Ordner behalten ihren gemerkten Zustand für die Rückkehr.
- **Runde 15 — Fußzeile ins Menü:** Die Dauer-Fußzeile (Button „✚ Neues Projekt", Tastenliste,
  Zeichenlegende) war eine Legende, kein Bedienelement — sie ist raus. Die Befehle stehen jetzt im
  eigenen Menü **Home** (Neues Projekt ⌘⇧N, Neu laden ⌘R, Session/Projekt anpinnen ⌘P/⌘⇧P,
  Umbenennen ⌘E, Angepinntes zeigen, Tastenhilfe ⌘/), alles Übrige (Pfeile, ⇥/⇧⇥, ⏎, Tippen,
  Zeichenlegende) in einer Tastenhilfe auf Abruf (⌘/, Esc oder Klick schließt).
  **Entscheidung:** ⇧⇥ bekommt *kein* Menükürzel — Menükürzel gelten fensterweit und würden
  Shift-Tab in Terminal-Kacheln schlucken (Claude Codes Modus-Umschalter). Es steht als Text im
  Menüpunkt. **Fund:** die Kachel gewinnt gegen das Menü — `performKeyEquivalent` der View-Hierarchie
  läuft vor dem Hauptmenü, und ausgegraute Menüpunkte verbrauchen ihr Kürzel nicht: ⌘R/⌘P/⌘E kommen
  in Terminal-Kacheln weiterhin unten an. Fokusquelle fürs Ausgrauen ist `HomeFocus.shared` (setzen
  nur der Gewinner, löschen nur man selbst — so ist die Reihenfolge zweier Fokuswechsel egal).
- **Runde 14 — Kontingente live:** Oben rechts in der Home-Kachel stehen 5h-Fenster, Woche und
  Modell-Woche mit Prozent und Reset-Countdown (auf der Grundlinie des Titels; ≥ 85 % rot). Der
  Countdown wird sekündlich neu gerechnet, die Zahlen alle 30 s über `projekte limits --json`
  nachgeladen — unter 10 Minuten Restzeit sekundengenau (`9:41`), sonst `1h38m` / `25m`.
  **Fund:** die 5h-/7d-Werte reicht Claude Code nur ins Statusline-JSON *innerhalb* einer Session;
  außerhalb liefert sie der OAuth-Usage-Endpoint (Token aus der Keychain) — das macht die Datenschicht,
  die App bekommt Label, Prozent, Farbnamen und `resetsAt` fertig serviert und bleibt generisch
  (`LatexTerm.limitsCommand`, Default `projekte limits --json`). Fehlt das CLI oder das Token, bleibt
  die Zeile leer statt zu meckern.
- **Runde 13 — Projekte anpinnen:** Pin-Screen (⇧⇥) hat jetzt zwei Blöcke, „Projekte“ oben und „Sessions“
  darunter (`PinGroup`, nicht wählbar, immer offen). Ein angepinntes Projekt zeigt rechts ＋ Neue Session,
  ↻ Weiter (letzte Session), › Nur Shell, ☆ Loslösen — der Griff „Projekt → neue Session“ ohne Baum.
  ⌘⇧P pinnt den gewählten Ordner (auch ohne CLAUDE.md), die ★-Zeile liegt hinter „▸ Mehr“; Daten aus
  `projekte pin-projekt|unpin-projekt` + `pinnedProjects` (Werkstatt).
- **Runde 12 — Aufgeräumte Aktionsspalte:** „zu unübersichtlich, nicht alles sofort einblenden“. Rechts
  stehen jetzt nur ＋ Neue Session, ↻ Weiter, › Nur Shell (+ Kompakt-Rat als Warnung) und eine Klapp-
  zeile „▸ Sessions (n ältere · anpinnen · umbenennen)“. → / ⏎ klappt auf (Pin, Umbenennen, Zuletzt
  hier/überall), ← klappt zu, Zustand in `LatexTerm.homeShowSessions`. ⌘P/⌘E wirken auf die markierte
  Session, sonst auf Weiter (`sessionInFocus`). Pin-Screen (⇧⇥) unverändert.
- **Runde 11 — Neue Session ist Standard:** Mats' häufigster Griff ist „Alias tippen, ⏎, neue Session" —
  darum steht ＋ Neue Session jetzt an erster Stelle (⏎ und Doppelklick im Baum), ↻ Weiter an zweiter,
  Shell & Co. danach. Reihenfolge wird in `renderActions` aus den Templates abgeleitet (Templates mit
  Befehl vor Weiter, ohne Befehl danach) — die Werkstatt bleibt Herr über die Einträge.
- **Runde 10 — Sessions umbenennen:** `projekte rename <id> [Titel]` schreibt nach
  `~/.config/projekte/namen.json`; der eigene Titel überstimmt den ai-title (`titleSource: manual`), leer
  = zurück auf automatisch. Home-Kachel: Template `rename` → ✎-Zeile bei der Weiter-Session und im
  Pin-Screen, ⌘E auf jeder Session-Zeile, NSAlert mit vorbelegtem Titel. `setPin` zu `runProjekte(args)`
  verallgemeinert — Argumente gehen als `"$@"` durch die Login-Shell, nie in den Befehlsstring interpoliert.
- **Runde 9 — Fokus aus einem Guss:** Klick in die andere Spalte änderte zwar den First Responder, die
  Dimmung/der Akzentbalken hingen aber am `becomeFirstResponder`-Hook + async-Nachprüfung und liefen
  bei Maus-Wechseln auseinander. Jetzt eine Wahrheit: KVO auf `window.firstResponder` → `focusDidChange()`
  (synchron, idempotent), die Tabellen machen sich im `mouseDown` explizit zum First Responder, und ein
  Klick ins Leere der Kachel fokussiert die Spalte unter der Maus (rechts nur, wenn es Aktionen gibt).
  Lehre: Fokus-Optik nie aus den Übergangs-Hooks ableiten, sondern aus dem Endzustand des Fensters.
- **Runde 8 — Aufklapp-Zustand + Suche von rechts:** Der gespeicherte Aufklapp-Zustand ging verloren, weil
  `reloadData()` (Statuswechsel alle 2 s, Filter) Collapse-Events feuert, die `saveExpansion` als Nutzer-
  aktion nahm. Jetzt: eigene `expandedPaths`-Menge als Wahrheit, Delegate-Events nur ohne
  `suppressExpansionSave`, Statuswechsel zeichnen Zeilen per `reloadData(forRowIndexes:)` nach. Tippen in
  der Aktionsspalte springt in die Baum-Suche; Pin-Toggle deshalb von `p` auf ⌘P.
- **Runde 7 (24.08. spät) — Pins, Kontext, Kompakten:** `projekte` liefert je Session `pinned` und
  `context` (letzte `usage` aus dem Transkript → Tokens, Prozent vom Modellfenster, advice ok/compact/
  critical) plus Top-Level `pinned` und die Templates `compact` (mit `followUp: "/compact"`), `pin`,
  `unpin`. Home-Kachel: ⇧⇥ = Pin-Screen (links die angepinnten Sessions statt des Baums, rechts ↻ Weiter /
  ⇣ Kompakten & weiter / ☆ Loslösen), `p` in beiden Spalten pinnt die markierte Session, Kontext-Badge
  („55%", orange ab compact, rot ab critical) rechts in jeder Session-Zeile; Kompakten-Zeile erscheint
  bei „Weiter" nur, wenn die Empfehlung greift. `TerminalPane.launch(followUp:)` tippt den Folgebefehl
  zweistufig (Text, 1 s später Enter), sobald die Session steht. Pins schreibt die Datenschicht
  (`projekte pin|unpin`, `~/.config/projekte/pins.json`) — die App kennt keine Dateien.
- **Runde 6 (24.08. spät) — sechs Befunde von Mats:** (1) Start-Overlay: Home bleibt als Vorhang mit
  Braille-Spinner liegen, bis `sessionState != .none` (passive Erkennung/Hook) oder 12 s — kein sichtbares
  Kommando-Paste, kein Plugin-Sync-Geflacker; nur-Shell zeigt sofort. (2) Tippen sucht mit Wortpause:
  > 1 s ohne Taste → nächstes Zeichen startet eine neue Suche; →/←/⇥ beenden die Suche und behalten die
  Auswahl. (3) Fokus-Spalte: die unfokussierte Spalte auf 55 % gedimmt, Akzentbalken nur bei Fokus, ⇥
  wechselt die Spalte. (4) Fußzeile: nur noch der Text-Button „✚ Neues Projekt", dim Hinweise, Legende.
  (5) Aufklapp-Zustand persistent (`LatexTerm.homeExpanded`, relative Pfade). (6) Legende der Baum-
  Glyphen in der Fußzeile + Tooltips je Zeile.
- **Runde 5 (24.08. abends) — Höhen-Einstiege aus `projekte`:** Mats' Frage „schreiben wir auf dieser
  Höhe Skills vor?" → Antwort: der Launcher erzwingt nur *Neues Projekt* (immer `/neues-projekt`), sonst
  bietet er höhentypische Einstiege als Zeilen an (Router/Bereich: „⌂ Wartungsgang" = `/claude-md .`;
  ohne CLAUDE.md: „✎ Zum Projekt machen" = `/neues-projekt --nachruesten`). Weil LatexTerm öffentlich
  ist, stehen diese Commands **nicht** in Swift: `projekte --json` liefert `actions` (resume/newProject/
  byLevel-Templates mit `{session}`/`{alias}`), die App rendert nur; ohne Templates Fallback Neu+Shell.
  Fußzeile = klickbare Buttons (Neues Projekt, Neu laden, Zoom, Schließen) statt Tastenlegende.
- **UX-Runde 4 (24.08. abends):** „einfarbig, unübersichtlich; soll aussehen wie Terminal + Statusline".
  → Home-Kachel nutzt jetzt die Terminal-Monospace in der persistierten Größe (`LatexTerminalView.storedFontSize`,
  jetzt intern sichtbar) und die xterm-256-Palette der `statusline-command.sh` (51 cyan Projekt/Neu, 77 grün
  Weiter/laufend, 111 blau Shell/Zeit, 171 violett Router/Bereich, 214 orange braucht Input, 220 gelb ohne
  CLAUDE.md). ⌘⏎ zoomt die Home-Kachel wie eine Terminal-Kachel (`onZoom` → `onZoomRequested`).
- **UX-Runde 3 (24.08. abends):** Mats' Kritik an Fassung 2: „Wo weiter?" zu wortreich, Zeit-Sortierung
  allein reicht nicht — man will auch *strukturell* navigieren. Erst Modus-Umschalter (⇥ Zuletzt/Struktur),
  dann erkannt: Modus = Denklast. Fassung 3 = Finder-Muster: Baum links, Aktionen des gewählten Ordners
  rechts; Root zeigt „Zuletzt überall". Enter = „Weiter" statt „Neu" — wer vor 20 min hier war, will
  weitermachen. Fußzeile fast weg (nur ⌘⇧N); Modifier-Tasten (⇧⏎/⌥⏎) durch sichtbare Zeilen ersetzt.
- **Fokus-Bug (Mats, 24.08. abends):** in der ⌘N-Home-Kachel gingen Tasten ins Nachbar-Terminal, ⌘W/⇥
  griffen nicht. Ursache: `HomePaneView.becomeFirstResponder` rief verschachtelt `makeFirstResponder(table)`
  und gab `false` zurück → AppKit stellte den alten Responder wieder her. **Regel:** Fokusziel direkt
  benennen (`focusTarget` = die Tabelle), nie in `becomeFirstResponder` umleiten.
- **Erster Live-Befund (Mats, 24.08. abends):** App startete mit normaler Shell — der Session-Snapshot
  (#11) hatte Vorrang vor Home; jetzt ist Home immer die erste Kachel. Erste Fassung der Ansicht
  (6-spaltige Tabelle + Detailspalte + Buttons + Hilfezeile + Kachel-Kopfzeile) war „hässlich,
  unintuitiv, überladen" → auf eine zweizeilige Liste reduziert, Sessions als zweiter Modus (→/←),
  keine Buttons, eine Fußzeile. Lehre: Cockpit-Ästhetik heißt *weniger* — die Titlebar-Punkte zeigen
  die anderen Kacheln schon.
- **Nicht live verifiziert (Fassung 1):** Claude arbeitete in einem LatexTerm-Fenster; Neustart hätte die
  Session gekillt. Build (Debug, Standard-DerivedData → `/opt/homebrew/bin/latexterm`-Symlink bleibt
  gültig) ist grün, Prüfliste unter HIER WEITERMACHEN in der CLAUDE.md.

 — ENTSCHIEDEN: Name bleibt LatexTerm, Reframing statt Rename)

**Namenssuche beendet. Mats' Entscheidung: der Name bleibt — nach 18 geprüften Namen in
6 Runden war keiner grün, und „LatexTerm" selbst erfüllt die Suchkriterien (frei, eindeutig,
googlebar) besser als fast alle Kandidaten.** Entscheidung + Begründung als Kommentar in #31;
Issue-Titel umbenannt auf „Reframing: README-Upgrade". Die Shortlist **Bellhop · Giverny ·
Juggler** bleibt dort mit Belegen dokumentiert, falls je ein Sichtbarkeits-Push ansteht —
erst dann lohnt der Rename-Rattenschwanz.

- [x] (2026-07-12 erledigt, Commit d000080, **#31 zu**) README-Upgrade mit minimal
  erweitertem Fokus: Intro-Absatz zur Cockpit-Seite, neue Sektion „Claude Code integration"
  (Status/Notifications + OSC-5522-Akzent dorthin verschoben, `latexterm`-CLI erstmals
  dokumentiert inkl. Symlink-Setup), „Why" um den Grid-Doppelnutzen ergänzt, Project layout
  um Control/ + LatexTermCLI/ vervollständigt. LaTeX bleibt Hero.
- [x] (2026-07-12 erledigt, **#25 zu**) **#25 v2 Live-Status-Pille in der Kachel:**
  schwebende Akzent-Pille oben rechts (`PaneStatusBadgeView`, rein visuell, zPosition
  über dem Terminal, vom Hüllen-Innenlayout ausgenommen) zeigt Tool-Name live
  (neuer globaler `PreToolUse`-Hook → `status=working;<tool_name>`), „arbeitet…"/
  „braucht Input" als Fallback; `Notification`-Hook schickt seine Message als Detail
  mit (auch im Notification-Body). WICHTIG: **Hook-Lease** — frisches Hook-Signal
  schaltet die passive Erkennung 10 min stumm (`lastHookStatusAt`), denn der Rater
  hielt Mats' Kickbacks-Statusline (`───`-Trennlinie) für die Input-Box → Pille
  flackerte. Nach Ablauf heilt der Rater abgestürzte Sessions (kein Stop-Hook bei
  Ctrl+C). Manuell verifiziert (Pille läuft stabil). Hook-Detail wird als untrusted
  Input gefiltert. Tool-Name in der Pille = Beweis, dass Hooks feuern (Rater kennt
  keine Tool-Namen).
- [ ] **Nächster Schritt: #28 v2 neu ausgerichtet (2026-07-12, Plan als Kommentar in #28,
  Issue wieder offen):** MCP nicht als lokale Zweit-Fassade (verworfen — CLI+Skill decken
  lokal alles ab), sondern als **Fernsteuerung vom Handy** über die Claude-App
  (Custom Connector / Remote MCP). Architektur: Claude-App → Cloudflare Worker
  (OAuth via `workers-oauth-provider`, nur MatsLuca) → Cloudflare Tunnel →
  MCP-Bridge auf localhost → bestehender `control.sock`. Etappen E1–E4 (lokale
  Bridge → Tunnel → OAuth+Connector → Bestätigungs-UX/Kill-Switch/Audit/SECURITY.md).
  Sicherheits-Kern: `send_text` = RCE auf dem Mac, deshalb OAuth nicht selbst bauen,
  Mac nie direkt im Netz, Lease-Bestätigung für schreibende Remote-Aktionen.
  Offene Entscheidungen (vor E3): Login-Provider, Bestätigungs-Modus, Bridge-Lebenszyklus.
- [x] (2026-07-12 erledigt) Nebenbefund aus #31: Vorgänger `LatexTerminalLive` liegt jetzt
  in `8_Archive/LatexTerminalLive_2026-07-12`.

## Archiv: Der Namens-Marathon (2026-07-06 bis 2026-07-12, abgeschlossen)

18 Namen per Websuche geprüft (6 Runden, je ein Subagent pro Name), alle Ergebnisse mit
Belegen als Kommentare in Issue #31. Kein grüner Name gefunden.

- **Runde 5+6 (2026-07-12, Asimov komplett):** Multivac 🔴 (Nische frei, aber die globale
  Verpackungsmaschinen-Firma MULTIVAC dominiert jede Suche + Abmahnrisiko) · Calvin 🟡
  (Allerweltsname, 8.834 GitHub-Repos, npm belegt, im AI-Branding mehrfach recycelt) ·
  Vivarium 🟡 (Tiling-Wayland-Compositor „vivarium" 420★ im Nachbarfeld, US-Marke „DIGITAL
  VIVARIUM", Labortier-Software-SEO) · **Daneel 🔴** (FydeOS' agentischer KI-Assistent heißt
  wörtlich „Daneel" + US-Marke DANEEL kurz vor Eintragung) · **Trantor 🔴** (npm-Paket
  `trantor` orchestriert wörtlich „Claude Code as live crews", ~6.700 DL/Monat, aktiv).
  Auffällig: zwei Asimov-Namen sind von Produkten besetzt, die selbst AI-Agenten/Claude
  orchestrieren — SF-Kanon ist in der Nische so überlaufen wie die Orchestrierungs-Metaphern.
- **Gesamttafel:** Baton 🔴 · Sigil 🔴 · Lattice 🔴 · Claudius 🔴 · Multivac 🔴 · Daneel 🔴 ·
  Trantor 🔴 · Ostia 🟡/🔴 · Mystic 🟡/🔴 · Theseus 🟡 · Bell 🟡 · Loge 🟡 · Salon 🟡 ·
  Calvin 🟡 · Vivarium 🟡 · Juggler 🟡 · **Bellhop 🟡 · Giverny 🟡** (die zwei saubersten;
  Giverny als einziger mit npm UND Homebrew frei).
- **Finale Shortlist (für einen etwaigen späteren Rename):** Bellhop („kommt, wenn die Glocke
  läutet" — Bell Labs + BEL-Notification-Feature) · Giverny (Monets Zuhause = „Claudes
  Zuhause") · Juggler (Shannons Jonglier-Roboter, viele Bälle in der Luft).
- **Muster-Erkenntnis:** Die Agent-Orchestrierungs-Nische ist 2025/26 explodiert — naheliegende
  Metaphern (Dirigent/Staffel/Zeichen/Gitter) sind alle von Produkten in exakt dieser Nische
  besetzt. Claude-Wortspiele sind doppelt riskant: „CLAUDE" ist eingetragene Anthropic-Marke,
  Anthropic nannte seinen Project-Vend-Agenten selbst „Claudius", und es gibt bereits zwei
  Claude-Code-Tools namens „Claudius".
- **Abgegraste Namensadern:** Orchestrierungs-Metaphern (Alt-Liste in #31) · Claude Shannon
  (Theseus/Juggler/Minivac/Bell/Bellhop/Mystic) · andere Claudes (Monet → Giverny/Salon/Atelier;
  Debussy → Clair; Kaiser Claudius → Ostia/Palatine/Claudius) · Modellnamen Haiku/Sonnet/Opus →
  Bühne (Loge/Stanza/Libretto) · Asimov komplett (Multivac/Calvin/Vivarium/Daneel/Trantor;
  Terminus verbrannt — Terminal-Emulator musste deshalb schon zu „Tabby" umbenennen).
- Alt-Kandidaten Choir/Tessera/Facet/Agentty/Conclave aus #31 blieben ungeprüft — durch die
  Bleiben-Entscheidung hinfällig.

---

## Nebengleis: Claude-for-OSS-Bewerbung (2026-07-07, abgeschickt auf gut Glück)

**Beim [Claude-for-Open-Source-Programm](https://claude.com/contact-sales/claude-for-oss) mit
LatexTerm beworben — bewusst als Long Shot, ohne erfüllte Eligibility.** Das Programm gibt
**6 Monate gratis Claude Max 20x** an OSS-Contributor.

- **Realität:** LatexTerm erfüllt **keine** der fünf Kategorien (500+ Dependents / Foundation-Core-
  Contributor / 100+ gemergte Fremd-PRs in 12 Mon. / 20+ externe Contributor / OpenSSF-Criticality
  ≥ 0.4). Ist-Zahlen: 1 Stern, Solo-Repo, 0 externe PRs. Eingereicht über die „passt nicht ins
  Raster, hier ist mein Beitrag"-Kulanztür. **Erwartung: eher Absage.**
- **Verkaufswinkel (bewusst ehrlich gehalten, keine Zahlen erfunden):** Mission = Claude Code für
  Nicht-Entwickler zugänglich machen, speziell **Schüler/Studierende, die in LaTeX arbeiten**;
  LatexTerm schließt die „Mathe im Terminal unlesbar"-Lücke; dazu das offene
  `claude-config`-Ökosystem als community-nahes Tooling.
- **Formularfelder (alle EN, ausgefüllt):** *Reach & impact* · *How will you use the subscription*
  · *Other info*. Texte waren zuletzt in `/tmp/claude-501/copy.txt` (flüchtig).
- [ ] **Falls Absage / falls ernsthaft verfolgt:** Der einzige selbst erreichbare Weg ist
  Kategorie #4 (20+ externe Contributor) → braucht Sichtbarkeits-Push (Show HN, r/macapps,
  LaTeX-/Terminal-Communities, „good first issue"-Labels). Monatsprojekt, kein Antrag. Hängt am
  #31-Rebranding (erst Name/Positionierung klären, dann öffentlich pushen).

---

## Vorheriger Stand (2026-07-06, Nacht — Rebranding-Frage)

**Neudenken-Session: Ziel & USP hinterfragt → alles in Issue #31 festgehalten (offen).**

- **Anlass:** Live-Demo des Steuerkanals — eine CC-Session hat per `latexterm`-CLI zwei Kacheln
  geöffnet, darin je eine neue Claude-Instanz (`yolo`) gestartet und geprompt (zweistufiges
  `send`, siehe Skill). Erste echte Multi-Instanz-Orchestrierung end-to-end; dabei aufgefallen:
  der `list-panes`-Status (`awaitingInput`) hinkt bei laufender Claude-TUI sichtbar hinterher.
- **Befund (belegt aus Commits/Issues):** Zwei Epochen — LaTeX-Terminal (Mai–Juni, Roadmap #13
  komplett fertig) vs. Claude-Cockpit (seit #29, 03.07.; seither trägt jeder Feature-Commit das
  Label `claude-code`). Der Zweck-Pivot ist intern entschieden, aber Name/README/Positionierung
  erzählen noch die alte Story. **Urteil: Rebranding ja, Rebuild nein** — Architektur (eigenes
  Grid, Zwei-Richtungen-Grundsatz) trägt den neuen Zweck perfekt.
- **Namens-Brainstorming (mats-Agent), Top 3:** Baton, Sigil (`$` ist wörtlich ein Sigil —
  Icon-Kontinuität), Lattice. Elf Kandidaten + Warnungen (Maestro/Relay/Prism/Helm vorbelegt)
  in #31; Kollisionschecks waren aus dem Kopf, vor Wahl googeln.
- [ ] Offen (Checkliste in **#31**): Positionierung Claude- vs. Agent-Cockpit → Namens-
  Kollisionscheck → Rename komplett vs. Reframing → README-Neuschnitt (Cockpit-Demo als Hero,
  LaTeX als Sektion) → bei Rename: Repo/Bundle-ID/CLI/Symlink/`LATEXTERM_PANE_ID`/Hooks/
  mats-tools-Skill nachziehen.
- [ ] Offen: Vorgänger-Projekt `LatexTerminalLive` (unter `4_Projekte/01_Aktiv/`) nach
  `8_Archive/` verschieben.

---

## Vorheriger Stand (2026-07-06, Abend)

**#27 Vollausbau (Hook→OSC-Statuspfad) + OSC-7-Fix — implementiert, END-TO-END VERIFIZIERT
(Screenshot der Notifications), committet. #27 zu.**

- **OSC 5522 `status=<working|input|done>[;detail]`** (`TerminalPane.applyHookStatus`): setzt
  `sessionState` ohne Hysterese, `input`/`done` feuern Notifications über den bestehenden
  `onAttentionSignal`-Pfad (unbeobachtet-Check + 5-s-Cooldown sitzen dort). `done` → `.none`
  bewusst: die danach sichtbare Input-Box darf passiv kein working→awaitingInput mehr auslösen.
  Neu: „Claude ist fertig"-Notification.
- **Sender = drei globale CC-Hooks** (`UserPromptSubmit`/`Stop`/`Notification` in
  `~/.claude/settings.json`, async). WICHTIGER Empirie-Fund: CC-Hooks laufen OHNE
  Controlling-TTY (`/dev/tty` = „Device not configured"; ein `2>/dev/null||true`-Wrapper
  verschleiert das — Probe-Hook nutzen!). Der Einzeiler holt die Pane-Leitung über
  `t=$(ps -o tty= -p $PPID)` und schweigt ohne `$LATEXTERM_PANE_ID`.
- **Claude kann LatexTerm jetzt überall steuern**: `latexterm`-Skill im mats-tools-Plugin
  (claude-config-Repo, Commit a380210) + Symlink `/opt/homebrew/bin/latexterm` →
  DerivedData-Debug-Bundle (bei App-Umzug nach /Applications einmal neu setzen).
- Passive Erkennung (#30) bleibt als Fallback voll aktiv; Bell/OSC 777 unverändert.

- [ ] Offen: #25 v2 (Live-Status-Text in der Kachel, z. B. Tool-Name) kann jetzt trivial auf
  `status=` aufsetzen (detail-Feld existiert schon, Hooks liefern es nur noch nicht).
- [ ] Offen: `tools/validate.sh` in claude-config kennt `skills/` noch nicht (Frontmatter/
  Listing-Sync ungeprüft für Skills).

---

## Vorheriger Stand (2026-07-06, spät)

**#28 v1 Steuerkanal + `latexterm`-CLI — implementiert, Build + 34 Tests grün, manuell
END-TO-END VERIFIZIERT (aus einer Kachel heraus: list-panes/--json, new-pane --cwd --exec,
send per Index/UUID-Präfix/--no-enter, zoom, focus via $LATEXTERM_PANE_ID-Fallback,
Fehlerfälle mit Exit 1), committet.**

Was drin ist:
- **Pane-Identität**: `TerminalPane.start()` gibt jeder Shell `LATEXTERM_PANE_ID=<uuid>` mit
  (Basis für Hooks/CLI, das „verbindende Stück" aus #29).
- **`Control/ControlProtocol.swift` + `Control/ControlServer.swift`** (neu): Unix-Socket
  `~/Library/Application Support/LatexTerm/control.sock` (0600 + getpeereid = nur gleicher User,
  als Fläche in SECURITY.md dokumentiert), Protokoll = eine JSON-Zeile Request → eine JSON-Zeile
  Response → Verbindung zu. Handler ist `TerminalSplitView.handleControl` (Extension am Datei-Ende
  von `TerminalSplit.swift`, damit `panes`/`toggleZoom` privat bleiben; `DispatchQueue.main.sync`).
- **CLI `latexterm`** (`LatexTermCLI/main.swift`): `list-panes [--json]`, `new-pane [--cwd]
  [--exec]`, `send [--pane] [--no-enter] TEXT…` (Enter default AN — Mats' Wahl), `zoom`, `focus`.
  Ohne `--pane` gilt `$LATEXTERM_PANE_ID` (= die eigene Kachel, gut für Hooks). Pane-Selektor:
  reine Ziffern = IMMER 1-basierter Index aus `list-panes`, sonst case-insensitives UUID-Präfix
  mit Genau-ein-Treffer-Regel (mehrdeutig = Fehler; `send` in die falsche Shell wäre
  Command-Execution). Exit-Codes 0/1/2/3 = ok/App-Fehler/Usage/nicht erreichbar.
- **Xcode-Verdrahtung** via `scripts/add_cli_target.rb` (idempotent; mit **System-Ruby**
  `/usr/bin/ruby` ausführen — Homebrew-Ruby hat kein xcodeproj-Gem). Zwei Stolperfallen, die das
  Script jetzt selbst umschifft: (a) Target/Modul heißen `LatexTermCLI`, nur die Binary
  `latexterm` — ein Target namens `latexterm` kollidiert auf case-insensitivem APFS mit
  `LatexTerm` (identisches Intermediates-Verzeichnis; die App überschreibt dann still die
  SwiftFileList des CLI → Geister-Fehler); (b) ältere xcodeproj-Gems persistieren `productType`
  für `:tool` nicht → Xcode 26 verweigert mit „productTypeIdentifier missing"; (c) eingebettet
  wird per Copy-Files-Phase (CodeSignOnCopy) nach `LatexTerm.app/Contents/Helpers/latexterm` —
  NICHT nach Contents/MacOS, dort überschriebe `latexterm` die App-Binary `LatexTerm`
  (APFS case-insensitiv; die App startete dann als CLI und beendete sich sofort). Außerdem
  `SuppressBuildableAutocreation` fürs CLI-Target, sonst schaltet Xcode das aktive Schema um
  und Cmd+R startet die CLI statt der App.

- [x] (2026-07-06 erledigt) Symlink-Komfort: liegt jetzt in `/opt/homebrew/bin/latexterm`
  (user-owned, kein sudo) statt `/usr/local/bin` — Details im Stand-Block oben.
- [x] (2026-07-06 behoben) `list-panes` zeigte CWD als „?": OSC 7 kam nie an, weil
  `TERM_PROGRAM` leer war — `/etc/zshrc` lädt Apples `update_terminal_cwd`-Hook nur bei
  `TERM_PROGRAM=Apple_Terminal`. Fix: `TerminalPane.start()` setzt genau das (bewusste
  Schummelei, Mats' Wahl gegen einen eigenen zshrc-Eintrag). Apples Session-Save bleibt aus,
  solange KEIN `TERM_SESSION_ID` gesetzt wird. End-to-end verifiziert (list-panes + new-pane).
  Achtung fürs #30-Umfeld: TERM_PROGRAM ist jetzt nicht mehr leer (iTerm2-Pfade in CC bleiben
  trotzdem aus, „Apple_Terminal" ≠ iTerm).
- [ ] Danach laut #29: #27/#25 Vollausbau über Hook→OSC-Pfad; #28 v2 (MCP) als Kür.

---

## Vorheriger Stand (2026-07-06)

**#30 Passive Statuserkennung + nativer Bell-Hook — implementiert, manuell END-TO-END VERIFIZIERT
(Notification kam, Auslöser war der passive Pfad), committet & gepusht, #30 zu.**

Debug-Erkenntnisse aus der Verifikation (wichtig für künftige Arbeit an der Erkennung):
- CC 2.1.201 zeigt **kein „esc to interrupt" mehr** (Hinweis wird zur Laufzeit aus der
  Keybinding-Tabelle gebaut und fehlt teils ganz). Working-Anker sind deshalb zweigleisig:
  Suffix „ to interrupt" ODER Spinner-Glyphe (✻✶✳✽·∗*) als erstes Zeichen + „…" in der Zeile.
  „✻ Worked for 38s" (ohne „…") wird korrekt NICHT als working gewertet.
- CC hat trotz erzwungenem `preferredNotifChannel: terminal_bell` (in ~/.claude/settings.json
  gesetzt, 2026-07-06) im Test **keine BELL** geschickt — passive Erkennung trägt das Feature
  allein, Bell/OSC-777 bleiben als Bonus-Sofortpfad drin.
- Ground-Truth-Log: `/tmp/latexterm-status.log` (DEBUG-Build; RAW-Wechsel mit Zeilen-Dump,
  COMMITs, BELL, NOTIFY-Entscheidungen, AUTH).

Was drin ist:
- **Fork**: `getLiveLine(row:)` auf `Terminal` (yBase-verankert, siehe Patch-Liste oben).
- **`TerminalPane` (TerminalSplit.swift)**: `SessionState` (.none/.working/.awaitingInput),
  `detectSessionState()` (untere 12 Live-Zeilen: „esc to interrupt" = working; Box-Drawing-Zeile
  farb-agnostisch = awaitingInput), läuft auf dem 0,3-s-Ticker — der `isAdaptiveAccent`-Gate wurde
  dafür vom `scheduleContrastAnalysis()`-Eingang IN den Tick verlegt (Status läuft immer).
  Hysterese in `registerSessionScan`: 5 Scans (~1,5 s, Mats' Wahl „sehr sicher") für awaitingInput,
  2 für Rest; legt sich Folge-Scans selbst nach (Scans sind output-getrieben — nach Claudes letztem
  Redraw käme sonst nie die Bestätigung). Bestätigtes working→awaitingInput feuert
  `onSessionAwaitingInput`.
- **Native Kanäle**: `LatexTerminalView.bell(source:)`-Override → `onBell`; OSC-777-Handler
  (`notify;title;body`) via `registerOscHandler` (überschreibt SwiftTerms eingebauten 777er) →
  `onAttentionSignal`. Sofort-Auslöser ohne Hysterese; CC nutzt default `terminal_bell`
  (preferredNotifChannel ungesetzt, TERM_PROGRAM leer → kein iTerm2-Pfad).
- **`SessionNotifier.swift` (neu)**: UNUserNotification „Claude braucht Input", Pane-UUID als
  Identifier, 5-s-Cooldown pro Pane (Bell + passiver Pfad melden sonst doppelt), Banner auch bei
  aktiver App, Klick → `TerminalSplitView.activatePane(id:)` = App nach vorn + Fokus + Zoom.
  Meldung nur wenn unbeobachtet (App inaktiv ODER andere Kachel fokussiert). Auth lazy.
- **#25 v1**: Titlebar-Session-Punkt (`PaneDotView`, neuer `pulsing`-Param) pulsiert bei working.

- [ ] Nichts in Arbeit — bei Wiederaufnahme: Reihenfolge aus #29 (als Nächstes #28 Steuerkanal
  v1: `LATEXTERM_PANE_ID`-Env-Var + Socket/CLI; danach #27/#25 Vollausbau über Hook→OSC-Pfad).

---

## Vorheriger Stand (2026-07-03)

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

**Neue Roadmap: Claude-Code-Integration — Tracking-Issue #29** (Label `claude-code`, Issues #24–#28).
LatexTerm wird fast nur für Claude Code genutzt → gezielt darauf optimieren. Architektur-Grundsatz
(in #29 ausformuliert): CC-**Hooks/Statusline** für Events Richtung Terminal (fertig/braucht Input/
Status/Farbe — kein Terminal-Text-Parsing), lokaler **Socket + `latexterm`-CLI** für Steuerung
Richtung Terminal (Panes öffnen/prompten), MCP-Server nur als spätere zweite Fassade; Bindeglied
ist eine `LATEXTERM_PANE_ID`-Env-Var je Shell. Empfohlener Einstieg: **#26 Pane-Zoom** (kein
Integrations-Aufwand), dann #24 v1 (passive Farbextraktion), dann Infra (#28) → #27/#25.
- [ ] Nichts in Arbeit — bei Wiederaufnahme: Reihenfolge aus #29.

---

## Vorheriger Stand (2026-06-12)

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
- **#22** Diese Doku, Root-CLAUDE.md (Test-Target-Satz), SECURITY.md (AX-PTY-Injection + Cmd-Klick als dokumentierte, bewusste Flächen).

---

## Vorheriger Stand (2026-06-11)

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

**Verifikations-Workflow (manuelles UI-Testen):** ⚠️ **Claude Code läuft selbst in einem LatexTerm-Fenster** — `pkill -f LatexTerm` killt den eigenen Host und die Instanzen-Jonglierung ist wertlos. Außerdem dedupliziert LaunchServices über die Bundle-ID, d.h. ein direkt gestartetes `.build`-Binary wird von einer bereits via Xcode laufenden Instanz verdrängt (→ Env-Vars wie `LATEXTERM_SCAN_LOG` greifen nicht). **Robuster Weg:** der User baut+startet selbst per **Xcode Cmd+R**; Diagnose-Logging in `#if DEBUG` *immer an* (kein Env-Gate) und **direkt in eine Datei** schreiben (`FileHandle`, z.B. `/tmp/…`) statt NSLog/os_log, dann die Datei auslesen. Der Standalone-`.build`-Run wirft harmlose WebContent-Sandbox-Fehler — kein echtes Problem.
