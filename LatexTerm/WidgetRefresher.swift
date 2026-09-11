import AppKit
import WidgetKit
import os

private let wlog = Logger(subsystem: "com.mats.LatexTerm", category: "widgets")

/// Schreiber für die Desktop-Widgets (`LatexTermWidgets`): ruft den konfigurierten Befehl
/// (`projekte widget`, Werkstatt-Datenschicht) beim Start, alle 5 min und nach dem Aufwachen, und
/// lädt danach die Widget-Timelines neu. Die App kennt weder Pfad noch Inhalt des Schnappschusses —
/// der Befehl schreibt ihn in den App-Group-Container, die Extension liest ihn dort.
final class WidgetRefresher {
    static let shared = WidgetRefresher()
    static let interval: TimeInterval = 300

    private var timer: Timer?
    private var running = false

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 30
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let command = CockpitSettings.shared.widgetCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            var ok = false
            do { try proc.run(); proc.waitUntilExit(); ok = proc.terminationStatus == 0 } catch { ok = false }
            DispatchQueue.main.async {
                WidgetRefresher.shared.running = false
                if ok { WidgetCenter.shared.reloadAllTimelines() }
                else { wlog.error("Widget-Befehl fehlgeschlagen: \(command, privacy: .public)") }
            }
        }
    }
}
