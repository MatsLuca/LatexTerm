# App-Icon (seit 21.09.2026, Testwoche)

Motiv: drei Kacheln in schwarzem Alu — Session mit Status-LED, Σ (Formeln), leuchtende Prompt-Kachel.
Skizze `skizze_C4.svg`, Bild per Codex-Bildgenerierung (`artwork_codex_original_1254.png`), zentriert und
auf 1024 gebracht (liegt als `LatexTerm/AppIcon.icon/Assets/artwork.png`).

## So ist es eingebaut

- `LatexTerm/AppIcon.icon` (Icon-Composer-Format): **eine** vollflächige Bitmap-Ebene, Glas/Specular/Schatten aus.
  Das System schneidet die Form selbst zu und legt den Lichtrand an; Dark/Getönt/Klar entstehen automatisch.
- `Assets.xcassets/AppIcon.appiconset`: Rückfall für macOS 14/15, mit `ictool` aus derselben `.icon` gerendert.
  Gleicher Name `AppIcon` — Xcode nimmt ab macOS 26 die `.icon`.

## Regeln für macOS 26/27 (gemessen am 21.09.2026 auf macOS 27.0)

- Motiv **randlos und deckend** anlegen: keine eigenen runden Ecken, kein Schatten, keine eigene Fase.
  Inhalt auf etwa 76 % der Kantenlänge, mittig.
- Klassische PNG-Icons mit transparentem Rand landen im grauen Kasten. Auch vollflächige PNGs sind unsicher:
  das System entscheidet **je Größe** nach Bildinhalt (32 px fiel immer durch, ein heller Rand ebenfalls).
  Deshalb `.icon` statt PNG-Satz.
- Prüfen, was das System wirklich zeichnet: `NSWorkspace.shared.icon(forFile:)` in ein PNG rendern.

## Neu rendern

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" "$PWD/LatexTerm/AppIcon.icon" --export-image --output-file out.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 2
```

Das alte Icon (Glas-Integral) steht in der Git-Historie vor diesem Commit.
