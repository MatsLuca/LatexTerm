import AppKit
import UserNotifications

/// macOS-Benachrichtigungen für den passiven Session-Status (#30, v1 von #27):
/// „Claude braucht Input" bei bestätigtem working→awaitingInput auf einer
/// unbeobachteten Pane. Klick auf die Notification fokussiert + zoomt die Pane
/// (Routing über die Pane-UUID als Notification-Identifier — dieselbe Pane
/// ersetzt so auch ihre eigene ältere, noch ungelesene Benachrichtigung).
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SessionNotifier()

    /// Klick auf eine Notification → Ziel-Pane aktivieren. Setzt die Split-View.
    var onActivatePane: ((UUID) -> Void)?

    private var authorizationRequested = false
    /// Letzter Post je Pane: Bell (sofort) und passive Erkennung (~1,5 s später)
    /// melden denselben Moment — der Cooldown verhindert das Doppel-Banner.
    private var lastPost: [UUID: Date] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(paneID: UUID, title: String, body: String?) {
        let cockpit = CockpitSettings.shared
        guard cockpit.notificationsEnabled else { return }
        if let last = lastPost[paneID], Date().timeIntervalSince(last) < cockpit.notificationCooldown {
#if DEBUG
            TerminalPane.statusLog("POST skipped (cooldown)")
#endif
            return
        }
        lastPost[paneID] = Date()
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            if let body { content.body = body }
            content.sound = .default
            center.add(UNNotificationRequest(identifier: paneID.uuidString,
                                             content: content, trigger: nil))
        }
        // Autorisierung lazy beim ersten Bedarf — kein Prompt beim App-Start
        // für ein Feature, das vielleicht nie feuert.
        if authorizationRequested { post(); return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
#if DEBUG
            TerminalPane.statusLog("AUTH granted=\(granted) error=\(error.map(String.init(describing:)) ?? "-")")
#endif
            if granted { post() }
        }
    }

    /// Banner auch zeigen, wenn die App selbst aktiv ist — der Fall „andere
    /// Kachel fokussiert, App vorne" ist genau der Multi-Session-Alltag.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = UUID(uuidString: response.notification.request.identifier)
        DispatchQueue.main.async { [weak self] in
            if let id { self?.onActivatePane?(id) }
        }
        completionHandler()
    }
}
