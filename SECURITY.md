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
- **Cmd-click link opening (standard terminal behaviour):** Cmd-clicking a link
  opens arbitrary URL schemes via `NSWorkspace` (http, mailto, custom schemes…);
  file paths are resolved against the OSC 7 working directory and revealed via
  Finder/default app. This matches what mainstream terminals do — treat terminal
  output from untrusted sources accordingly.
