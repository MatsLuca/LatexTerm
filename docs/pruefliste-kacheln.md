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

## Steuerkanal

| # | Befehl | Erwartet | Wer |
|---|---|---|---|
| 20 | `latexterm list-panes --json` | alle Kacheln, `focused` nur bei einer | C |
| 21 | `latexterm new-pane --cwd /tmp --exec 'echo hi'` | neue Kachel in `/tmp`, „hi“ | C |
| 22 | `latexterm send --pane N 'echo x'` | Text in der Zielkachel | C |
| 23 | `latexterm zoom --pane N`, `latexterm focus --pane N` | Zoom bzw. Fokus wandert | C |
| 24 | `latexterm close-pane --pane N` auf ruhende Shell / auf Kachel mit `sleep 60` | zu / Fehler mit Prozessname | C |
| 25 | Claude-Status (`working`/`done`) während eines Turns | Chip tickt, `list-panes` zeigt `working` | C |
