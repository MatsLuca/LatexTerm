import Foundation
import Combine

/// Verhalten des Claude-Code-Cockpits — alles, was nicht Aussehen (`ThemeStore`) oder Formel
/// (`FormulaSettings`) ist: Benachrichtigungen, Home-Launcher-Befehle. Persistiert in UserDefaults,
/// postet `didChange`; Leser (`SessionNotifier`, `TerminalSplitView`, `ProjekteLoader`) lesen den
/// Wert im Moment des Bedarfs, ein Observer ist nur nötig, wo etwas sofort neu gezeichnet wird.
final class CockpitSettings: ObservableObject {
    static let shared = CockpitSettings()
    static let didChange = Notification.Name("LatexTerm.CockpitSettings.didChange")

    enum Keys {
        static let notificationsEnabled = "LatexTerm.notificationsEnabled"
        static let notifyOnlyUnobserved = "LatexTerm.notifyOnlyUnobserved"
        static let notificationCooldown = "LatexTerm.notificationCooldown"
        static let statusBadgeMode = "LatexTerm.statusBadgeMode"
        /// Historische Keys (vorher nur per `defaults write` erreichbar) — Namen bleiben; UI unter „Erweitert“.
        static let projekteCommand = "LatexTerm.projekteCommand"
        static let limitsCommand = "LatexTerm.limitsCommand"
        static let homeOnlyProjects = "LatexTerm.homeOnlyProjects"
    }

    static let defaultProjekteCommand = "projekte --json"
    static let defaultLimitsCommand = "projekte limits --json"
    static let defaultCooldown: TimeInterval = 5
    static let cooldownRange: ClosedRange<TimeInterval> = 0...30

    /// macOS-Banner „Claude braucht Input / ist fertig“ überhaupt zeigen.
    @Published var notificationsEnabled: Bool = true {
        didSet { guard !loading else { return }; UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled); post() }
    }
    /// Nur melden, wenn die Session gerade niemand ansieht (App im Hintergrund oder andere Kachel
    /// fokussiert). Aus = auch für die fokussierte Kachel.
    @Published var notifyOnlyUnobserved: Bool = true {
        didSet { guard !loading else { return }; UserDefaults.standard.set(notifyOnlyUnobserved, forKey: Keys.notifyOnlyUnobserved); post() }
    }
    /// Mindestabstand zweier Banner derselben Kachel (Glocke + passive Erkennung melden denselben Moment).
    @Published var notificationCooldown: TimeInterval = CockpitSettings.defaultCooldown {
        didSet { guard !loading else { return }; UserDefaults.standard.set(notificationCooldown, forKey: Keys.notificationCooldown); post() }
    }
    /// Status-Pille oben rechts in der Kachel („arbeitet…“, „braucht Input“, Tool-Name).
    enum StatusBadgeMode: String, CaseIterable, Identifiable {
        case off, status, detail
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Aus"
            case .status: return "Nur Status"
            case .detail: return "Status + Werkzeug"
            }
        }
    }
    @Published var statusBadgeMode: StatusBadgeMode = .detail {
        didSet { guard !loading else { return }; UserDefaults.standard.set(statusBadgeMode.rawValue, forKey: Keys.statusBadgeMode); post() }
    }

    /// Befehl, der die Projektliste als JSON liefert (Login-Shell, `zsh -lc`).
    @Published var projekteCommand: String = CockpitSettings.defaultProjekteCommand {
        didSet { guard !loading else { return }; UserDefaults.standard.set(projekteCommand, forKey: Keys.projekteCommand); post() }
    }
    /// Befehl für die Kontingent-Zeile der Home-Kachel (darf fehlschlagen → Zeile bleibt leer).
    @Published var limitsCommand: String = CockpitSettings.defaultLimitsCommand {
        didSet { guard !loading else { return }; UserDefaults.standard.set(limitsCommand, forKey: Keys.limitsCommand); post() }
    }
    /// Reduzierter Ordnerbaum in der Home-Kachel (nur Projekte + die Ordner dorthin).
    @Published var homeOnlyProjects: Bool = false {
        didSet {
            guard !loading else { return }
            UserDefaults.standard.set(homeOnlyProjects, forKey: Keys.homeOnlyProjects)
            NotificationCenter.default.post(name: .latexTermHomeTreeChanged, object: nil)
            post()
        }
    }

    private var loading = false
    private init() { load(initial: true) }

    func load(initial: Bool = false) {
        loading = true
        let d = UserDefaults.standard
        notificationsEnabled = d.object(forKey: Keys.notificationsEnabled) != nil ? d.bool(forKey: Keys.notificationsEnabled) : true
        notifyOnlyUnobserved = d.object(forKey: Keys.notifyOnlyUnobserved) != nil ? d.bool(forKey: Keys.notifyOnlyUnobserved) : true
        let cd = d.object(forKey: Keys.notificationCooldown) != nil ? d.double(forKey: Keys.notificationCooldown) : Self.defaultCooldown
        notificationCooldown = min(max(cd, Self.cooldownRange.lowerBound), Self.cooldownRange.upperBound)
        statusBadgeMode = d.string(forKey: Keys.statusBadgeMode).flatMap(StatusBadgeMode.init(rawValue:)) ?? .detail
        projekteCommand = d.string(forKey: Keys.projekteCommand) ?? Self.defaultProjekteCommand
        limitsCommand = d.string(forKey: Keys.limitsCommand) ?? Self.defaultLimitsCommand
        homeOnlyProjects = d.bool(forKey: Keys.homeOnlyProjects)
        loading = false
        guard !initial else { return }
        NotificationCenter.default.post(name: .latexTermHomeTreeChanged, object: nil)
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
