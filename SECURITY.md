# Security Policy

## Reporting a vulnerability

LatexTerm is a local macOS terminal emulator that spawns your login shell and
renders terminal output. It runs **with the App Sandbox intentionally disabled**
(the terminal needs unrestricted PTY/process-spawn rights), so it has the same
privileges as any terminal you run.

If you find a security issue — for example, a way for terminal output to escape
the formula-rendering WebView, execute unintended code, or read files outside the
user's intent — please report it privately:

- Use GitHub's **[Report a vulnerability](https://github.com/MatsLuca/LatexTerm/security/advisories/new)** (Security → Advisories), **or**
- Open a minimal issue asking for a private contact channel (do not include exploit details in the public issue).

Please do not open a public issue with full exploit details before a fix is available.

## Scope notes

- KaTeX and SwiftTerm are vendored; upstream vulnerabilities in those should be
  reported to their respective projects, but feel free to flag them here so the
  vendored copy can be updated.
- **Accessibility interface (by design):** `LatexTerminalView` exposes an
  `AXTextArea` role whose `setAccessibilityValue`/`setAccessibilitySelectedText`
  write the given text **directly into the PTY**. This exists so dictation apps
  (e.g. SuperWhisper) can insert text; it also means *any* app holding the
  macOS Accessibility permission can inject shell input. That capability is
  inherent to the Accessibility permission itself (keystroke synthesis could do
  the same), but it is worth knowing it is an intentional, documented surface —
  not an oversight.
- **In-band pane control channel, OSC 5522 (by design):** any program writing to
  a pane's PTY can emit `ESC ] 5522 ; key=value BEL/ST` to control cosmetic
  per-pane state — currently `accent=#RRGGBB` / `accent=reset` (accent colour of
  caret, focus border, zoom badge). This is intentionally in-band (like OSC 7/8)
  so Claude Code hooks/statuslines can drive it without extra infrastructure. The
  parser is strict (exactly 6 hex digits or `reset`; unknown keys ignored) and the
  effect is purely visual — no command execution, no file access, no persistence.
  Untrusted output (`cat`-ing a hostile file) can therefore recolour a pane, which
  matches the blast radius of standard OSC 4/10/11 colour sequences in mainstream
  terminals. Future keys added to this channel must keep that cosmetic-only bar or
  gain explicit confirmation UI.
- **Local control socket + `latexterm` CLI, #28 (by design):** the app listens on
  a Unix domain socket (`~/Library/Application Support/LatexTerm/control.sock`,
  created with mode 0600) through which the bundled `latexterm` CLI can list
  panes, open new panes (optionally running a command), **inject text into a
  pane's PTY** (`send`, text injection = command execution), zoom and focus
  panes. This is the deliberate foundation for Claude-Code meta-work ("open
  three panes and prompt each"). Mitigations: no TCP, socket file is 0600 inside
  the user's home, and every connection is checked with `getpeereid()` — only
  processes of the same user may speak. The accepted residual risk is the same
  as for the Accessibility surface above: a process that already runs as the
  user can achieve the same effect by other means (spawning shells directly).
  Anything that would widen the caller set (TCP, world-writable socket,
  privileged helper) must not be added without a confirmation UI.
- **Cmd-click link opening (standard terminal behaviour):** Cmd-clicking a link
  opens arbitrary URL schemes via `NSWorkspace` (http, mailto, custom schemes…);
  file paths are resolved against the OSC 7 working directory and revealed via
  Finder/default app. This matches what mainstream terminals do — treat terminal
  output from untrusted sources accordingly.
