# HISTORIE — LatexTerm

Erledigt-Verlauf der Arbeitssessions, 1:1 aus der Projekt-`CLAUDE.md` ausgelagert (Welle 5 der
CLAUDE.md-Verfassung, 2026-08-22). Neueste Einträge oben. Der aktuelle Stand und die offenen
Punkte stehen in `CLAUDE.md`; die Feature-Sicht (was ist drin, seit wann) im `CHANGELOG.md`.
Hier liegen die Arbeits-Erkenntnisse: Debug-Funde, Entscheidungen mit Begründung, Sackgassen.

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
