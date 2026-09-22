# HISTORIE — LatexTerm

## 2026-09-22 — Scratchpad ausgebaut

**Anlass (Mats):** Die Malfläche war nur ein Beispiel fürs Kachel-Protokoll — jetzt ein „basic cooles Scratchpad“ mit Farben,
Speichern, ⌘Z und Radierer.

**Gebaut:** schwebende Werkzeugleiste (hochkant, quer wenn die Kachel zu flach ist): Stift, Marker (halbdeckend, unter der
Tinte), Radierer (löscht ganze Striche, Rechtsklick radiert immer), sieben Farben als Index ins Theme (Theme-Wechsel färbt mit),
drei Stärken, Undo/Redo als Schritt-Stapel (ein Radier-Zug = ein Schritt, Leeren rückgängig machbar), Striche geglättet,
⇧ = gerade Linie, Zeiger als Kreis in Werkzeuggröße. Tasten P/M/E, 1–7, +/−, ⌘Z/⇧⌘Z, ⌘⌫, ⌘S (PNG, Dialog), ⌘C (Bild).
Sicherung bei jeder Änderung nach `Application Support/LatexTerm/scratchpads/<id>.json` → kommt nach ⌥⌘R wieder; ⌘W löscht
sie, Waisen nach 30 Tagen. `close-pane` ohne `--force` lehnt ein bemaltes Scratchpad ab. `send save <pfad>` schreibt ein
zugeschnittenes PNG — der Weg, auf dem Claude eine Skizze ansehen kann.

## 2026-09-22 — MCP-Server `latexterm mcp`

**Anlass (Mats, per 42 erörtert):** Der Werkstatt-Skill `latexterm` sprang manchmal nicht an — dann wusste Claude
nichts von den Kacheln. Wunsch: Claude versteht, dass es im Gesamtsetup sitzt, nutzt Kacheln „ganz natürlich“, und das
wächst mit jeder neuen Kachelart mit, ohne Skill-Pflege.

**Entscheidung:** MCP-Server als Unterbefehl `mcp` im vorhandenen CLI (Swift). Gleicher Socket-Code und dieselbe
`ControlProtocol.swift` → App und Server laufen nicht auseinander. Schicht auf dem Steuerkanal, kein Ersatz (Mods,
Hooks, Launcher bleiben beim CLI). Verworfen: Node/TS-Server (zweite Laufzeit), Mod-Werkzeuge per `$.tool.register`
(nur Claude, early access), `.mcp.json` im Bridge-Plugin (nur Wrapper-Sessions, Codex nicht).

**Gebaut:**
- Werkzeuge auf Absichts-Ebene + je App-Kachelart `open_<art>` aus der neuen Selbstbeschreibung (`PaneContent.manual`
  Pflicht, `pane-kinds` → `kindInfos`). Alte App ohne Handbuch → generisches Schema.
- Lagebild in `instructions` (eigene Kachel, andere Kacheln, wofür Kacheln gut sind).
- Schutz als Bauart: `new-pane` mit `focus: false` (neu im Protokoll, CLI `--no-focus`), kein `force`, nie in die eigene
  Kachel, `run_in_pane` nur in ruhende Shells (neues `PaneInfo.foreground`), fremde Kacheln schließen nur mit `foreign`.
- Briefkasten gehört jetzt zum Protokoll (`ControlProtocol.mailboxPath`); `ask_session` schreibt atomar, wartet auf
  Abholung und fällt ohne Empfänger auf zweistufiges Einfügen zurück. `start_agent` gibt den ersten Prompt nicht in die
  Befehlszeile (frische PTY puffert vor dem Shell-Start nur ~1 KB), sondern stellt ihn nach dem Start zu.
- `open_web` mit derselben Datei lädt die offene Kachel neu statt zu stapeln (`PaneInfo.args`).

**Geprüft:** `scripts/test-mcp-server.swift` (Fake-App: Werkzeugliste, alle Schutzregeln, Briefkasten mit/ohne Empfänger,
Wiederverwendung, alte App), stdio-Handtest gegen die laufende App, `claude -p` und `codex exec` sehen Werkzeuge und
Lagebild. Lehre: Codex filtert die Env für MCP-Server — ohne `env_vars = ["LATEXTERM_PANE_ID"]` sähe der Server keine Kachel.

## 2026-09-22 — Kachel-Protokoll: Kacheln, die kein Terminal sind

Anlass: Mats will Kacheln, die kein Terminal sind (erste Idee: ein Scratchpad zum Malen) — „wenn, dann
richtig“: eine Grundinfrastruktur statt eines weiteren Home-Tricks. Bauplan in der claude-werkstatt
(`plans/kachel-protokoll_2026-09-22.md`), Branch `kachel-protokoll`, ein Commit je Schritt.

Befund vorher: `TerminalPane` war alles in einem, die Split-View griff an 29 Stellen direkt darauf zu,
13 optionale Closures als Rückkanal. Drei Dinge lagen doppelt: Kachel-Kürzel (Terminal-View, Home, Menü),
Fokus-Meldung (je Inhaltsansicht per `becomeFirstResponder`) und die Hüll-Optik (auf `TerminalPane`
gerechnet, auf der Hülle gemalt).

Gebaut (Schritte 1–8): die Hülle `PaneContainerView` besitzt die ganze Kachel-Optik und verteilt
⌘T/⌘W/⌘1–9/⌘⏎; die Split-View beobachtet `window.firstResponder` per KVO als einzige Fokus-Wahrheit
(setzt `hasFocus`, Fenstertitel, Titelleiste); `PaneHost` ersetzt die Closures; `Pane` ist das Protokoll,
das die Split-View spricht (`[any Pane]`, drei kommentierte `as? TerminalPane`); `AppPane` ist der eine
Wirt für App-Kacheln, `PaneContent` das Inhalts-Protokoll, `PaneKindRegistry` die Wahrheit für Menü,
Steuerkanal und Restore. Erste Arten: `scratchpad` (Malfläche) und `web` (lokale HTML-Datei). Steuerkanal:
`new-pane --kind … --arg k=v`, `pane-kinds`, `kind` in `list-panes`. Neue Kacheln stehen oben im Menü
„Kachel“ (File → Neu ist leer). Schritt 9 (Snapshot v2) kam vorgezogen als „Neu starten mit Kacheln“
(Eintrag unten), App-Kacheln mit `snapshotArgs` (web) kommen nach ⌥⌘R wieder.

Abweichungen vom Plan: `Pane` bewusst ohne Protokoll-Defaults (eine um ein Zeichen vertippte Signatur
bekäme sonst still den Default); `receive(_:enter:)` statt `receive(_:)`; die Registry wirft
`PaneArgsError` mit Grund statt `init?`; `PaneContent.menuArgs()` für Arten mit Pflicht-Args (web öffnet
im Menü einen Dateidialog).

Lehren: **⌘T erbte seit jeher das Verzeichnis der ältesten Terminal-Kachel**, nicht der fokussierten —
`performKeyEquivalent` läuft in Subview-Reihenfolge und ⌘T hatte als einziges Kürzel keinen Fokusfilter;
mit der Hülle als einzigem Verteiler behoben. **Unter einer Home-Ansicht liegt ein ungestartetes Terminal**
in derselben Hülle; ohne eigenen Fokus-Check öffnete es bei ⌘F eine unsichtbare Suchleiste — der Check
bleibt im Terminal. **WKWebView schluckt Kürzel** und reicht unerledigte nur ans Menü: darum kommen
⌘T/⌘W/⌘1–9 vor dem Inhalt dran, ⌘⏎ erst danach (die ⌘K-Palette belegt es als Zweitaktion).
Abdunkeln greift auch auf WebKit-Inhalt (Hüll-Alpha). Leck-Probe: DEBUG-Zeile „PANE <art> freed“ in
`/tmp/latexterm-status.log` nach jedem Schließen — für Terminal (⌘W und `exit`), Scratchpad und Web
gesehen. Pixelvergleich vor/nach Schritt 1–2: fokussiert (22,20,20), gedimmt (40,39,39), Steg (73,73,73)
identisch. Prüfliste `docs/pruefliste-kacheln.md`; Mats hat nach Schritt 2, 5 und 8 abgenommen
(„passt alles“, „alles funktioniert“).

## 2026-09-22 — Neu starten mit Kacheln

Anlass: Mats baut LatexTerm in LatexTerm. Nach jedem Build hieß es ⌘Q, wieder öffnen und jede
Session im Home per „Weiter“ suchen. Neu im App-Menü über „Beenden“: **Neu starten** (⌥⌘R) und
**Beenden und Kacheln merken** (⌥⌘Q, wie macOS' „Beenden und Fenster behalten“). Beide laufen
durch `applicationShouldTerminate` samt `VMQuitGuard`. Erst `applicationWillTerminate` schreibt den
Snapshot mit Marke `restoreOnce`; ein abgebrochenes Beenden setzt sie zurück. „Neu starten“
startet danach `AppRelaunch`: ein losgelöster `/bin/sh` wartet auf das Prozessende (max. 60 s)
und öffnet dann das eigene Bundle, also den frisch gebauten Debug-Build. Vorher zu öffnen ginge
nicht, denn LaunchServices aktivierte nur die alte Instanz. Arbeitet eine Kachel noch, fragt die
App vorher nach. Normales ⌘Q startet weiter mit Home (Entscheidung 24.08. unverändert).

Snapshot v2 (Kachel-Protokoll §3.7), gegenüber dem Plan um Fenster erweitert:
`{version: 2, windows: [{panes: [{kind, args}], focused, zoomed}], restoreOnce}`. v1 wird
übersetzt. Terminal-Args: `cwd`, `agent`, `session`, `accentName`; Home = `kind home`.
Geschrieben wird einmal zentral für alle Fenster (vorher schrieb jedes Fenster, das letzte
gewann). `SessionStore.takeRestore` löscht die Marke **vor** dem Wiederherstellen, damit ein
gescheiterter Start nicht in Schleife wiederherstellt.

Wiederherstellen (`RestoreStep`, Foundation, getestet): Agenten-Session → Home-Kachel, die nach
dem Laden einmal „Weiter“ ausführt. Das ist derselbe Weg wie der Klick: Claude über
`actions.resume` und Projektpfad der Session (sonst gemerktes CWD), Codex über `resumeAction`
aus `agentSessions`. Farbe, Farbzeile und Vorhang sind identisch; der alte Farbname bleibt,
solange er zur Familie gehört und frei ist. Kachel ohne Identität, mit vim/ssh oder mitten im
Start → Shell im CWD. Home → Home, unbekannte Art → Home. IDs und Farbnamen werden wie im
Steuerkanal geprüft. Jedes neue Fenster holt sich sein Fenster; was macOS nicht wieder öffnet
(„Fenster beim Beenden schließen“), hängt das erste Fenster nach 1,5 s als Kacheln an.
Wiederhergestellte Kacheln nehmen Vorhang-/Terminal-Fokus nur, wenn sie ihn schon haben;
Fokus und Zoom kommen zurück. Ein Kaltstart-Quickstart übernimmt keine Home-Kachel, die gleich
fortsetzt.

Grenzen: Codex-Session nicht in `projekte --json` (älter als das Ordnerlimit) → Home bleibt,
Ordner ausgewählt. Schlägt `projekte` beim Start fehl, wartet der Auftrag auf ⌘R. Ein laufender
Turn bricht beim Neustart ab (daher die Rückfrage). Der Vorhang erscheint erst, wenn Home
geladen hat (kurz ist Home sichtbar).

Verifiziert: `scripts/test-session-restore.swift` (32 Fälle: Codec v1/v2, Indizes, Restore-
Regeln inkl. unsicherer IDs, Marke genau einmal, Fensterverteilung, Neustart-Helfer mit echtem
Prozess), in `test-regressions.sh`; 63 native Xcode-Tests; Compile-Check im Worktree
`sitzung-merken`. **Keine Live-Abnahme** — die App wurde bewusst nicht gestartet (zweite
Instanz übernähme den Socket); Prüfung nach dem Merge.

## 2026-09-22 — Explizite Agenten-Sessions und fensterübergreifendes Cockpit

`AgentSession` bindet Anbieter und echte Session-ID, optional Turn-ID. Ein fremder/alter Turn
oder Legacy-Status überschreibt keine identifizierte Session. `ready` bindet, `closed` löst;
der PTY-Vordergrundprozess räumt bei Exit/Wechsel auch ohne Abschluss-Hook auf. Der Claude-Mod
meldet die Engine-Session-ID. Codex nutzt einen stillen Python-Sender für acht offizielle
Lifecycle-Hooks: keine Transkriptanalyse, keine TTY-Schreibzugriffe, kurze Socket-Timeouts,
Capability-Abfrage vor dem ersten Status und Abgleich der emittierenden Prozessgruppe.
Der Installer bewahrt andere Hooks/notify-Einstellungen und sichert ersetzte Dateien.

`ControlRouter` hält alle Fenster schwach referenziert. `list-panes`, Index/UUID-Präfix,
Fokus und Notification-Klick haben damit ein gemeinsames Zielverzeichnis. Home nutzt
Anbieter + Session-ID für bereits verbundene Sessions; gleiche CWDs reichen nicht.
Zwischen Start und erstem Hook gibt es noch keine Bindung und keine Startreservierung.
Status-Einstellungen heißen „Agenten“, Claude-spezifische Optionen bleiben benannt.
Verbundene Sessions heißen in Suche/Aktionen „Zur Kachel“ und tragen ihren Live-Status.
Nur die fokussierte Kachel im Key-Fenster gilt als beobachtet; Hintergrundfenster behalten
zwar ihren AppKit-First-Responder, unterdrücken dadurch aber keine Benachrichtigungen mehr.

Dokumentation berichtigt: Status läuft seit 21.09. über den Socket, globale OSC-Fallback-Hooks
sind entfernt. Neustarts öffnen Home; die gespeicherte Verzeichnisliste wird derzeit nicht
wiederhergestellt. Overlay-Identität hängt an Spalte/Inhalt/Vorkommen, Position am Raster.
Der frühere Projektstand ist unten unverändert archiviert. Alte Sichtprüfungen sind weiterhin
als solche markiert; Tests sind kein Beleg für eine Nutzerabnahme.

Verifiziert: 63 native Xcode-Tests; eigenständige Swift-Regressionen für Launcher, VM,
Identität und Routing; 11 Python-Hook-/Installer-Tests. Abschließender Debug-Build in
Default-DerivedData signiert und mit `codesign --verify --deep --strict` geprüft.
Live-/Sichtabnahme des neuen Prozesses nach Nutzer-Neustart steht noch aus.

## 2026-09-22 — Launcher-Regressionen in CI und VM-Beenden abgesichert

Die eigenständigen Launcher-Tests waren nicht an CI angeschlossen: Suchtests riefen nach dem
Paletten-Umbau noch das entfernte `score` auf, der vollständige AppKit-Test verwendete den alten
Paletten-Initializer und veraltete Präsentations-Stubs. Beide aktualisiert; Suchtests decken zusätzlich
Rangfolge, Unicode-Hervorhebung und fehlende Session-Identität ab. `bash scripts/test-regressions.sh`
führt dieselben 42 Launcher-Fälle lokal und in CI aus (Suche, Codex-Start, Pfadgrenzen, Fokus und
vollständige Tastatureingabe in unsichtbaren AppKit-Fenstern).

Der VM-Beenden-Pfad ist in `VMQuitGuard` ausgelagert. Bei fehlendem/nicht startbarem Werkzeug,
Fehler, unbekanntem VM-Zustand oder 120-s-Timeout bleibt die App geöffnet und zeigt den Grund.
Auch nach Exit 0 wird geprüft, ob noch eine VM läuft. Ein verspäteter Erfolg nach Timeout beendet
die App nicht nachträglich; solange der Helfer noch arbeitet, startet kein zweiter Suspend-Versuch.
Der Helfer wird beim Timeout nicht unterbrochen, damit er das Speichern abschließen kann.
16 zusätzliche Regressionen verwenden nur temporäre Hilfsprozesse, keine echte VM und keinen
App-Neustart. Der vorhandene lokale Werkzeugpfad bleibt kompatibel.

Verifiziert: alle 58 eigenständigen Regressionen und 63 Xcode-Tests grün; abschließender
Debug-Build in DerivedData signiert. Echte VM und laufende App für die Tests nicht beendet.

## 2026-09-21 — Status über den Socket statt über die TTY (Rendering-Artefakte in Claude Code)

Anlass: Mats' Screenshot — im Claude-Code-TUI stand `;255;255;255mjo` als Text, Zeilen waren versetzt,
Reste alter Zeilen blieben stehen. Das ist der Schwanz von `ESC[38;2;255;255;255m`: Bridge-Mod und die
fünf Fallback-Hooks schrieben OSC 5522 per `printf > /dev/ttysN` in dieselbe Leitung, in die Claude Code
gerade malte; landete die Meldung mitten in einer CSI-Sequenz, brach der Parser sie ab und druckte den Rest.
Im Vollbild-TUI (Diff-Rendering) blieb der Müll stehen. Im Terminal nicht heilbar — die Bytes kommen schon
vermischt an. Fix: neues Steuerkommando `status` (`ControlRequest.text` = Payload, Ziel per `--pane`) ruft
dasselbe `applyHookStatus`; der Mod meldet nur noch darüber, die fünf settings.json-Hooks sind entfernt.
OSC-5522-Empfang bleibt für `accent=` (kommt aus der Shell, nicht neben einem TUI) und Altsender.
Lehre: **in eine TTY schreibt nur der Prozess, dem sie gerade gehört.**

## 2026-09-16 — `latexterm close-pane` (Kacheln vom Agenten schließen lassen)

Anlass: Mats, nach dem Briefkasten-Mod: „wäre es nicht sinnvoller, wenn Agenten mit dem latexterm-Skill
eine Kachel direkt schließen, wie ⌘W?" Bis dahin ging das nur über `/exit` + `exit` per `send`, und
das scheiterte, sobald in der Kachel etwas hing. Neu: `close-pane [--pane ZIEL] [--force]` im Protokoll
(`ControlRequest.force`), Handler ruft denselben `closePane` wie ⌘W. Ohne `--force` schließt er nur
eine nackte Shell oder ein Claude im Zustand `awaitingInput`: `sessionState == .working` → Fehler
„arbeitet gerade“, ein Vordergrundprozess (`tcgetpgrp(childfd) != shellPid`, Name über `proc_name`) →
Fehler mit Prozessname. Skill-Regel in der Werkstatt: eigene Kacheln nach getaner Arbeit schließen,
fremde nur auf Auftrag, `--force` nie ungefragt.

Nebenbefund: Xcode-Update hatte die Metal-Toolchain gelöscht, Build brach ab — `xcodebuild
-downloadComponent MetalToolchain` (840 MB), dann grün.


## 2026-09-15 — Status-Pille und Banner neu gedacht (Bridge-Mod als Fundament)

Anlass: Claude Mods (function hooks, early access) erlauben einen Mod *in* Claude Code, der den echten
Session-Zustand kennt — `claude-werkstatt/mods/latexterm-bridge` schickt seitdem OSC 5522 aus
`session.start`/`turn.start`/`tool.call`/`classic.Notification`/`turn.complete`, inklusive Ctrl+C
(`reason: aborted`). Mats hatte die Pille „seit längerem" abgeschaltet: „nicht nützlich, nicht zuverlässig".
Mit der neuen Wahrheit wurde sie neu gedacht, Mats' Auftrag: „Feature, Nützlichkeit, Design, Nutzen und
die Mac-Benachrichtigungen — alles cooler, testweise wieder aktivieren."

Payload erweitert (abwärtskompatibel, `parseHookStatus`): `status=<state>[;detail][;k=v…]` mit `t` Sekunden,
`n` Werkzeug-Schritte, `p` Prompt-Anfang, `a` Antwort-Anfang, `r` Grund (`answer|aborted|refusal|error`).
Pille: `◐ Bash · 0:42 · 3 Schritte` (Uhr tickt lokal, Sekunden-Timer nur solange sichtbar), `● braucht dich
· <Frage>` in Gelb, Nachklang `✓ fertig · 1:42 · 7 Schritte` in Grün, `■ abgebrochen` gedimmt, `⚠ Fehler` rot —
der Nachklang bleibt, bis die Kachel beobachtet wurde (App aktiv + fokussiert) plus 6 s, höchstens 10 min.
Farben nur aus dem Theme. Modi umbenannt: Aus / Kompakt / Mit Details. Banner: „Claude fertig · <Ordner>"
mit „Frage", Dauer, Schritten und Antwort-Anfang; „Claude braucht dich · <Ordner>" mit der offenen Frage;
Fehler immer; Abbruch und Turns unter 2 s stumm; `threadIdentifier` = Kachel. Legacy-Shell-Hooks laufen
parallel weiter — sobald eine Session Bridge-Felder geschickt hat (`bridgeSeen`), werden ihre feldlosen
Signale ignoriert (sonst zwei „fertig"-Banner, das ärmere gewinnt durch den Cooldown).

Lehren: `private struct` als Rückgabetyp einer `static func` schlägt fehl („method must be declared private") —
`HookStatus` ist deshalb internal. Notification-Text kommt aus untrusted Output: jedes Stück gekappt, Steuerzeichen
raus, kein `;` (Feldtrenner) — die Bridge filtert dasselbe schon auf ihrer Seite.

**Nachtrag (abends, zweite Runde):** Mats nahm Pille + Banner ab („sieht tatsächlich super aus"), wollte aber die
Pille nicht frei im Terminal schweben sehen — Vorschlag: mit den Titelleisten-Punkten verschmelzen. Umgesetzt als
`PaneChipView`: Punkt in Kachelfarbe + Text in Tonfarbe, ruhend nur Punkt, fokussiert lang / sonst kurz / ab fünf
Kacheln nur Zeichen; Chip auch bei einer einzigen Kachel, sobald Status da ist. HUD wird nicht mehr bei jedem
Signal neu gebaut, sondern in place aktualisiert — Neuaufbau nur bei Strukturwechsel oder anderer Gesamtbreite
(Monospace-Ziffern halten die Breite beim Ticken). `PaneStatusBadgeView` und `PaneDotView` entfernt.
Offen: ob `NSTitlebarAccessoryViewController` eine reine Frame-Änderung sauber nachlayoutet, war nicht zu
belegen — deshalb der Neuaufbau bei Breitenänderung als sicherer Weg.


## 2026-09-14 — ⌘K neu gebaut (Palette als Karte, Gruppen, Zweitaktionen)

`LauncherPalette` von Grund auf neu: schwebende Karte im oberen Drittel über abgedunkelter Kachel
(Einblenden mit kurzem Slide), rahmenloses 18-pt-Feld mit Symbol (Lupe → Sparkles bei `/`),
Filter-Chips Alles/Sessions/Projekte/Aktionen/Ordner (⇥ wechselt), Fußzeile mit Tastenhinweisen
je gewählter Zeile. Leerzustand statt „alles in Ordner-Reihenfolge“: Wartet auf dich · Fällig ·
Zuletzt (6 Sessions beider Agenten) · Hier (Aktionen des gewählten Ordners in Projektfarbe) ·
Angepinnt · Läuft · Launcher. Suche: Gruppen nach Art, Reihenfolge nach bestem Treffer, Deckel je
Gruppe („Sessions · 10 von 23“), Treffer im Titel hervorgehoben (`LauncherSearch.match` liefert
UTF-16-Bereiche), Wortanfang schlägt Teilstring, kürzlich Gewähltes (+120, `LatexTerm.paletteRecent`)
und Pins (+30) steigen. Sessions sind auch über den letzten Prompt findbar (Keywords).
Zeilen: Akzentbalken/Tönung in Projektfarbe, Symbolkachel nach Art/Agent (Claude orange, Codex cyan),
Pille rechts (Kontext-%, Kachelzustand, Fälligkeit, Git-Änderungen), ★ bei Pins. Maus: Hover wählt,
Einzelklick führt aus, Klick ins Dunkel schließt. Tasten: ⏎ Hauptaktion, ⌘⏎ Zweitaktion (Session:
Weiter + /compact bzw. Projekt zeigen · Projekt: Neue Session · Ordner: Nur Shell), ⌘C kopiert
ID/Pfad/Antwort — beide laufen über `HomePaneView.performKeyEquivalent` → `handleKeyEquivalent`,
vor Zoom (⌘⏎). KI-Modus: Beispiel-Prompts zum Übernehmen, Statuszeile mit Sekundenzähler, Antwort als
Inline-Karte (⏎/⌘C kopiert, kein NSAlert mehr), Treffer mit Beleg als Untertitel (⏎ Beleg-Dialog,
⌘⏎ sofort weiter), Start als eigene Zeile → bestehende Vorschau. Vertrag zur Datenschicht
(`projekte assist`, Payload, Grenzen) unverändert. `LauncherSearchField` ist jetzt ein rahmenloses
NSTextField (Fokus-Fix bleibt). Sichtabnahme durch Mats nach Neustart offen.

## 2026-09-14 — Fälligkeit zukünftiger Wiedervorlagen (Codex)

Die Aufgabenliste zeigte auch unter „In den nächsten 7 Tagen“ überall „heute fällig“:
Die Zeilendarstellung unterschied nur überfällig/nicht überfällig. `HomePaneView` nutzt jetzt
`daysLeft` für überfällig, heute, morgen und „in N Tagen fällig“. Datum und Gruppierung waren
bereits korrekt; der Fehler lag ausschließlich im Untertitel.

## Archiviert beim Tagesabschluss 2026-09-05

## Aktueller Stand (2026-09-02)

**Formel-Rendering an Claude-Code-Text angepasst (02.09., ungepusht)** — Anlass `/neudenken` über UI/UX + Grenzen
der LaTeX-Overlays: die Detektions-Prämissen stammten aus der Shell-Epoche, der Text kommt heute aus Claude
Codes TUI. Vier Punkte, alle in `OverlayController`/`LaTeXDetector`/Fork: (1) **Hard-Wrap-Join** — Claude Codes
eigener Wortumbruch (harte Zeilen mit Einzug) wird per `looksLikeHardWrapContinuation` wie `isWrapped`
behandelt; `$$`-Blöcke dürfen ein `⏺ ` vor dem Öffner haben. (2) **Dynamischer Span** — Inline-Formeln wachsen
in leere Nachbarzeilen (Items tragen `sy/sh`, `fit()` ankert auf der Quellzeile). (3) **Keine Maske mehr** —
Quellzellen werden vom Fork via `CellStyleOverride.hidden` transparent gezeichnet (Selektion/Diff-Hintergrund
bleiben echt, `bg` aus der Layer-Config raus, `M|`-Masken-Items weg). (4) **Keys ohne Zeile** (`col|body#n`),
damit Fullscreen-TUI-Scrollen nur repositioniert. Nachschlag nach Mats' Screenshot (Falsch-Formel aus
`offenes $,` + `mit $PATH`): (5) **Prosa-Schutz** — Pandoc-Regel + Stilklassen-Regel (Öffner/Schließer gleich
gefärbt; Controller liefert je Zeile mit `$`/`\` eine Klasse pro Spalte aus `attribute.fg` + dim, Row-Cache
hasht Text + Stile). Probe mit 20 Formen (Screenshot): alles wie erwartet bis auf Claude Codes Markdown-Escape
(s. Known limitations) → (6) `looksLikeProse` + `repairMarkdownDamage`. Build + 63 Tests grün (16 neue Detector-Tests); **Sicht-Check
durch Mats steht aus** — besonders: Formel über Claude-Umbruch, Bruch neben Leerzeile, Mausauswahl über
Formel, Scrollen im Fullscreen. Chronik `HISTORIE.md` oben.

## Vorheriger Stand (2026-08-31)

**Lokal-Modus (31.08., ungepusht)** — Toggle in ⌘, → Claude („Neue Sessions lokal starten“): Claude Code
gegen Ollama statt Anthropic-API (Heimat: `claude-werkstatt/lokal/README.md`). Neuer dateibasierter Store
`LokalModusSettings` (Wahrheit = Flag `~/.config/projekte/lokal-modus`, externe Leser: Launcher-Shell +
`projekte.py`; liest bei `onAppear` frisch), schaltet das neue Statuszeilen-Segment `lokal` (🦙, in
`StatuslineSettings.Segment`) automatisch mit. Claude-Tab-Höhe 640→740. Build + Tests grün; Sicht-Check
durch Mats steht aus. Chronik `HISTORIE.md` oben.

**Fullscreen-TUI (29.08. spät, `7377371`, gepusht)** — Claude Code läuft bei Mats jetzt in `/tui fullscreen`
(Alt-Screen; `~/.claude/settings.json` `tui: fullscreen`, `CLAUDE_CODE_SCROLL_SPEED=1`, Beschleunigung aus).
Fork dafür: `MacTerminalView.reportWheel` meldet Rad **und** Trackpad als Wheel-Buttons 64/65, sobald eine App
Maus-Tracking anfordert (vorher totes Rad im Alt-Screen; Trackpad zeilenweise akkumuliert, Gestenstart ¾ Zeile
vorgeladen); `AppleTerminalView.displayFrameDelayNanos` koppelt das Repaint-Throttle an die Screen-Rate (120 Hz).
Prompt-Stil, LaTeX-Overlay, Launcher/Vorhang laufen im Alt-Screen unverändert. Grenze: zeilenquantisiertes
Scrollen (Protokoll), kein Terminal-Scrollback mehr (`Ctrl+O` → `[` schreibt Transcript). Chronik `HISTORIE.md` oben.

**Terminal-Optik R26–R30 + Spielereien (28.08.)** — Plan `claude-werkstatt/plans/terminal-optik_2026-08-28.md`,
Chronik `HISTORIE.md` oben. LatexTerm sieht aus wie Ghostty (Dark+, JetBrains Mono NL 20, Padding 12,
xterm-256, Bold ≠ hell, Font-Smoothing aus, Cursor steht); Themes im Ghostty-Format (`Theme/`), Import-Knopf,
**alle** Flächen am `ThemeStore` — Regel: keine feste Farbe außerhalb `TerminalTheme`. Side-by-side
`docs/optik-side-by-side.png` (Probe `docs/optik-probe.sh`): bis auf Ligaturen nicht unterscheidbar.
Darstellungs-Schalter (⌘,): Theme, Innenabstand, Schrift verstärken, Bold = hell, Cursor blinkt / Theme-Farbe,
Kachel-Akzentrahmen, **Prompt-Text** (Aus / Projektfarbe / Eigene Farbe / Regenbogen, glühend, optional auch
Claudes gefärbten Text übersteuern, wahlweise eigene Farbe) — Grundlage `Latex/PromptBoxLocator.swift`
(13 Tests) + Fork-Hook `cellStyleOverride`. Mats hat alles live abgenommen („funktioniert alles“).
Fork-Fixes unterwegs: `mapColor` (256er um 8 verschoben), `setupOptions` überschrieb Options.
Fallen: Bildschirmaufnahme-Grant klebt nach Rebuilds am alten Build → `tccutil reset ScreenCapture
com.mats.LatexTerm`, neu einschalten, Neustart (`~/.claude/reference/latexterm-tcc.md`); fremde Kacheln
nie zoomen, während Mats in einer anderen arbeitet; `open -na Ghostty` ohne `--window-save-state=never`
bringt gespeicherte Fenster mit; Fork-Dateien sind `r--r--r--` (`chmod u+w`); `xcodeproj`-Gem nur in
`/usr/bin/ruby`.

Weiter gültig aus dem Stand vom 24.08. (Volltext in `HISTORIE.md` → „Stand 2026-08-24, Zusammenfassung“):
Cockpit-Roadmap #29 bis auf **#28 v2 (Fernsteuerung vom Handy, Plan als Kommentar in #28)** zu; Home-Kachel
= Werkstatt-Launcher (Heimatort `claude-werkstatt/launcher/README.md`, Runden 1–25 abgenommen; Fokusziel ist
die Tabelle, Aufklapp-Zustand in `expandedPaths`, Mats-Befehle nur in den Templates von `projekte --json`,
`runProjekte(args)` mit `"$@"`); OSS-Bewerbung offen; `list-panes`-Status hinkt bei laufender TUI nach.

Erledigt-Verlauf der Arbeitssessions, 1:1 aus der Projekt-`CLAUDE.md` ausgelagert (Welle 5 der
CLAUDE.md-Verfassung, 2026-08-22). Neueste Einträge oben. Der aktuelle Stand und die offenen
Punkte stehen in `CLAUDE.md`; die Feature-Sicht (was ist drin, seit wann) im `CHANGELOG.md`.
Hier liegen die Arbeits-Erkenntnisse: Debug-Funde, Entscheidungen mit Begründung, Sackgassen.

---

## Stand (2026-09-05 — gleichwertiger Agentenstart im Home)

Nachprüfung des Erstzeichen-Fixes: isolierter SearchField-Test war unzureichend. Neuer Test
kompiliert die echte LauncherPalette, öffnet sie während NSWindow.sendEvent und durchläuft
Layout/Runloop. Vor Fix reproduziert: Auswahl {0,1}, moin→oin und /frage→frage. AppKit setzt
Select-all nach dem synchronen Fokuscode erneut. Jetzt nachgelagerte, bewachte Korrektur nur
bei unverändertem Anfangstext, vollständiger Auswahl, gleichem Fokus und ohne IME-Markierung.
Gleicher Regressionstest danach grün: Auswahl {1,0}, beide vollständigen Eingaben erhalten.

Erstes Zeichen bei „Tippen öffnet Suche“: explizite Field-Editor-Aktivierung via selectText,
danach kollabierte UTF-16-Auswahl am Textende statt nur makeFirstResponder/currentEditor.
Regressionstest mit unsichtbarem AppKit-Fenster: m→moin, /→/frage, leere Eingabe und Unicode,
vier Fälle grün. Laufende LatexTerm-Instanz dabei nicht gestartet/beendet oder gesteuert.

Mats verwirft die KI-Modusschalter: eine Leiste, führendes `/` = freier Prompt, Enter sendet
ohne weiteren Versanddialog. Sichtbarer Kontingent-/OpenAI-Hinweis, Kontextdetails im Tooltip.
Backend erkennt Absicht intern; freie Antworten zusätzlich zu Finden/Start/Team/Vergleich.
Nur Kachelstarts bleiben separat zu bestätigen. 57 Backend-Tests, 14 Swift-Logikfälle.

KI-Grundfunktionen auf Mats' Auftrag implementiert: Palette trennt Lokal/KI finden/Start/Team.
Opt-in vor Übertragung, Prozessabbruch bei Esc/Moduswechsel/Tippen, alte Antworten per Generation
verworfen. Belegdialog löst Resume nur gegen vorhandenen Sessionkatalog auf. Startvorschau zeigt
Ziel, Prompt und tatsächlichen Startbefehl, neuer Group-Callback öffnet erst nach Bestätigung
eine oder zwei frische Kacheln. Team-Vergleich aus zwei bewusst eingefügten Antworten; kein
automatisches Einsammeln aus unsicher zugeordneten Live-Sessions. Native Tests grün; private
Datenschicht 54 Tests + synthetischer Live-Test (Luna 3,4 s). UI-/Startabnahme nach Neustart offen.

⌘K-Fokus nach Mats' Präzisierung: zentrierte Palette (max. 820 pt), klarer Suchkopf,
42-pt-Suchfeld, 68-pt-Trefferkarten mit separatem 15-pt-Titel/12-pt-Kontext und Anbieterkennung.
Auswahl bleibt sichtbar, obwohl das Suchfeld Fokus hält; Esc-Button und eigener Leerzustand.
KI-Planung anschließend: zuerst lesende Session-Findung mit belegten Treffern, dann bestätigte
Startvorschauen, zuletzt Mehragenten-Briefings; keine KI-Anbindung in dieser UI-Runde.

UI-Nachschliff nach Mats' Rückmeldung: feste Navigation Projekte/Aufgaben/Pins statt
mehrerer Hinweislinks zum selben Ziel; Aufgaben zählt Fälliges und trennt heute/überfällig
von den nächsten sieben Tagen. Schriftbasis 14–16 pt, Erklärungen kleiner in zweiter Zeile,
einheitlich 54-pt-Aktionszeilen, Titel dürfen bei schmalen Kacheln kürzen statt Layout zu sprengen.
Visuelle Abnahme durch Mats nach Neustart bleibt erforderlich.

Launcher-Basics mit Mats/Codex: Tippen und ⌘K öffnen dieselbe persistente lokale Suche
über Ordner, Projekte, Claude-/Codex-Sessions und Aktionen. Rechtsklick auf Resume-Zeilen
der Aktionsliste: Fortsetzen, Pin, Titel, ID/Pfad kopieren. „Heute“ bündelt Wiedervorlagen
bis sieben Tage, Inbox-Anzahl (optionales Backend-Feld) und laufende Kacheln.
Kachelsprünge verwenden UUID statt CWD; mehrere Kacheln im selben Ordner bleiben getrennt.
Grenze: aktuelles Fenster, keine verlässliche Live-Session-ID nach manuellen TUI-Wechseln;
Session-Resume wird daher nicht automatisch auf eine vermeintlich passende Kachel umgeleitet.
KI-Funktionen bleiben bewusst zurückgestellt. Sichtprüfung nach Neustart durch Mats offen.

Sessionverwaltung für beide Agenten: ⌘P/⌘E und Mehr-Aktionen; Sessionmodell trägt Anbieter und
Resume-Template, Codex-Pins in eigener Gruppe im gemeinsamen Pin-Screen. Native Titel über die
Datenschicht, Pins vorerst launcher-lokal (installierte Codex-API bietet das Schreibfeld nicht).
Neuladen baut Pin-Gruppen frisch auf, erhält Projekt/Pin-Auswahl und aktualisiert Suchtreffer.
Mutationen gegen Doppelklick geschützt; Prozessfehler werden gemeldet statt still als Erfolg behandelt.

Kontingente: eigene zweizeilige Fläche unter Claude/Codex statt Platzkonkurrenz zum Projekttitel.
Auf Mats' Wunsch bleibt Claudes drittes Kontingent (Fable) auch unterhalb der Warnschwelle sichtbar.
Verbrauch + Reset sichtbar, weitere Details im Tooltip, Warnung bei ≥85 %. Pro Anbieter
getrennte Antwortablage und zusammengefasste Requests über offene Home-Kacheln; Fehler löschen
den In-Memory-Stand statt fremde/veraltete Werte unbegrenzt zu behalten. Ab 60 s „älterer Stand“,
ab 30 min keine Zahlen; fehlende Daten nicht als 0 %. Datenquelle `projekte limits --agent codex`.

Nach Optik-Abnahme: `agentSessions` aus der Datenschicht für direkte Codex-Fortsetzung,
ältere unter „Mehr“, Picker als Rückfallebene; auch für Projekt-Pins. Ordnergrenzen mit sechs
Fixtures geprüft, Titel suchbar, Codex-Ordner im reduzierten Baum sichtbar. Wiedervorlagen
nutzen fertige `agentActions` mit Initialprompt für den ausgewählten Agenten; Hinweise nennen
ihn ausdrücklich. Claude-Sondermenüs gekennzeichnet, keine Codex-Session-Pins vorgetäuscht.

Claude/Codex als gleich großer Schalter statt addierter Startzeilen; Wahl pro Ordner in
UserDefaults, Standard aus dem Launcher. Nur passende Start-/Resume-Aktionen sichtbar,
Claude-Wartung unter „Mehr“, Sessionaktionen tragen Anbieterkennung. Bestehende gepinnte
Claude-Sessions bleiben Claude; Codex nutzt vorerst seinen nativen Resume-Picker.
Codex erhält den gemeinsamen animierten Startring mit eigener TUI-Readiness-Beobachtung,
Escape/Knopf zum sofortigen Aufdecken und 12-s-Grenze. Eingabepfeil allein reicht nicht:
Er erscheint schon beim Laden; zusätzlich auf aufgelösten Footer und stabile Anzeige warten.
Kein Live-Status-API-Ersatz, keine Claude-Folgebefehle/Prompt-Erkennung für Codex.
Acht eigenständige Readiness-Fixtures (`scripts/test-codex-launch.swift`) und Xcode-Tests grün,
signierter Debug-Build erfolgreich. Live-Sichtprüfung nach Mats' Neustart noch offen;
laufende Host-App bewusst nicht beendet.

## Stand (2026-09-02 — Formel-Overlays für Claude-Code-Text: Umbruch-Join, Span, keine Maske, Keys)

Anlass: `/neudenken uiux, bisherige limitierungen und perfektion der latex formeln renderings`. Befund: die
Architektur (Grid → eine WebView, Scroll-Block) trägt; gebrochen waren vier Prämissen aus der Shell-Epoche, seit
der Text aus Claude Codes Fullscreen-TUI kommt. Mats' Entscheidung: alle vier umsetzen, **keinen** CLAUDE.md-Satz
„Mathe als $…$ schreiben“ — wenn das Modell zufällig lesbar rendert, ist das ebenso gut.
- **Umbruch-Join:** Claude Code bricht selbst wortweise um und schreibt harte Zeilen mit Einzug (`isWrapped` =
  false); eine Formel darüber hatte pro Zeile nur ein `$` → nichts erkannt. Jetzt `LaTeXDetector.
  looksLikeHardWrapContinuation(prev:next:)`: unpaariger Öffner oben (mit Inhalt dahinter), Folgezeile beginnt
  mit Leerzeichen und enthält den Schließer. Einzug ist die Schutzschwelle gegen `echo $PATH`/`cd $HOME`. Dazu
  `findBlocks`: Marker-Zeichen (`⏺ • - * > ⎿ │`) vor `$$`/`\[` erlaubt, `startCol` = Delimiter-Spalte.
- **Dynamischer Span:** Box = Quellzeile + leere Nachbarzeilen (ohne Block), Item trägt `sy/sh`; `fit()` im
  JS skaliert in die Box, ankert vertikal auf der Quellzeilen-Mitte und schiebt nur bei Überstand. Bruch
  zwischen Text und Leerzeile bekommt zwei Zeilen, in einem Absatz mit Leerzeile oben und unten drei.
- **Keine Maske:** `CellStyleOverride.hidden` im Fork (Glyph/Unterstrich transparent, Hintergrund + Selektion
  + Cursor bleiben); Hook läuft jetzt für alle Zellen, Dim-Zellen honorieren nur `hidden`. Controller führt
  `hiddenCells` (absolute Zeile → Spaltenbereiche) aus allen Segmenten (auch Block-Zeilen), meldet Änderung →
  `needsDisplay`. `bg` aus der Layer-Config, `.bg`-Div und `M|`-Masken-Items entfernt.
- **Keys ohne Zeile:** `col|body#n`. Im Fullscreen-TUI scrollt Claude Code selbst (yDisp 0) — vorher pro
  Schritt Div weg + neu + KaTeX; jetzt nur Reposition. Beim echten Scroll unverändert.
- **Nachschlag (Screenshot von Mats):** der Umbruch-Join machte aus `offenes $,` + `mit $PATH` eine Prosa-
  Formel. Neue Idee statt Heuristik-Flickwerk: (a) **Pandoc-Regel** `tex_math_dollars` — Öffner-`$` braucht
  rechts ein Nicht-Leerzeichen, Schließer-`$` links eines und rechts keine Ziffer. Fängt auch den alten
  „by design“-Rest `echo $PATH and $HOME`. (b) **Stilklassen** — wir besitzen das Grid: Öffner und Schließer
  müssen dieselbe Vordergrundfarbe (+Dim) tragen; Claude Codes Code-Span `$PATH` (blau) paart sich nie mit
  Fließtext-`$`. `find/findWrapped/looksLikeHardWrapContinuation` nehmen optional `styles` (Klasse je Spalte),
  der Controller berechnet sie nur für Zeilen mit `$`/`\` und hasht sie in den Row-Cache. Preis: `$ x $` mit
  Innen-Leerzeichen ist keine Formel mehr (Test angepasst). 61 Tests grün.
- **Probe (20 Formen, Screenshot):** Inline, Index, Griechisch, Bruch in Leerzeile, großes Integral, Umbruch-Join
  über Claudes Wortumbruch, `$$`-Blöcke mit/ohne Marker, alle Negativfälle (Shell-Variablen, Preise, `$,`,
  Innen-Leerzeichen, `\$100`) — alles wie erwartet. Zwei Funde: (a) `$$ und das war $$` einzeilig paart
  (Pandoc-Regel gilt nur für `$`) → `looksLikeProse`: ≥ 2 Wörter à ≥ 3 Buchstaben ohne Mathe-Zeichen = Text.
  (b) **Claude Codes Markdown-Renderer entfernt Backslashes vor ASCII-Satzzeichen** (CommonMark): `\(`→`(`,
  `\[`→`[`, `\,`→`,`, `\;`→`;`, `\$`→`$`, `\\`→`\ ` — daher kam Punkt 3/10 roh, Punkt 6 mit `, dx`, Punkt 9
  als einzeilige Matrix, Punkt 11 als Fehler. App-seitig nur die Matrix heilbar (`repairMarkdownDamage`:
  `\ ` in `\begin{…}` → `\\`); der Rest ist CC-Verhalten, dokumentiert in CLAUDE.md/README. Code-Span
  `` `$a$` `` rendert (gleiche Farbe beidseits) — bewusst gelassen. 63 Tests grün. Doku-Drift bereinigt: CLAUDE.md
  behauptete „display:false hartkodiert“, README „KaTeX 0.16.9“ (gebündelt: 0.16.47).

## Stand (2026-08-31 — Lokal-Modus: Ollama-Fallback als ⌘,-Toggle)

Anlass: Claude-Code-Fallback auf lokale Modelle (claude-werkstatt `lokal/`). Neu: `LokalModusSettings`
(dateibasierter Store nach dem Muster von `StatuslineSettings` — Wahrheit ist die Flag-Datei
`~/.config/projekte/lokal-modus`, weil Launcher-Shell und `projekte.py` sie extern prüfen; UserDefaults
wäre für externe Leser unsichtbar). Toggle in ⌘, → Claude („Neue Sessions lokal starten“, Höhe 640→740),
liest den Zustand bei `onAppear` frisch (Datei kann von der Shell geändert werden). Der Toggle schaltet
das neue Statuszeilen-Segment `lokal` (🦙 Modell/CPU/RAM/tok/s, gerendert vom mats-tools-Skript) automatisch
mit — `StatuslineSettings.Segment` um `case lokal` (Zeile 2) erweitert, im Statuszeile-Tab weiter von Hand
übersteuerbar. Build + alle Tests grün. Lehre am Rande: Download-Kachel + „App neu starten (⌘Q)“-Anweisung
beißen sich — der Neustart killt laufende Pane-Prozesse.

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

## 2026-08-29 — „Neues Projekt“ aus dem Menü verpuffte
Dialog kam, danach nichts: kein Ordner, kein Start im Timer-Log. Der Code hatte nach dem Dialog vier
stille `return`-Pfade und `launch()` schluckte Anfragen auf schon gestarteten Kacheln (Menü ging über
`HomeFocus.active`, das beim Entfernen der Home-Kachel nicht gelöscht wurde). Jetzt: Abbrüche als
Alert, `active` wird beim Fensterverlust gelöscht, Start auf laufender Kachel wandert in eine neue
(`onLaunchElsewhere`), Logger `com.mats.LatexTerm` Kategorie `home`/`launch`. Lehre: nach einem
Modal-Dialog nie still aussteigen — der User liest „nichts passiert“ als Bug.

## 2026-09-22 — ⌘Q hält die Windows-VM vorher an
⌘Q reißt eine laufende VMware-VM mit (`vmware-vmx` bekommt SIGTERM, die Fusion-App überlebt; Absender nicht
ermittelbar — LatexTerm selbst schickt nur `kill(shellPid, SIGTERM)`, Unified Log ohne sudo leer). Statt der Regel
„vor ⌘Q `/labor aus`": `applicationShouldTerminate` prüft `pgrep -x vmware-vmx`, zeigt ein kleines Panel und ruft
`~/.claude/skills/vm/vm suspend` (Werkstatt), antwortet `.terminateLater` und beendet nach dem Anhalten (Fallback: rc≠0,
Startfehler oder 120 s → trotzdem beenden). Ohne VM oder ohne Werkzeug unverändert. Logger-Kategorie `quickstart`.

## Archiviert am 2026-09-22 — ersetzter Projektstand und Arbeitsliste

## Aktueller Stand (2026-09-15)

**Status-Chips + Banner neu (15.09.):** Fundament ist der Bridge-Mod (Werkstatt `mods/latexterm-bridge`), der Claude Codes
echten Zustand liefert. Erste Runde (schwebende Pille in der Kachel) von Mats abgenommen („Feature passt und läuft"),
dann auf seinen Wunsch in die Titelleiste verlegt: Chips = Punkt + Text, ersetzen die alten Punkte und die Pille.
Zeigt Tätigkeit, laufende Uhr, Schritte, danach Nachklang „✓ fertig · 1:42 · 7 Schritte" bis hingesehen; Banner mit
Frage, Dauer, Schritten, Antwort-Anfang (live gesehen: „braucht dich"-Banner, Klick holt die Kachel). Modi
Aus/Kompakt/Mit Details; Mats' Default per `defaults write` auf „Mit Details". Signiert gebaut; Sichtabnahme der
Chips nach Neustart offen. Details `HISTORIE.md` 15.09.

**Desktop-Widgets (11.09.):** neues Target `LatexTermWidgets` (WidgetKit, sandboxed, App-Group; Abschnitt oben unter
Architecture) mit Claude-Cockpit und Claude Wrapped, `WidgetRefresher` als Schreiber (`projekte widget`, Setting
„Widget-Befehl“). Signiert gebaut, beide Widgets auf Mats' Schreibtisch, zwei Nachbesserungen nach Abnahme
(kein Kachel-Stapeln bei `latexterm://home`, Fristen fließend hinter zweizeiligen Titeln, große Variante).
Von Mats abgenommen (16:50); kleine Varianten nur in der Galerie gesehen.

**Feierabend-Übergabe 05.09.:** Claude und Codex sind im Home gleichberechtigt: Anbieterwahl je Ordner,
eigene Kontingente/Startvorhänge, Direkt-Resume mit nativem Picker als Fallback, Pins/Titel,
gemeinsame Wiedervorlagen. Navigation Projekte/Aufgaben/Pins; Kachelsprünge per UUID statt CWD.

**Entschiedene Bedienung:** ⌘K und freies Tippen öffnen genau eine Suchleiste. Normaler Text sucht
lokal; führendes `/` ist ein freier KI-Prompt, Enter sendet. Keine vorgefertigten KI-Modusschalter
oder zusätzlichen Versanddialoge; OpenAI-/Kontingenthinweis sichtbar. Kachelstarts brauchen weiterhin
eine Vorschau und Bestätigung. KI erkennt Absicht intern; Suchen liefert lokale Belegausschnitte,
Start/Team erzeugen validierte Vorschläge, freie Antworten/Vergleiche bleiben lesend.
Private Daten-/Befehlslogik: Werkstatt `launcher/assistant.py`, Vertrag in `launcher/README.md`.

**Bestätigt:** Mats meldet nach Neustart „funktioniert erstmal“ für den Erstzeichen-Fix.
Vollständiger AppKit-Palettentest reproduzierte vorher moin→oin und /frage→frage:
verzögertes Select-all nach Fokusübergabe. Bewachte Runloop-Korrektur behebt beide Fälle.
Der frühere isolierte SearchField-Test allein war unzureichend. Code + Repro:
`LauncherSearchField.swift`, `scripts/test-launcher-palette-input.swift`.

**Prüfstand:** 57 Backend-Tests, 14 Swift-Such-/Slash-Fälle, vier isolierte Fokusfälle,
zwei vollständige AppKit-Tastaturpfade und native Xcode-Suite grün. Ein synthetischer Luna-Test
über bestehenden Codex-Login: 3,4 s (Finden-Pfad, keine privaten Daten/keine Test-Kacheln).
Finaler Debug-Build in DerivedData signiert und Signatur geprüft. Tagesänderungen per `$finish`
als `1d1d5dc` committet/gepusht (Werkstatt: `b406ea3`); bestehende fremde Änderungen erhalten.

**Grenzen:** Suche max. 160 jüngste Katalog-Sessions / 48 übertragene Kandidaten, kein Vollarchiv.
Live-Session-ID und fensterübergreifende Zuordnung fehlen; Team-Antworten zum Vergleich bewusst
in den Prompt einfügen, nicht automatisch aus laufenden Kacheln holen. Frühere Formel-/Optik-
Abnahmen bleiben offen, Details der ersetzten Stände 1:1 in HISTORIE.md.

## HIER WEITERMACHEN

- [x] **Widgets** 11.09. abgenommen (Rendering, große Variante); Rebuild-Rezept im Abschnitt „Desktop-Widgets“ oben.
- [ ] **Morgen zuerst:** ⌘K → `/wo hatten wir über … gesprochen?` an bekanntem Thema testen;
      dann eine Start-/Team-Vorschau prüfen, echte Starts nur im tatsächlich gewünschten Projekt.
- [ ] **Formel-Runde 02.09. abnehmen** (Details im archivierten Stand in HISTORIE.md). Bekannte Reste: zwei Formeln mit derselben
      leeren Zeile dazwischen können sich im Overlay überlappen (beide wachsen hinein); ein echter weicher
      Umbruch direkt am `$` bleibt wie gehabt Grenzfall.
- [ ] **Terminal-Optik, Reste:** Ghostty-Import-Knopf einmal von Mats drücken (Vorschau zeigt nur „Innenabstand →
      15 px“); feste Signing-Identität fürs Target (TCC-Grants kleben am Debug-Build) — To-Do in der Werkstatt-CLAUDE.md.
      Prompt-Stil ist experimentell: bricht leise, wenn Claude Code die Box-Zeichnung ändert (`PromptBoxLocator`-Tests
      dann anpassen, `/tmp/latexterm-status.log` → `BOX`-Zeilen).
- [ ] **Home-Kachel:** Runden 1–25 abgenommen; Heimatort `claude-werkstatt/launcher/README.md` (Übergabe, JSON-Vertrag,
      Offenes) — dort zuerst lesen. Neue Befunde → `HISTORIE.md`.
- [ ] #28 v2, Etappe E1: lokale MCP-Bridge auf `control.sock` — zuerst den Plan-Kommentar in #28 lesen.
- [ ] OSS-Antwort abwarten; bei Absage ist der einzige Weg Kategorie „20+ externe Contributor" =
      Sichtbarkeits-Push (Show HN, r/macapps, LaTeX-/Terminal-Communities) — Monatsprojekt, `HISTORIE.md`.
- [x] Codex-Einstieg 05.09.: `AGENTS.md` zeigt auf diese gemeinsame Quelle. Home rendert
      additive `agentActions`; gleichwertiger Claude/Codex-Schalter merkt die Wahl pro Ordner.
      Wartung unter „Mehr“, Sessionaktionen mit Anbieterkennung. Codex hat einen eigenen Startvorhang
      im gemeinsamen Ring-Design (Escape/Knopf zum Aufdecken, maximal 12 s), ohne Claude-Folgebefehle
      und ohne Claude-Prompt-/Statusheuristiken. Acht Readiness-Fixtures und Xcode-Tests grün,
      signierter Build erfolgreich. Projektfarbe bleibt. Sichtprüfung nach Neustart offen;
      erste Optik von Mats abgenommen. Codex-Direktfortsetzung jetzt über `agentSessions`,
      ältere unter „Mehr“, nativer Picker als Fallback, auch in Projekt-Pins. Gemeinsame
      Wiedervorlagen über `agentActions` an den gewählten Agenten, kein Codex-Start-Hook.
      Sechs Pfadgrenzen-Fixtures grün. Codex-Pins/-Titel jetzt mit ⌘P/⌘E und Mehr-Aktionen:
      Pins launcher-lokal, Titel nativ; eigene Anbietergruppen im Pin-Screen. Auswahl beim Reload
      erhalten, Fehler sichtbar. Neue Sichtprüfung und Live-Status noch offen.
      Kontingente beider Agenten jetzt in eigener Zeile unter dem
      Schalter, mit Reset, getrenntem Cache und ehrlichem Fehler-/Veraltet-Zustand.
      Live-Datenprobe beider Anbieter erfolgreich; visuelle Abnahme nach Neustart offen.
      Datenvertrag: Launcher-README.
