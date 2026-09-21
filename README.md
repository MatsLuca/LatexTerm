# LatexTerm

[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-black)](#install)
[![Language: Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A native macOS terminal that renders LaTeX live over the text — with a shared launcher for **Claude Code and Codex** sessions.

![LatexTerm demo: a Claude Code agent orchestrates panes via the latexterm CLI, then LaTeX renders live over a Claude explanation](docs/demo.webp)

## Highlights

- **Live LaTeX overlays** — formulas between `$…$`, `$$…$$`, `\(…\)`, `\[…\]` render as KaTeX exactly on their source characters. No OCR: a vendored SwiftTerm fork exposes the real cell grid.
- **Hover, pin & export** — hover shows a formula full-size; a click pins it with copy buttons: **LaTeX**, **readable Unicode** (`(-b ± √(b²-4ac))/(2a)`), **PNG**, **vector PDF**, **Markdown**.
- **Edit loop** — ✎ opens the formula in an inline editor with live preview; Enter types the result into your prompt.
- **Auto-tiling panes** — ⌘T splits into a balanced grid, ⌘⏎ zooms one pane, layout + working dirs survive a relaunch.
- **Claude + Codex launcher** — provider-specific resume, quotas, pins and titles; projects, tasks and pins in one Home screen. ⌘K or typing opens one search palette; `/` explicitly sends a free AI prompt when the optional backend is installed.
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
- Detection handles soft-wrapped inline formulas, Claude Code's own word-wrap (indented continuation lines) and multi-line `$$ … $$` blocks; inline hits scale to fit their row and grow into empty neighbour rows.
- The source characters under a formula are drawn transparent by the terminal itself (no mask), so selection and coloured backgrounds stay intact.
- Clicks on empty space pass through to normal terminal selection; only formula hitboxes are interactive.

The deep-dive lives in the source — start at `LatexTerm/Latex/OverlayController.swift`.

</details>

## Agent integration

Everything here is a plain terminal mechanism — escape sequences, an env var, a Unix socket. Nothing is hardwired to Claude; any agent or script can use the same channels.

### Home pane — project launcher (`⌘N`)

**Current launcher:** choose **Claude / Codex** per folder. Both offer new sessions, direct
resume, pins (`⌘P`), rename (`⌘E`) and shared follow-ups; Codex also keeps its native resume
picker as a fallback. Codex titles are native, while Codex pins belong to the launcher.
Provider badges distinguish actions and quota windows (including Claude's Fable quota).
Claude-specific maintenance stays separately labelled; its status/color heuristics do not
run on Codex panes. Codex has its own dismissible startup curtain.

Home navigation groups **Projekte / Aufgaben / Pins**; tasks group due follow-ups and show
the Inbox count. Open-pane results target the exact pane in the current window, not simply
another pane with the same folder. Reliable live session identity is not yet available.

**One search bar:** `⌘K` and typing in Home open the same palette, preserving the first
character. Empty, it shows what matters now: panes waiting for input, due follow-ups, recent
sessions, actions for the selected folder, pins. Ordinary text searches locally across
sessions (titles and last prompt), projects, actions, panes and folders, grouped with match
highlighting, filter chips (`⇥`), project colours and status pills; `⏎` runs the primary
action, `⌘⏎` the secondary one (resume + `/compact`, new session, shell only), `⌘C` copies
the session ID or path. Start
with `/` and press Enter to send a free AI prompt through the optional external
`projekte assist` backend. This can find sessions with source excerpts, propose a session
or Claude/Codex pair, answer questions, or compare answers deliberately pasted into the prompt.
New sessions require a separate preview confirmation. Normal typing does not call a model;
explicit AI requests use the configured backend/account quota and may send selected session
excerpts. Search is bounded to recent candidates, not the full archive. Escape cancels.

Additional controls live in the **Home menu**: new project `⌘⇧N`, reload `⌘R`,
pin project/folder `⌘⇧P`, key help `⌘/`, only projects `⌘⇧B`, and expand/collapse all
`⌘⇧A` / `⌘⇧E`. `⌘T` remains a plain shell inheriting the focused pane's working directory.
Quota data refreshes via `projekte limits --json --agent <provider>`; unavailable or stale
data is distinguished from zero usage. Follow-ups use the same external task store for both agents.

The data comes from an external CLI — `projekte --json` (run through your login shell; change it in *Settings → Erweitert*). Without it the pane shows a hint and nothing else breaks. The contract (JSON shape) lives with the CLI, not in the app.

### Desktop widgets

LatexTerm ships a WidgetKit extension with two widgets for the macOS desktop and
Notification Center: **Claude-Cockpit** (5h / 7d / model quota rings plus what is due —
follow-ups and Reminders; small, medium, large) and **Claude Wrapped** (today's sessions,
replies, tokens, streak and a 28-day bar chart; small, medium). The widgets read only a
JSON snapshot from the app group; the app writes it on launch and every 5 minutes through
the configurable *Widget command* (`projekte widget`, *Settings → Erweitert*). Clicking a
widget brings LatexTerm to the front and focuses a Home pane; reminder rows open Reminders.

### Status & notifications

Each pane tracks its session as a **chip in the titlebar** (its colored dot plus a live status: `Bash · 0:42 · 3 steps`, `needs you`, then `✓ done · 1:42` until you've looked; idle panes show only the dot). Clicking a chip focuses the pane. **done** / **needs input** also post a macOS notification when the pane is unwatched (your prompt, duration, steps and the first line of the answer); clicking it focuses and zooms the pane.

- **Precise:** a Claude Code hook (best: a function-hooks mod) reports `working|input|done|ready[;detail][;k=v…]` via `latexterm status --pane ID PAYLOAD` (control socket). Don't send it as OSC to the pane's tty while Claude Code is running — a second writer on the line tears the TUI's escape sequences apart and leaves rendering garbage (`\e]5522;status=…\a` is still accepted for legacy senders). `detail` is the tool name or the open question; optional fields `t` (seconds), `n` (tool steps), `p` (prompt), `a` (answer), `r` (reason: answer/aborted/refusal/error) feed the pill (`◐ Bash · 0:42 · 3 steps`, then `✓ done · 1:42 · 7 steps` until you've looked) and the notification body. `ready` only lifts the home-tile launch curtain.
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
latexterm close-pane [--pane SEL] [--force]       # close a pane; without --force only an idle shell or Claude awaiting input
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

- A formula whose opener is scrolled off above the viewport (or that wraps past the bottom) isn't detected; multi-line `$$` blocks need each delimiter alone on its line (a leading marker like `⏺ ` is fine).
- Claude Code's Markdown renderer strips the backslash before ASCII punctuation, so `\(…\)`, `\[…\]`, `\,`, `\{` and `\$` never reach the terminal intact — use `$…$`, `\thinspace`, `\lbrace`. Matrix row breaks (`\\`) are repaired heuristically.
- A fraction squeezed between two text lines still shrinks to one row height — hover for the full-size view.
- `$` in prose is filtered by Pandoc's rule (no space right of the opener / left of the closer, no digit after the closer) and by colour: opener and closer must share the cell colour, so a `$PATH` in a code span never pairs with a prose `$`. Price: `$ x $` with inner spaces isn't a formula — write `$x$` or `\( x \)`.
- Ligatures are off by design (bundled font is the NL variant); a ligature font can still be chosen, but glyphs then may not align with cells.

## License

MIT — © 2026 Mats Luca Dagott. Bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT, vendored fork at `SwiftTermLocal/`) and [KaTeX](https://katex.org) 0.16.47 (MIT; fonts under SIL OFL 1.1) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) NL 2.304 (SIL OFL 1.1) — see [`NOTICE`](NOTICE). The demo above is rendered programmatically with [Remotion](https://remotion.dev) (`demo-video/`).
