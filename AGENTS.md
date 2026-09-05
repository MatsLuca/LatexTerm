# LatexTerm — Codex

If `CLAUDE.md` exists locally, read it before working here. It carries the shared
project context and current status. It is intentionally gitignored, so a public
checkout may not contain it. Do not add private machine context to this public file.

For a checkout without local guidance, read README.md and SECURITY.md, then the source
files relevant to the task. LatexTerm is a native macOS terminal with a vendored
SwiftTerm fork and KaTeX overlays. App Sandbox is intentionally disabled for PTY access.

Build with `xcodebuild -project LatexTerm.xcodeproj -scheme LatexTerm -configuration Debug build`.
Run tests with `xcodebuild test -project LatexTerm.xcodeproj -scheme LatexTerm
-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (one shell command).
A runnable development build should retain signing and the default DerivedData location.
Never terminate the user's running terminal to replace it; let the user restart the app.

Keep launcher commands and personal paths in the external data source. Home renders
its JSON contract. Preserve compatibility with older data: optional provider fields
must not change existing Claude actions. Terminal-only agents must not receive Claude
slash commands, prompt styling or inferred Claude session status.

Formula overlays use terminal grid positions; keep the vendored fork hooks and
selection/scroll behavior intact. Project context belongs in one maintained source;
do not restore a dated copy of local CLAUDE.md into this file.
