# Konkurrenz-Analyse: LaTeX im Terminal

Angelegt 23.09.2026 aus einem Claude-Chat, **Detailanalyse 24.09.2026** (Suche + Code-Lektüre von 14 Repos,
Klone lagen im Session-Scratchpad). Nichts davon ist beschlossen — §1 ist die Empfehlung, der Rest Beleg.

Grundproblem: LaTeX, das ein Agent (Claude Code, Codex …) im Terminal ausgibt, gesetzt anzeigen — auf dem Mac.

---

## 1. Ergebnis: was LatexTerm übernehmen sollte

### Schnell (S), klarer Nutzen

1. **KaTeX begrenzen** (Folio, pi-math). Heute `{displayMode, throwOnError:true}` ohne Limits
   (`MathOverlayView.swift:120`); eine pathologische Formel trifft die *eine* WebView aller Formeln.
   → `maxSize`, `maxExpand` explizit, Quelltext > 8 KB gar nicht erst rendern (Folio: 8 KB, pi-math: 20 000 Zeichen).
2. **`repairMarkdownDamage` schärfen** (Folio `restore_stripped_environment_newlines`). Unsere Funktion ersetzt
   *jedes* `\ ` in einem Text mit `\begin{` — auch in `\text{a\ b}` und in `equation`. Folio: nur Zeilen-
   Environments (matrix/cases/align/array, auch verschachtelt), nur Klammertiefe 0, nur wenn vor `\end` noch
   eine Zeile folgt. Kopieren liefert bei Folio immer die Originalbytes, nie die reparierten.
3. **`# $$` als Block-Öffner** (Folio): Markdown-/Codex-Reflow macht aus `$$` eine Überschrift. `#` in
   `blockMarkerChars` (`LaTeXDetector.swift:200`) nur zulassen, wenn ein `$$`-Schließer folgt.
4. **False-Positive-Korpus als Testfälle** (Folio `INLINE_FALSE_POSITIVE_CORPUS`, MIT/Apache — Quelle im Test
   nennen): `PATH=$HOME/bin:$PATH`, `WHERE a=$1 AND b=$2`, `Cost $5+$10`, `tiers $5-$10-$20`,
   `awk '{print $1}' report.txt`, `if [ $a -eq $b ]; then`, `export FOO=$BAR:$BAZ`, `sed -i 's/$old/$new/g' f`,
   `echo $$`, `pid=$$`, `+ $$x^2$$`, `$$broken`, `$5 和 $10`. Dazu Folios `malformed`/`malicious`-Korpus
   (`\frac{1}{2`, `x^{^{^{`, `\newcommand{\loop}{\loop}\loop`, 600er-Klammertiefe, 70 000-Zeichen-Exponent)
   gegen Punkt 1.
5. **XTVERSION beantworten** (Folio `adapter.rs:47`: `ESC P >|Name(Version) ESC \`, erst nach DA1, nicht
   mitten in einem DEC-2026-Block). Unser SwiftTerm kann DEC 2026 schon (`Terminal.swift:4147`), beantwortet
   `CSI > q` aber nicht — Claude Code nutzt Synchronized Output nur, wenn es das Terminal erkennt. Erst messen,
   ob Claude Code in LatexTerm heute `?2026h` schickt; wenn nicht, verspricht das weniger Flackern beim Redraw.

### Mittel (M), größter Hebel

6. **Backslash-Schaden an der Quelle verhindern — Hook `MessageDisplay`** (iCodeCraft/claude-code-latex-terminal,
   Apache-2.0). Claude Code ruft den Hook pro gestreamtem Antwort-Stück *vor* dem Markdown-Rendern; die Antwort
   `{"hookSpecificOutput":{"hookEventName":"MessageDisplay","displayContent":…}}` ersetzt nur die Anzeige,
   Transkript und Modellkontext bleiben unberührt. **Existiert in Claude Code 2.1.281** (im Binary geprüft
   24.09.). Das Plugin verdoppelt in `$…$` jeden Backslash vor ASCII-Satzzeichen (`\,`→`\\,`), puffert einen
   Backslash an Stückgrenzen, zählt Code-Fences/Backticks, lässt `$$` nativ (dort frisst CC nicht) außer die
   Nachricht hatte schon eine Ersetzung. Für uns: als Teil des Mods `latexterm-bridge` (nur in LatexTerm-
   Kacheln), **erweitert um `\(…\)`→`$…$` und `\[…\]`→`$$…$$`** (Idee aus codex-latex, dort längenerhaltend
   `\(`→`${`, `\)`→`}$`). Damit würden die heute „nie erkennbaren" `\(…\)`-Formeln und `\,`/`\{`/`\;`-Schäden
   verschwinden; `repairMarkdownDamage` bleibt Fallback (Codex, Shell, ohne Mod).
7. **Transkript als Zweitquelle** (ghostty_latex_render, texpop — beide MIT): die JSONL unter
   `~/.claude/projects/<cwd>/<session>.jsonl` enthält den Text *vor* dem Markdown-Schaden. Wir kennen die
   Session-ID je Kachel. Nur nötig, falls Punkt 6 scheitert — Zuordnung Raster↔Transkript ist unsauber.
8. **Mindestgröße für Inline-Formeln** (pi-math `inlineMinScale`): würde ein Bruch in seiner Zeile kleiner als
   z. B. 60 %, bekommt er mehr Höhe statt winzig zu werden. Antwort auf die bekannte Grenze „Bruch in eine
   Zeilenhöhe geschrumpft". Bei uns ohne echte Zeilen einzufügen nur als größere Box über Nachbarzeilen
   (Hover-artig) machbar — erst Konzept.
9. **„Vollständig statt wohlgeformt"** (Folio `inline_source_is_complete`): eine Inline-Formel darf nicht auf
   einem binären Operator enden und muss balancierte Klammern haben. Zusätzliche, billige Prosa-Bremse.

### Bewusst nicht

- **Platz schaffen / echte Zeilen einfügen** (Folio-Bänder): Folio hat Bild-Bänder selbst zurückgebaut, weil sie
  mit absolut positionierenden Programmen kollidieren. Unser Einpassen ist für ein TUI-Cockpit richtig.
- **OSC-133-Provenienz**: bringt bei Claude Code nichts (läuft im Alt-Screen, Folio erklärt dort alles für
  zulässig); unsere Stilklassen-Regel ist dort genauer. Nur für Shell-Ausgabe interessant — Prio niedrig.
- **Formel als Bild/Werkzeug statt Text** (opencode-latex-render), **Unicode statt LaTeX** (claude-math),
  **`@nl`-Makro statt `\\`** (LaTerM), **Netz-Renderer** (glow/mods → codecogs.com): widersprechen „Text bleibt
  Text, offline".
- **Alpha-Clipping mit adaptivem Rand** (pi-math): nur bei Pixelrendering nötig; erst angehen, wenn bei uns
  abgeschnittene Glyphen beobachtet werden.
- **Komplexitätsfilter** (ghostty_latex_render: `$x$` bleibt Text): höchstens als Einstellung.

### Wo LatexTerm vorn liegt

Stilklassen-Regel (Farbe von Öffner/Schließer) hat niemand sonst; `isWrapped` aus dem echten VT-Parser statt
Einzug-Raten; Scroll per CSS-Translation einer WebView statt Bild-Neusenden; kein Plugin/Bundle-Patch, der bei
Host-Updates bricht; Agenten-Cockpit ohne Gegenstück.

---

## 2. Die Projekte (Stand 24.09.2026)

| Projekt | ★ | Lizenz | Datenweg → Renderer | Was lohnt |
|---|---|---|---|---|
| [folio-terminal](https://github.com/lulu-loopp/folio-terminal) | 53 | MIT/Apache | eigenes Terminal (Rust, Alacritty-Fork) → mitex/Typst → GPU | Erkennung, Reparatur, Härtung, XTVERSION, Korpus — Hauptreferenz |
| [claude-code-latex-terminal](https://github.com/iCodeCraft/claude-code-latex-terminal) | 0 | Apache | Claude-Code-Hook `MessageDisplay` → Anzeige-Umschreibung | Backslash-Schutz an der Quelle (§1.6) |
| [pi-math](https://github.com/DorianRudolph/pi-math) | 0 | MIT | Pi-TUI-Patch → MathJax → PNG → Kitty | Limits, Fehlercodes, LRU, Inline-Mindestgröße, Alpha-Clipping |
| [ghostty_latex_render](https://github.com/YangLiu14/ghostty_latex_render) | 0 | MIT | Stop-Hook + Transkript-JSONL → MathJax → Ghostty-Split | Transkript lesen, Komplexitätsfilter |
| [texpop](https://github.com/dyed-eye/texpop) | 7 | MIT | Hotkey → Transkript → KaTeX-Popup | Turn per `requestId` zusammensetzen, Plan-Mode, Fokus-Erkennung fremder Terminals |
| [herdr-math](https://github.com/liambern/herdr-math) | 1 | MIT | Herdr-Pane-Text → MathJax → Kitty | fast unsere Regeln; Skill lehrt das Modell, Backslashes zu verdoppeln |
| [codex-latex](https://github.com/ChizhongWang/codex-latex) | 1 | Apache | Codex-Fork, pulldown-cmark `ENABLE_MATH` → Unicode | `\(`→`$` längenerhaltend |
| [claude-code-katex](https://github.com/MahammadNuriyev62/claude-code-katex) | 24 | MIT | patcht Webview-Bundle der VS-Code-Extension | dritter Weg (Render-Pipeline patchen), nicht übertragbar |
| [LaTerM](https://github.com/MaxwellsEquation/LaTerM) | 55 | MIT | xterm.js `write()` → Hash-Platzhalter + KaTeX-Overlay | tot seit 09/2025; `@nl`-Makro |
| [glow](https://github.com/mil-ad/glow) / [mods](https://github.com/mil-ad/mods) | 1/2 | MIT | Sentinel → codecogs.com → Kitty-Platzhalter | nur `$$`; mods: Terminal per XTGETTCAP erkennen |
| [go-term-latex](https://github.com/floatpane/go-term-latex) | 0 | — | pdflatex/tectonic → PNG → Kitty/Sixel | Theme-Recolor |
| [latex-terminal](https://github.com/GuyAzene/latex-terminal) | 5 | MIT | matplotlib → Kitty | naiver Parser, Randnotiz |
| [opencode-latex-render](https://github.com/FuHao0119/opencode-latex-render) | 5 | MIT | Agent ruft Render-Werkzeug je Formel | Gegenmodell |
| [claude-math](https://github.com/vladimirrott/claude-math) | 18 | MIT | Skill: Unicode statt LaTeX | Gegenmodell |

Außerdem: upmath-mcp (MCP → externe API), DaebangStn/latex-terminal-setup, murzua7/latex-terminal (Skill).
Issues: Claude Code #44479, #63139, #80702, #65777, #21433; Codex #36233, #18906, #46097 (Folio-Maintainer:
Option, TeX verbatim zu lassen — betrifft uns genauso).

---

## 3. Belege im Detail

**Folio** — `crates/bt-detect/src/lib.rs` (8 000 Zeilen, Erkennung/Reparatur/Korpus), `crates/bt-math/src/`
(`MAX_SOURCE_BYTES` 8 KB, Tiefenlimit im Parser, `macro_budget.rs`: statische Kostenanalyse vor Expansion,
`MAX_WORK` 32 K, 128 Definitionen, `\input/\include/\write` gesperrt, `catch_unwind` je Formel),
`crates/bt-term/src/adapter.rs` (XTVERSION, DEC 2026 mit 2-MiB-Puffer + Deadline), `session.rs` (Formeln
während Redraw eingefroren, 200 ms Ruhe je Zeile; `\x1b[2J` ist kein Scroll, weil CC/Codex jeden Frame neu
drucken; Claude Codes „Jump to bottom (ctrl+End)"-Chip macht eine Zeile ungültig). Cache-Key = Renderparameter
(DPI, Schrift, Farbe, Modus) + Quelltext, byte-gewichtete LRU. `tests/corpus/claude-code-session.btcr` =
anonymisierte echte CC-Session als Byte-Aufnahme — Muster für eigene Replay-Tests.

**pi-math** — `src/svg-renderer.ts` (eine Skala für beide Achsen, nie vergrößern; Alpha-Scan mit Rand 1→32 px;
Fehlercodes `tex-error/height-limit/raster-limit/clipped-raster/png-limit`, Fehlschläge negativ gecacht),
`src/transform.ts` (Delimiter-Scanner: Code-Fences, Inline-Code, HTML-`<code>`, `\verb`, `%`-Kommentare,
Environment-Stack), `test/inline-scale.test.ts`.

**iCodeCraft** — `hooks/message-display.py`, `lib/math_spans.py` (`transform_delta`, Zustand je `message_id` in
`CLAUDE_PLUGIN_DATA`), Tests: `Inline $a\,b\;c\!d\frac{1}{2}$.` → `Inline $a\\,b\\;c\\!d\frac{1}{2}$.`;
Code-Fence/Backtick/`$5` bleiben unangetastet. Kein Integrationstest gegen echtes `claude` — vor dem Bau selbst
probieren.

---

## 4. Nächste Schritte

- [x] S-Paket §1.1–1.4 umgesetzt (24.09., + Vollständigkeitsregel §1.9). Bewusst nicht übernommen aus Folios
      Korpus: `价格是 $5$` (auch legitime Mathe) und `+ $$x^2$$` (Diff-Zeile; wir rendern). §1.5 offen, erst messen
- [x] §1.6 umgesetzt (24.09., Werkstatt `9d45f37`): Probe per `script`-Aufzeichnung + Terminal-Replay belegt —
      CC frisst auch in `$$`-Blöcken (iCodeCraft irrt da), `displayContent` wirkt, in Code frisst CC nichts.
      `\(`→`$` war unnötig: verdoppelt kommt `\(…\)` heil an und unser Detektor kennt es.
- [ ] §1.8/1.9 erst nach Alltagsbeobachtung
- [ ] Ergebnisse in `CLAUDE.md` („Known limitations", HIER WEITERMACHEN) übertragen
