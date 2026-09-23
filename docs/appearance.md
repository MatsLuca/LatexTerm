# Appearance


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

![Ghostty and LatexTerm side by side](optik-side-by-side.png)

