# Agents, CLI & internals

Reference for everything behind the clips in the [README](../README.md). The interface of the app itself is German for now.

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
the Inbox count. Open-pane results target an exact pane across all windows. With session hooks,
resume actions focus an already connected session with the same provider and session ID.
The working directory alone never identifies a session. Until its first hook arrives, a new
session is not yet known to Home; launches in that interval are not deduplicated.

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

- **Precise:** hooks report `ready|working|input|done|closed[;detail][;k=v…]` through the control socket. Use `latexterm status --pane ID --agent claude --session SESSION_ID -- PAYLOAD` (or `--agent codex`); optional `--turn ID` rejects stale turn events. `ready` attaches the session and lifts the launch curtain, `closed` detaches it. `detail` describes the tool/question; fields `t` (seconds), `n` (steps), `p` (prompt), `a` (answer), `r` (answer/aborted/refusal/error) feed chips and notifications. Never write status to the TTY beside a running TUI: interleaved escape sequences corrupt its display. OSC 5522 remains accepted for legacy senders.
- **Claude fallback:** without an identified session, grid heuristics detect its spinner/input box; legacy hooks suppress them for 10 minutes. Identified sessions remain hook-driven until their foreground process leaves the pane. Codex panes do not use Claude heuristics or prompt styling.
- Terminal bell (`\a`) and OSC 777 (`\e]777;notify;Title;Body\a`) notify instantly too.

### Codex status setup

The included bridge uses Codex's [lifecycle hooks](https://learn.chatgpt.com/docs/hooks).
From this checkout, with Python 3.9+ and a Codex CLI that supports hooks:

```sh
python3 scripts/install_codex_hooks.py           # preview
python3 scripts/install_codex_hooks.py --apply   # preserve other hooks and notify settings
```

Review and trust the eight LatexTerm entries in Codex `/hooks`, then start or resume a
Codex session inside LatexTerm. The installer copies the bridge into
`~/.local/share/latexterm/` and adds commands to `$CODEX_HOME/hooks.json`
(`~/.codex` by default); rerun it after bridge updates. Existing changed files are backed up.
The bridge reads hook input only, sends bounded text excerpts over the local socket,
and stays silent outside LatexTerm or with an older app. It does not read transcripts.
It checks that the emitting Codex process owns the pane's foreground job; shared background
daemons are not attached by guessing. Settings → **Agenten** controls chips and notifications.

### Per-pane accent color

The pane accent (caret, border, titlebar dot) follows the session — passively from Claude Code's `/color` frame, or explicitly, even through SSH:

```sh
printf '\e]5522;accent=#e85e3e\a'   # set this pane's accent
printf '\e]5522;accent=reset\a'     # back to global/adaptive
```

### Pane kinds — not every pane is a terminal

A pane can be a shell, the home launcher, or an **app pane**: grid, borders, focus, zoom, `⌘W` and the
title-bar chips work the same for every kind. Open them from the **Kachel** menu, the CLI
(`latexterm new-pane --kind …`) or let an agent open them through MCP.

| Kind | What it shows | Hand-back to the agent |
|---|---|---|
| `scratchpad` | Pen, highlighter, eraser in theme colours; `⌘Z`/`⇧⌘Z`, `⌘S` saves a PNG, `⌘C` copies it; survives a restart. | **➤ / `⇧⌘⏎`** puts the sketch into a Claude/Codex prompt as an image. Agents look with `scratch_look` and draw native, erasable elements with `scratch_draw` (SVG subset). |
| `web` | A local HTML file or a dev server on `localhost` — like a browser: reloads when a loaded file changes (CSS without a reload), links, back, dialogs, downloads, `⌘±` `⌘F` `⌘R`, Web Inspector. | Select text or **⌥-click** an element, **`⇧⌘⏎`** sends selector, source line and a crop. Local pages can call `latexterm.send("…")` to prompt the owning session. Agents use `web_look` / `web_act`. |
| `preview` | PDF, image, Office document or a folder of plots; reloads on change and jumps to the changed page. | Mark passages, add a note, **Send** — with page, SyncTeX source line and a crop. Agents use `preview_look` and `sync file.tex:line` to point at a change. |

Remote web content is refused by design, see [SECURITY.md](../SECURITY.md). A new kind is one Swift file in
`LatexTerm/Panes/Contents/` plus one line in `PaneKindRegistry`; its `manual` becomes the agent's
`open_<kind>` tool.

### The `latexterm` CLI

Agents (or you) can drive the terminal from any shell — the app listens on a per-user socket (0600 + peer check, see [SECURITY.md](../SECURITY.md)):

```sh
latexterm list-panes [--json]                     # all windows; index, UUID, CWD, state, provider/session/window IDs
latexterm close-pane [--pane SEL] [--force]       # without --force: idle shell with no foreground job
latexterm new-pane [--cwd DIR] [--exec CMD] [--no-focus]
latexterm new-pane --kind KIND [--arg KEY=VALUE]... [--no-focus]   # e.g. --kind web --arg url=$PWD/plot.html
latexterm pane-kinds                              # terminal, home, scratchpad, web, …
latexterm send [--pane SEL] [--no-enter] TEXT...  # type into a pane (Enter by default)
latexterm zoom [--pane SEL]
latexterm focus [--pane SEL]
```

Indices and unique UUID prefixes address all windows consistently. Without `--pane`, the
calling shell's own pane is targeted (via `$LATEXTERM_PANE_ID`); `new-pane` outside a pane uses
the active window. Focusing raises the owning window. Put the bundled binary on your PATH once:

```sh
ln -s /Applications/LatexTerm.app/Contents/Helpers/latexterm /opt/homebrew/bin/latexterm
```

That closes the loop: a Claude Code session can open panes, start fresh Claudes in them, prompt them, and watch their status — Claude orchestrating Claude.

### MCP server — `latexterm mcp`

The same binary speaks the [Model Context Protocol](https://modelcontextprotocol.io) over stdio, so agents get
LatexTerm as native tools instead of shell commands — and know where they are without a skill having to load:

```sh
claude mcp add -s user latexterm -e 'LATEXTERM_START_CLAUDE=claude' -- /opt/homebrew/bin/latexterm mcp
codex mcp add latexterm -- /opt/homebrew/bin/latexterm mcp   # then add env_vars = ["LATEXTERM_PANE_ID"] to its [mcp_servers.latexterm]
```

- **Intent-level tools:** `panes`, `open_terminal`, `start_agent`, `ask_session`, `wait_session`, `run_in_pane`,
  `pane_action`, `focus_pane`, `close_pane` — plus one `open_<kind>` per app pane kind (`open_web`, `open_scratchpad`, `open_preview`),
  generated from each kind's self-description (`pane-kinds` → `kindInfos`). A new pane kind becomes a new tool with no
  server change.
- **Shared scratchpad:** `scratch_look` returns the pad as an image with a labelled coordinate grid (world units,
  0,0 = pane centre, y down) plus where the user's and the agent's strokes are; `scratch_draw` takes an SVG subset
  (paths incl. arcs, basic shapes, text, transforms, `marker-end` arrowheads) and turns it into native, erasable
  elements in theme colours — a `viewBox` is fitted into the visible area, no viewBox means world coordinates;
  `replace: "mats"` swaps the user's sketch for a clean version in one undo step. `scratch_clear` removes a layer.
  Underneath: control command `call` (request with reply, `latexterm call`), `send --paste` (bracketed paste).
- **Seeing the panes:** `web_look` (screenshot, page text, console; `full` for the whole page), `web_act` (click, type,
  scroll in a web pane), `preview_look` (what the preview shows). 
- **Situational instructions:** on `initialize` the server tells the model which pane it is in, what else is open and
  what panes are good for (show results, run long processes beside the chat, parallel agents).
- **Guard rails by construction:** new panes open without stealing focus; no `force` close; never types into its own
  pane; `run_in_pane` refuses agent sessions and busy programs unless asked; prompts to agents go through the pane's
  mailbox (`~/Library/Application Support/LatexTerm/mailbox/<pane-uuid>/*.md`, delivered by a receiver inside the
  session) and fall back to a two-step paste; a session may close foreign panes only with an explicit `foreign` flag.
- **Scope:** outside a LatexTerm pane (`$LATEXTERM_PANE_ID` unset) the server offers no tools. Agent start commands come
  from `LATEXTERM_START_CLAUDE` / `LATEXTERM_START_CODEX` (defaults `claude` / `codex`).

## How the LaTeX overlay works

```
PTY (login shell) → SwiftTerm VT parser → buffer grid
      → OverlayController scans visible rows
      → LaTeXDetector finds delimited formulas
      → one shared WKWebView + KaTeX renders each as a positioned <div>
```

- One WebView hosts *all* formulas; KaTeX loads once, offline (bundled CSS/JS/fonts).
- Overlay identity uses column, formula body and occurrence; grid rows position them. Scrolling repositions surviving overlays instead of rebuilding them.
- Detection handles soft-wrapped inline formulas, Claude Code's own word-wrap (indented continuation lines) and multi-line `$$ … $$` blocks; inline hits scale to fit their row and grow into empty neighbour rows.
- The source characters under a formula are drawn transparent by the terminal itself (no mask), so selection and coloured backgrounds stay intact.
- Clicks on empty space pass through to normal terminal selection; only formula hitboxes are interactive.

The deep-dive lives in the source — start at `LatexTerm/Latex/OverlayController.swift`.

## Known limitations

- A formula whose opener is scrolled off above the viewport (or that wraps past the bottom) isn't detected; multi-line `$$` blocks need each delimiter alone on its line (a leading marker like `⏺ ` is fine).
- Claude Code's Markdown renderer strips the backslash before ASCII punctuation, so `\(…\)`, `\[…\]`, `\,`, `\{` and `\$` never reach the terminal intact — use `$…$`, `\thinspace`, `\lbrace`. Matrix row breaks (`\\`) are repaired heuristically.
- A fraction squeezed between two text lines still shrinks to one row height — hover for the full-size view.
- `$` in prose is filtered by Pandoc's rule (no space right of the opener / left of the closer, no digit after the closer) and by colour: opener and closer must share the cell colour, so a `$PATH` in a code span never pairs with a prose `$`. Price: `$ x $` with inner spaces isn't a formula — write `$x$` or `\( x \)`.
- Ligatures are off by design (bundled font is the NL variant); a ligature font can still be chosen, but glyphs then may not align with cells.

