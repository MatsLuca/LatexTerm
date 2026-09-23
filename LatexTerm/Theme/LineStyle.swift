import AppKit

/// Stil „Linie“ (23.09.2026): Punkt · Nummer · Text in Mono 11, aktiv = 2-pt-Strich in Kachel-/Tonfarbe,
/// Hover = leise Fläche, keine Kapseln/Ränder/getönten Flächen. Eine Quelle für Maße, Deckkraft und die
/// Bedeutung der Farben — vorher hatten Chips, Home, ⌘K und Hinweise je eine eigene Farbtabelle
/// (UI-Inventar `claude-werkstatt/plans/ui-inventar_2026-09-23.html`).
enum LineStyle {
    // Maße
    static let itemHeight: CGFloat = 22
    static let tabHeight: CGFloat = 24
    static let dotSize: CGFloat = 6
    static let underline: CGFloat = 2
    static let underlineInset: CGFloat = 3
    static let hoverRadius: CGFloat = 5
    /// Schwebe-Grund: die einzige erlaubte Fläche (Leisten über fremdem Inhalt).
    static let groundRadius: CGFloat = 8
    static let groundAlpha: CGFloat = 0.94

    // Deckkraft von `foreground`
    static let textFocused: CGFloat = 0.92
    static let numberFocused: CGFloat = 0.75
    static let text: CGFloat = 0.5
    static let number: CGFloat = 0.4
    static let faint: CGFloat = 0.22
    static let track: CGFloat = 0.10
    static let divider: CGFloat = 0.08
    static let hover: CGFloat = 0.07

    static func font(_ size: CGFloat = 11, _ weight: NSFont.Weight = .medium) -> NSFont {
        AppFonts.mono(size: size, weight: weight)
    }
    static var numberFont: NSFont { font(11, .bold) }
    static var fg: NSColor { ThemeStore.shared.theme.foreground }
}

/// Bedeutung → Farbe. Werte aus dem Theme (helle ANSI-Reihe), damit jedes Ghostty-Theme passt;
/// `claude` aus Claudes `/color`-Palette (Home lädt sie mit den Projektdaten).
enum Tone {
    /// Agent braucht dich — gelb wie Chip und Reiter-Abzeichen (vorher im Home orange).
    case waiting
    /// läuft, arbeitet, weiter
    case running
    /// neu, starten, bereit, Hinweis
    case start
    /// fällig, angepinnt, kompaktieren
    case due
    case error
    /// Shell, Ordner, umbenennen
    case shell
    /// Bereich, Vorlage
    case area
    /// Claude/KI selbst
    case claude
    case muted

    var color: NSColor {
        let t = ThemeStore.shared.theme
        switch self {
        case .waiting, .due: return t.yellow
        case .running: return t.green
        case .start: return t.cyan
        case .error: return t.red
        case .shell: return t.blue
        case .area: return t.violet
        case .claude: return HomePaneView.orange
        case .muted: return t.faint
        }
    }

    /// Session-Zustand aus Steuerkanal/Home (`awaitingInput`, `working`, `ready`, sonst Shell).
    static func pane(_ state: String) -> Tone {
        switch state {
        case "awaitingInput": return .waiting
        case "working": return .running
        case "ready": return .start
        default: return .muted
        }
    }
}
