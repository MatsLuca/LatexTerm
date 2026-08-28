import SwiftUI

/// Claude Codes Statuszeile (unter der Eingabe-Box) segmentweise ein-/ausblenden — wirkt live in
/// allen Sessions, weil das Statusline-Skript die Datei bei jedem Rendern liest.
struct StatuslinePage: View {
    @ObservedObject private var sl = StatuslineSettings.shared

    var body: some View {
        Form {
            SettingsGroup("Zeile 1", help: nil) { toggles(line: 1) }
            SettingsGroup("Zeile 2", help: nil) { toggles(line: 2) }
            SettingsGroup("Layout",
                          help: "Schreibt ~/.claude/statusline.conf; das mats-tools-Skript statusline-command.sh liest sie alle 3 s — Änderungen erscheinen in jeder laufenden Claude-Code-Session ohne Neustart. Fehlt die Datei, ist alles an.") {
                Picker("Zeilen", selection: $sl.lines) {
                    ForEach(StatuslineSettings.Lines.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    Button("Alles anzeigen") { sl.reset() }.disabled(sl.isDefault)
                }
            }
        }
    }

    private func toggles(line: Int) -> some View {
        let segs = StatuslineSettings.Segment.allCases.filter { $0.line == line }
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                   GridItem(.flexible(), alignment: .leading)], spacing: 6) {
            ForEach(segs) { s in
                Toggle(s.label, isOn: Binding(get: { sl.isOn(s) }, set: { sl.set(s, on: $0) }))
                    .disabled(s.parent.map { !sl.isOn($0) } ?? false)
            }
        }
    }
}
