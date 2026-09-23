# Prüfliste Kacheln (Regressionstest für den Kachel-Umbau)

Manueller Durchgang nach jedem Umbau an Kachel, Hülle, Fokus oder Kürzeln — was sich als Unit-Test nicht
prüfen lässt. Entstanden mit dem Bauplan „Kachel-Protokoll“ (22.09.2026, Plan in der claude-werkstatt:
`plans/kachel-protokoll_2026-09-22.md`); Pflicht nach den Schritten 2, 4, 5 und 8.

**Aufbau:** frisch gestartete App, ein Fenster, drei Kacheln — Home, Shell in `~/Documents`, Claude-Session.
`A` = Mats sieht hin, `C` = Claude prüft per CLI/Log selbst.

## Tastatur

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| 1 | ⌘T in der Shell-Kachel (nicht die älteste) | neue Shell erbt **deren** Verzeichnis, nicht das der ersten Kachel (bis Schritt 5 erbte ⌘T das der ältesten Terminal-Kachel: kein Fokusfilter) | A |
| 2 | ⌘T in der Home-Kachel | neue Shell im Home-Verzeichnis, Home bleibt | A |
| 3 | ⌘W in Terminal, in Home, bei offener ⌘F-Suchleiste, bei offener ⌘K-Palette | genau die fokussierte Kachel geht zu (auch bei offener Palette: die ganze Kachel, wie seit jeher) | A |
| 4 | ⌘3 bei zwei Kacheln / ⌘1 bei drei | auf drei auffüllen / nichts schließen | A |
| 5 | ⌘⏎ in Terminal und in Home; ⌘⏎ in der offenen ⌘K-Palette | Zoom an/aus, Zoom-Pille in der Titelleiste; in der Palette die Zweitaktion statt Zoom | A |
| 6 | ⌘F in Terminal, ⌘F in Home | Suchleiste nur im Terminal; Home ignoriert | A |
| 7 | Menü Kachel → Zoom/Schließen/Suchen mit der Maus | wirkt auf die fokussierte Kachel | A |
| 8 | ⌘± / ⌘0 in einer Kachel | alle Terminals ändern die Schrift | A |

## Fokus, Rahmen, Titel

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| 9 | Klick in jede Kachel reihum | fokussierte hell + dicker Rahmen, andere gedimmt + dünn; kein Flackern | A |
| 10 | ⌘F-Suchleiste öffnen/schließen, Tippen in Home, ⇥ zwischen Baum und Aktionen | Kachel bleibt fokussiert, Rahmen flackert nicht | A |
| 11 | Fenstertitel beim Kachelwechsel | folgt der fokussierten Kachel („LatexTerm — Projekte“ in Home) | A |
| 12 | Einstellungen ⌘, → Kacheln: Rahmen aus/an, Dimmung aus/an | wirkt sofort auf alle Kacheln | A |
| 13 | Einstellungen → Darstellung: Theme wechseln (Dark+ ↔ Ember), Innenabstand ändern | Terminal, Hülle, Home, Stege färben um; Inset passt | A |
| 14 | Eine einzige Kachel / gezoomte Kachel | voller 2-px-Akzentrahmen | A |

## Titelleiste, Notifications, Start

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| 15 | Chip-Klick bei gezoomter Kachel auf eine andere | Zoom wandert zur angeklickten | A |
| 16 | Claude arbeitet in unfokussierter Kachel, fertig > 2 s | Banner; Klick → App vorn, Kachel fokussiert + gezoomt | A |
| 17 | Home → Claude-Session starten | Vorhang mit Ring, danach Terminal mit Fokus, Kachelfarbe gesetzt | A |
| 18 | Home → „Nur Shell“ | Shell sofort, Fokus im Terminal | A |
| 19 | `exit` in einer Shell | Kachel verschwindet, Nachbar bekommt Fokus | A |

## Anordnung (Kachel-Layout, 23.09.2026)

Aufbau: eine Claude-Kachel links, sonst nichts. Plan: claude-werkstatt `plans/kachel-layout_2026-09-23.md`.

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| L1 | ⌘T dreimal (nur Terminals) | wie früher: nebeneinander bis 3–4, dann zwei Reihen — Pixel wie das alte Raster | A |
| L2 | Claude öffnet eine PDF-Vorschau (`open_preview`) | Vorschau als hohe Spalte rechts neben Claude, Claude behält ≥ 60 Spalten | A |
| L3 | Claude öffnet danach Web und Scratchpad | beide in dieselbe Nebenspalte (untereinander), Claude wird nicht weiter halbiert | A |
| L4 | Menü Kachel → Neues Scratchpad bei fokussierter Claude-Kachel | landet in Claudes Nebenspalte | A |
| L5 | Steg zwischen Claude und Nebenspalte ziehen | Hüllen folgen der Maus, Terminal-Text springt erst beim Loslassen (ein Umbruch, keine Treppe) | A |
| L6 | Doppelklick auf einen Steg | beide Nachbarn gleich groß | A |
| L7 | nach L5 eine weitere Kachel öffnen / eine schließen | gezogene Breite bleibt; die neue kommt in die Nebenspalte bzw. der Platz fällt an den Block | A |
| L8 | Menü Kachel → Automatisch anordnen | gezogene Größen weg, Automatik ordnet neu | A |
| L9 | ⌥⌘R nach L5 | gleiche Anordnung samt gezogener Breite | A |
| L10 | ⌘⏎ Zoom während angepasstem Layout | Zoom wie immer, Stege verschwinden, danach wieder da | A |
| L11 | Agent: `panes` | Liste + „Anordnung (Stand N, …)“ als Baum mit %, ✋ an Mats' gezogener Teilung | C |
| L12 | Agent: `layout gross` auf eigene Vorschau; danach auf ✋-Teilung; auf fremde Kachel | groß / abgelehnt mit Grund / abgelehnt ohne `auf_auftrag` | C |
| L13 | Mats zieht, dann Agent `layout` mit altem Stand | abgelehnt, aktueller Stand kommt mit; zweiter Versuch geht | C |

### Kachel ziehen (Stufe 2, Scheibe B)

Aufbau: Claude + drei Begleiter + eine zweite Terminal-Kachel (⌘T), dazu ein Reiter-Platz (vierter Begleiter).

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| Z1 | Chip in der Titelleiste kurz anklicken | fokussiert wie bisher (erst beim Loslassen), nichts wird gezogen | A |
| Z2 | Chip einer Kachel ziehen, über eine andere Kachel fahren | Hand-Cursor, Quelle abgeblendet, Schildchen mit Titel; Rand links/rechts/oben/unten = diese Hälfte leuchtet, Mitte = ganzer Platz (als Reiter) | A |
| Z3 | loslassen auf Z2-Hälfte | Kachel steht genau dort, hat den Fokus, Terminal-Text springt einmal (kein Treppen-Reflow) | A |
| Z4 | loslassen in der Mitte einer Kachel | beide werden Reiter eines Platzes, die gezogene vorn | A |
| Z5 | Reiter aus einer Leiste ziehen, auf die eigene Kachel darunter an den Rand | Reiter löst sich neben/unter die übrigen Reiter | A |
| Z6 | Reiter innerhalb der Leiste ziehen | Einfügemarke zwischen den Reitern, Loslassen sortiert um | A |
| Z7 | Kachel ganz an den Fensterrand ziehen (≤ 14 pt) | Vorschau über die ganze Höhe/Breite (⅓), Loslassen setzt sie dort hin | A |
| Z8 | Ziehen und Esc drücken / außerhalb des Fensters loslassen / auf sich selbst loslassen | nichts ändert sich, keine neue Stand-Nummer | A |
| Z9 | Kachel auf eine schon schmale Kachel werfen | Schildchen „zu eng“, Loslassen ändert nichts | A |
| Z10 | ⌘⏎ Zoom, dann Chip ziehen | kein Zug; Loslassen über dem Chip wechselt den Zoom wie ein Klick | A |
| Z11 | während des Ziehens öffnet/schließt ein Agent eine Kachel | Zug endet ohne Wirkung, Anzeige verschwindet | C |
| Z12 | nach Z3/Z4: Agent `panes`, dann `layout automatisch` bzw. Kachel aus Mats' Reitern lösen | ✋ an der neuen Teilung / an den Reitern; beides abgelehnt ohne `auf_auftrag` | C |
| Z13 | ⌥⌘R nach Z3–Z6 | gleiche Anordnung, Reiter samt Reihenfolge und vorderem | A |

### Abzeichen am Reiter (Stufe 2, Scheibe C)

| # | Aktion | Erwartet | Wer |
|---|---|---|---|
| C1 | Claude-Session als verdeckter Reiter, Prompt per `ask_session`, arbeitet | Punkt rechts im Reiter pulsiert ruhig in Kachelfarbe | A |
| C2 | derselbe Agent fertig bzw. fragt nach | grüner (Fehler: roter) Punkt bzw. gelb, schnell pulsierend; Tooltip nennt es | A |
| C3 | verdeckte Vorschau: Datei neu schreiben; verdecktes Web: HTML ändern; verdecktes Scratchpad: Agent zeichnet | Ring in Kachelfarbe | A |
| C4 | Reiter anklicken | Abzeichen weg; wieder verdecken → bleibt weg | A |
| C5 | Maus über den Reiter mit Abzeichen | × erscheint an seiner Stelle, Titel wird nicht abgeschnitten dahinter | A |

## Steuerkanal

| # | Befehl | Erwartet | Wer |
|---|---|---|---|
| 20 | `latexterm list-panes --json` | alle Kacheln, `focused` nur bei einer | C |
| 21 | `latexterm new-pane --cwd /tmp --exec 'echo hi'` | neue Kachel in `/tmp`, „hi“ | C |
| 22 | `latexterm send --pane N 'echo x'` | Text in der Zielkachel | C |
| 23 | `latexterm zoom --pane N`, `latexterm focus --pane N` | Zoom bzw. Fokus wandert | C |
| 24 | `latexterm close-pane --pane N` auf ruhende Shell / auf Kachel mit `sleep 60` | zu / Fehler mit Prozessname | C |
| 25 | Claude-Status (`working`/`done`) während eines Turns | Chip tickt, `list-panes` zeigt `working` | C |
