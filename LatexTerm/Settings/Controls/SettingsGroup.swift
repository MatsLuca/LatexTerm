import SwiftUI

/// Sektion mit Titel und optionalem Erklärtext darunter. Jede Gruppe, deren Wirkung sich nicht
/// aus den Beschriftungen ergibt, bekommt einen `help`-Satz — einmal, unter der Gruppe, nicht
/// hinter jedem Schalter.
struct SettingsGroup<Content: View>: View {
    let title: String
    let help: String?
    let content: () -> Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.help = help; self.content = content
    }

    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let help { HelpText(help) }
        }
    }
}

/// Sekundärer Erklärtext (auch einzeln unter einem Element nutzbar).
struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
