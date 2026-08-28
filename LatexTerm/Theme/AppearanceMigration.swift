import Foundation

/// Einmalige Umstellung bestehender Installationen auf den Ghostty-Look (Runde 27, 28.08.2026):
/// Schriftgröße 20 und Zeilenabstand 0 sind neue Defaults — wer vorher die alten Defaults
/// (bzw. Mats' 18 pt) gespeichert hatte, bekommt sie einmal umgesetzt; danach gilt, was der
/// Nutzer einstellt. Marker-Key verhindert Wiederholung.
enum AppearanceMigration {
    private static let marker = "LatexTerm.migration.ghosttyLook"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: marker) else { return }
        d.set(20.0, forKey: ThemeStore.Keys.fontSize)
        d.set(0.0, forKey: ThemeStore.Keys.lineSpacing)
        d.set(true, forKey: marker)
    }
}
