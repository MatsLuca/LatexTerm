# LatexTerm

[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-black)](#install)
[![Language: Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A native macOS terminal that renders LaTeX live over the text — and doubles as a cockpit for **Claude Code** sessions.

![LatexTerm demo: a Claude Code agent orchestrates panes via the latexterm CLI, then LaTeX renders live over a Claude explanation](docs/demo.webp)

## Highlights

- **Live LaTeX overlays** — formulas between `$…$`, `$$…$$`, `\(…\)`, `\[…\]` render as KaTeX exactly on their source characters. No OCR: a vendored SwiftTerm fork exposes the real cell grid.
- **Hover, pin & export** — hover shows a formula full-size; a click pins it with copy buttons: **LaTeX**, **readable Unicode** (`(-b ± √(b²-4ac))/(2a)`), **PNG**, **vector PDF**, **Markdown**.
- **Edit loop** — ✎ opens the formula in an inline editor with live preview; Enter types the result into your prompt.
- **Auto-tiling panes** — ⌘T splits into a balanced grid, ⌘⏎ zooms one pane, layout + working dirs survive a relaunch.
- **Claude Code cockpit** — every pane knows whether its agent is working, done, or waiting for input, notifies you, and picks up the session's `/color` as its accent. Agents drive the terminal themselves via the `latexterm` CLI.
- Plus: ⌘F search, KaTeX errors underlined instead of swallowed, overlays that follow the scroll, a native settings window (⌘,).

## Why

The predecessor ([LatexTerminalLive](https://github.com/MatsLuca/LatexTerminalLive)) read another terminal's screen with OCR — too flaky for greek glyphs and fractions. LatexTerm *is* the terminal, so formula positions come straight from the cell grid. Owning the grid paid off twice: the same buffer access now powers the Claude Code session detection.

<details>
<summary><b>How the LaTeX overlay works</b></summary>

```
PTY (login shell) → SwiftTerm VT parser → buffer grid
      → OverlayController scans visible rows
      → LaTeXDetector finds delimited formulas
      → one shared WKWebView + KaTeX renders each as a positioned <div>
```

- One WebView hosts *all* formulas; KaTeX loads once, offline (bundled CSS/JS/fonts).
- Overlays are keyed to the absolute scrollback row — scrolling repositions them (one GPU-composited translate) instead of rebuilding.
- Detection handles soft-wrapped inline formulas and multi-line `$$ … $$` blocks; inline hits scale to fit their row.
- Clicks on empty space pass through to normal terminal selection; only formula hitboxes are interactive.

The deep-dive lives in the source — start at `LatexTerm/Latex/OverlayController.swift`.

</details>

## Claude Code integration

Everything here is a plain terminal mechanism — escape sequences, an env var, a Unix socket. Nothing is hardwired to Claude; any agent or script can use the same channels.

### Home pane — project launcher (`⌘N`)

The first pane on launch (and every `⌘N`) is a **home pane** instead of a shell: the folder tree of your projects on the left (Finder order; ▣ project, ▤ area, ● where a Claude pane is running), and on the right the actions for the selected folder — **＋ Neue Session** (default: type an alias, hit `⏎`), **↻ Weiter** (resume the last session, titled from Claude Code's own `ai-title` entries), **› Nur Shell**, and a collapsed **▸ Sessions** row (`→` opens it: pin, rename, the most recently active projects below that folder and earlier sessions; `←` closes). Typing filters the tree, `→`/`←` expand/collapse or move between tree and actions, `⏎` runs the first action, `⌘⇧N` opens the new-project dialog — name, alias, a one-sentence purpose, and the place: the selected folder, any folder via a Finder picker, or *"noch offen"* (not decided yet), which starts Claude at the root with `--einordnen` to work out where the project belongs before creating it. `⌘P` pins a session, `⌘⇧P` pins a project/folder (`⇧⇥` shows the pin screen — projects on top, sessions below; a pinned project offers new session / resume / shell directly), `⌘E` renames one — the custom title overrides Claude Code's `ai-title` (`projekte rename <id> [title]`, empty = back to automatic). `⌘T` stays a plain shell inheriting the focused pane's CWD. The pane has no footer: its commands live in the **Home menu** in the menu bar (new project `⌘⇧N`, reload `⌘R`, pin session/project `⌘P`/`⌘⇧P`, rename `⌘E`, show pins, key help `⌘/`, **only projects** `⌘⇧B` — hides every folder that is neither a project nor ever had a session — and **expand/collapse all** `⌘⇧A`/`⌘⇧E`), and everything that cannot be a menu command — arrows, `⇥`/`⇧⇥`, `⏎`, type-to-search, the glyph legend — is one keystroke away in that key help (`⌘/`; Esc or a click closes it).

Above the tree a notice strip shows panes that are **waiting for you** (click → jump there; the same jump is the first action of a folder that already has a running pane) and due **follow-ups** from `~/.claude/wiedervorlage/`. The header on the right carries what the tree cannot: alias, CLAUDE.md headline, git state, last activity, and the last prompt of the session you would resume. Type-to-search also matches session titles.

The top right corner shows your subscription's **quota**: 5-hour window, week and model week with percentage and a live countdown to the reset (red from 85 %). It refreshes every 30 s via `projekte limits --json` (change the command in *Settings → Erweitert*) and stays empty if that command is missing.

The data comes from an external CLI — `projekte --json` (run through your login shell; change it in *Settings → Erweitert*). Without it the pane shows a hint and nothing else breaks. The contract (JSON shape) lives with the CLI, not in the app.

### Status & notifications

Each pane tracks its session: **working** (titlebar dot pulses, a floating pill in the pane shows the current tool live) → **done** / **needs input** (macOS notification if the pane is unwatched; clicking it focuses and zooms the pane).

- **Precise:** Claude Code hooks write `\e]5522;status=working|input|done|ready[;detail]\a` to the pane's tty — `detail` (e.g. the tool name from a `PreToolUse` hook) becomes the pill text. `ready` (from a `SessionStart` hook) only lifts the home-tile launch curtain.
- **Zero-config fallback:** the pane detects spinner vs. input box straight from the buffer grid; a fresh hook signal silences it for 10 minutes (hooks win, the fallback self-heals crashed sessions).
- Terminal bell (`\a`) and OSC 777 (`\e]777;notify;Title;Body\a`) notify instantly too.

### Per-pane accent color

The pane accent (caret, border, titlebar dot) follows the session — passively from Claude Code's `/color` frame, or explicitly, even through SSH:

```sh
printf '\e]5522;accent=#e85e3e\a'   # set this pane's accent
printf '\e]5522;accent=reset\a'     # back to global/adaptive
```

### Appearance — themes, font, padding

LatexTerm renders like Ghostty out of the box: theme **Dark+**, bundled **JetBrains Mono NL** at 20 pt,
xterm-256 colors, bold stays bold, steady block cursor, 12 px padding. Everything lives in
*Settings → Darstellung* (⌘,). The settings window has six tabs —
Allgemein (home tree, Ghostty import), Darstellung, Kacheln (accent, focus), Claude
(notifications, prompt text), Formeln, Erweitert (launcher data commands, control socket, reset):

- **Themes** are Ghostty theme files. `Dark+` and `Ember` (the old warm black) are built in; if Ghostty is
  installed, all of its ~460 themes appear in the picker. Every surface follows the theme — panes, home
  pane, launch ring, status pills, formula overlays.
- **Font**: any installed monospace family or the bundled JetBrains Mono NL (no ligatures on purpose —
  the renderer is cell-exact and formula overlays sit on cell coordinates).
- **Import from Ghostty**: one button reads `~/.config/ghostty/config` (theme, font, size, padding,
  cursor blink, bold-is-bright) and previews the changes before applying. Color overrides in the config
  become the theme „Ghostty (Config)“. Lives in *Settings → Allgemein*.

![Ghostty and LatexTerm side by side](docs/optik-side-by-side.png)

### The `latexterm` CLI

Agents (or you) can drive the terminal from any shell — the app listens on a per-user socket (0600 + peer check, see [SECURITY.md](SECURITY.md)):

```sh
latexterm list-panes [--json]                     # index, UUID, CWD, session state
latexterm new-pane [--cwd DIR] [--exec CMD]
latexterm send [--pane SEL] [--no-enter] TEXT...  # type into a pane (Enter by default)
latexterm zoom [--pane SEL]
latexterm focus [--pane SEL]
```

Without `--pane`, the calling shell's own pane is targeted (via `$LATEXTERM_PANE_ID`). Put the bundled binary on your PATH once:

```sh
ln -s /Applications/LatexTerm.app/Contents/Helpers/latexterm /opt/homebrew/bin/latexterm
```

That closes the loop: a Claude Code session can open panes, start fresh Claudes in them, prompt them, and watch their status — Claude orchestrating Claude.

## Install

Grab `LatexTerm.app` from [**Releases**](https://github.com/MatsLuca/LatexTerm/releases), unzip, drop into `/Applications`. The build is unsigned — right-click → **Open** on first launch, or:

```sh
xattr -dr com.apple.quarantine /Applications/LatexTerm.app
```

<details>
<summary><b>Build from source</b></summary>

Needs Xcode 26+ with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
open LatexTerm.xcodeproj    # then Cmd+R  (App Sandbox is off on purpose: PTY rights)
```

```sh
# CLI build + tests
xcodebuild -project LatexTerm.xcodeproj -scheme LatexTerm -configuration Release \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project LatexTerm.xcodeproj -scheme LatexTerm \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

</details>

## Shortcuts

| | |
|---|---|
| `⌘N` | new **home pane** (project launcher) |
| `⌘T` / `⌘W` | new shell pane (inherits CWD) / close pane |
| `⌘1…9` | grow the grid to N panes |
| `⌘⏎` | zoom the focused pane (toggle) |
| `⌘F` | find in the focused pane |
| `⌘+` `⌘-` `⌘0` | font size (all panes, persisted) |
| `⌘L` | toggle formula overlays |
| `⌘,` | settings window (six tabs — theme, font, line spacing, accent, formula scale, notifications …) |

**Tip — testing formulas:** zsh `echo` mangles backslashes; use `printf '%s\n' '$E=mc^2$'` or a quoted here-doc.

## Known limitations

- A formula whose opener is scrolled off above the viewport (or that wraps past the bottom) isn't detected; multi-line `$$` blocks need each delimiter alone on its line.
- Two bare `$` in prose (`echo $PATH and $HOME`) still pair into a false formula — every safe heuristic broke legit math, so math correctness wins.
- Ligatures are off by design (bundled font is the NL variant); a ligature font can still be chosen, but glyphs then may not align with cells.

## License

MIT — © 2026 Mats Luca Dagott. Bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT, vendored fork at `SwiftTermLocal/`) and [KaTeX](https://katex.org) 0.16.9 (MIT; fonts under SIL OFL 1.1) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) NL 2.304 (SIL OFL 1.1) — see [`NOTICE`](NOTICE). The demo above is rendered programmatically with [Remotion](https://remotion.dev) (`demo-video/`).
