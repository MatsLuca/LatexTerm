# Contributing to LatexTerm

Thanks for your interest in improving LatexTerm! This is a small, actively
maintained project and contributions of all sizes are welcome.

## Ways to contribute

- **Report a bug** — open an issue with the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include your macOS version, a sample formula, and a screenshot of the misrender if possible.
- **Request a feature** — use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
- **Send a pull request** — see below.

## Development setup

1. macOS 14+, Xcode 26+ with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
2. `open LatexTerm.xcodeproj` and `Cmd+R`.
3. The terminal/LaTeX architecture is documented in the [README](README.md#how-it-works).

## Pull request guidelines

- Keep PRs focused on one change; describe the *why*, not just the *what*.
- Match the surrounding Swift style (the codebase favors small, single-purpose types).
- If you change formula detection or rendering, include a sample formula in the PR description that demonstrates the before/after.
- The CI build (`.github/workflows/build.yml`) must pass.

## Vendored SwiftTerm

`SwiftTermLocal/` is a vendored MIT fork of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
The patches we depend on (notably `extraLineSpacing` and `lineCellSize` on `TerminalView`) must
survive any re-vendor — see the README's *Project layout* notes. Don't edit vendored files for
app-level behavior; prefer subclassing in `LatexTerm/`.

## Code of conduct

Be respectful and constructive. Harassment or abuse won't be tolerated.
