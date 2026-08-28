import AppKit
import CoreText

/// Schriften der App: gebündelte JetBrains Mono NL (Ghosttys Standardschrift; „NL“ = ohne
/// Ligaturen, weil der Terminal-Renderer zellgenau zeichnet und die Formel-Overlays an
/// Zellkoordinaten hängen) plus die Wahl der Terminal-Familie.
///
/// Die TTFs liegen flach in `Contents/Resources` (synchronized group) und werden beim ersten
/// Zugriff prozessweit registriert — kein `ATSApplicationFontsPath`, keine Installation auf
/// dem Rechner nötig. Die Familie ist damit auch für `NSFontManager` sichtbar, das SwiftTerm
/// für Bold/Italic nutzt.
enum AppFonts {
    static let bundledFamily = "JetBrains Mono NL"

    /// Einmal pro Prozess: alle `.ttf` im Bundle registrieren.
    static let registerBundled: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), let e = error?.takeRetainedValue() {
                // Bereits registriert ist kein Fehler (z. B. nach Hot-Reload) — nur loggen.
                NSLog("AppFonts: \(url.lastPathComponent): \(e.localizedDescription)")
            }
        }
    }()

    /// Gewählte Familie (`ThemeStore.fontFamily`); leer = System-Monospace (SF Mono).
    static var storedFamily: String { ThemeStore.shared.fontFamily }

    /// Terminal-/UI-Schrift in der gewählten Familie. Gewichte ≥ semibold nehmen den Bold-Schnitt;
    /// fehlt die Familie (nicht installiert, Tippfehler), fällt alles auf SF Mono zurück.
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular, family: String? = nil) -> NSFont {
        _ = registerBundled
        let fam = family ?? storedFamily
        guard !fam.isEmpty, let base = NSFont(name: fam, size: size) ?? familyFont(fam, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        if weight.rawValue >= NSFont.Weight.semibold.rawValue {
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }

    /// Gibt es die Familie (installiert oder gebündelt)?
    static func familyExists(_ family: String) -> Bool {
        _ = registerBundled
        return NSFont(name: family, size: 12) != nil || familyFont(family, size: 12) != nil
    }

    /// `NSFont(name:)` will einen PostScript-/Display-Namen; Familiennamen wie „JetBrains Mono NL“
    /// gehen über den Font-Manager (Regular-Schnitt).
    private static func familyFont(_ family: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    /// Alle Monospace-Familien für den Picker: gebündelte zuerst, dann die installierten (fixed pitch).
    static var availableMonospaceFamilies: [String] {
        _ = registerBundled
        var names: [String] = [bundledFamily]
        for fam in NSFontManager.shared.availableFontFamilies where fam != bundledFamily {
            if let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 12), f.isFixedPitch {
                names.append(fam)
            }
        }
        return names
    }
}
