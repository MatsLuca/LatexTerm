import AppKit

/// Myzel-Kachel: nativer Client für einen Myzel-Server (privater Chat zweier Menschen, die ihre Claude-Agenten
/// dazuholen). Vertrag: PROTOKOLL.md im Myzel-Repo; Pflichten jeder Oberfläche §10 — Auftrag wörtlich vor dem
/// Zulassen, alles vor dem Senden zeigen, gesehene `version` senden, große Anhänge einzeln bestätigen, nichts im
/// Hintergrund, kein HTML aus Nachrichten.
///
/// Verbindung nur, solange die Kachel offen ist (`willClose` trennt). Einstellungen lokal in
/// `~/.config/myzel/kachel.json` (nicht im Repo), das Token im Schlüsselbund. Sicherheitsabschnitt: SECURITY.md.
final class MyzelContent: PaneContent, MyzelTimelineDelegate {
    static let kind = "myzel"
    static let displayName = "Myzel-Chat"
    static let manual = PaneKindManual(
        summary: "Myzel-Chat: privater Chat zweier Menschen, in den beide ihre Agenten per @-Erwähnung holen. Bedient wird "
            + "sie nur vom Menschen — Zulassen und Senden sind immer Klicks, Agenten schreiben ihre Entwürfe über den "
            + "Myzel-MCP-Server, nicht über diese Kachel. Einstellungen: ~/.config/myzel/kachel.json.",
        actions: [PaneKindAction(name: "<text>", summary: "Text ins Eingabefeld legen (wird nie selbst gesendet)")])

    enum Phase: Equatable {
        case setup
        case connecting
        case live
        case offline(String)
    }

    weak var delegate: PaneContentDelegate?
    let root = MyzelRootView()
    let composer = MyzelComposerView()
    private(set) var phase: Phase = .connecting
    private(set) var chat = MyzelChat()
    private(set) var me: MyzelMe?
    private var config: MyzelConfig?
    private var client: MyzelClient?
    private var attempt = 0
    private var retryWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var refreshWork: DispatchWorkItem?
    private var connectedAt = Date()
    private var images: [String: NSImage] = [:]
    private var imageWaiters: [String: [(NSImage?) -> Void]] = [:]
    private var closed = false
    private var pending: [MyzelComposerView.Pending] = []
    private var flashWork: DispatchWorkItem?
    private var scopes = MyzelScopeStore(path: MyzelContent.stateFolder + "/umfang.json")
    private var draftSheet: (job: String, sheet: MyzelDraftSheet)?
    private let waitingButton = LineButton(title: "")
    private let moreButton = LineButton(title: "⋯")
    /// Was schon gemeldet wurde (Banner je Auftrag und Zustand nur einmal).
    private var announced: Set<String> = []

    /// `~/Library/Application Support/LatexTerm/myzel` — Auftragsordner, Umfang je Auftrag.
    static var stateFolder: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LatexTerm/myzel").path
    }

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, kind: Self.kind)
        root.timeline.delegate = self
        root.setup.onSave = { [weak self] token in self?.adopt(token: token) }
        root.setup.onImport = { [weak self] in self?.importTokenFile() }
        root.footer = composer
        root.footerHeight = { [unowned composer] in composer.preferredHeight }
        root.onDropFiles = { [weak self] urls in self?.attach(urls) }
        root.focusTarget = { [weak self] in self?.keyView }
        composer.onHeightChange = { [weak root] in root?.needsLayout = true }
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.onAttach = { [weak self] urls in self?.attach(urls) }
        composer.onAttachData = { [weak self] data, name in self?.upload(data: data, name: name) }
        composer.onRemovePending = { [weak self] id in self?.removePending(id) }
        waitingButton.onClick = { [weak self] in self?.showWaitingMenu() }
        moreButton.toolTip = "Mehr"
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        root.header.trailing = [moreButton]
        start()
    }

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView { root.setup.isHidden ? composer.input : root.setup.field }
    var title: String { "Myzel" + (config.map { " · \($0.host.split(separator: ".").first ?? "")" } ?? "") }
    var directory: String? { config?.agentFolder }
    var layoutPreference: LayoutPreference { LayoutPreference(aspect: nil, minWidth: 320, minHeight: 240, comfortWidth: 520) }

    var chip: StatusChip? {
        let theme = ThemeStore.shared.theme
        switch phase {
        case .setup:
            return StatusChip(short: "einrichten", tone: theme.yellow, tooltip: "Myzel — Token oder Einstellungen fehlen")
        case .connecting:
            return StatusChip(short: "verbinde", tone: theme.yellow, pulsing: true, tooltip: "Myzel — verbinde …")
        case .offline(let reason):
            return StatusChip(short: "offline", tone: theme.red, tooltip: "Myzel — \(reason)")
        case .live:
            let mine = me?.id ?? ""
            let waiting = chat.waiting(for: mine)
            if !waiting.isEmpty {
                return StatusChip(short: "\(waiting.count) wartet", tone: theme.yellow, urgent: true,
                                  tooltip: "Myzel — \(waiting.count) wartet auf dich")
            }
            if chat.active(for: mine).contains(where: { $0.status == .laeuft }) {
                return StatusChip(short: "Agent", tone: theme.green, pulsing: true, tooltip: "Myzel — Agent arbeitet")
            }
            return StatusChip(tone: ThemeStore.shared.accentColor, tooltip: "Myzel — verbunden")
        }
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
        composer.applyTheme(theme)
        refreshHeader()
    }

    /// Steuerkanal `send`: Text landet im Eingabefeld — gesendet wird er nur per ⏎/Klick des Menschen.
    func receive(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        composer.append(text)
        return true
    }

    /// Nach ⌥⌘R kommt die Kachel wieder und verbindet neu (sie ist ja offen).
    func snapshotArgs() -> [String: String]? { [:] }

    func willClose() {
        closed = true
        retryWork?.cancel()
        refreshWork?.cancel()
        flashWork?.cancel()
        draftSheet?.sheet.end()
        draftSheet = nil
        watchdog?.invalidate()
        watchdog = nil
        client?.invalidate()
        client = nil
        imageWaiters = [:]
    }

    // MARK: Verbinden

    private func start() {
        do {
            config = try MyzelConfig.load()
        } catch {
            setPhase(.setup)
            root.setup.show(title: "Myzel einrichten", text: "\(error)", askToken: false, importLabel: nil)
            return
        }
        guard let config, let token = MyzelKeychain.token(host: config.host) else {
            askForToken(reason: nil)
            return
        }
        connect(token: token, server: config.server)
    }

    private func askForToken(reason: String?) {
        setPhase(.setup)
        var importLabel: String?
        if let file = config?.tokenFile, FileManager.default.fileExists(atPath: file) {
            importLabel = "Token aus \(MyzelConfig.tilde(file)) übernehmen"
        }
        let intro = "Die Kachel braucht dein Menschen-Token für \(config?.host ?? "den Server") (mzm_…). Es kommt in den "
            + "macOS-Schlüsselbund und geht nur als Anmeldung an diesen Server."
        root.setup.show(title: "Myzel: Token", text: reason.map { "\($0)\n\n\(intro)" } ?? intro,
                        askToken: true, importLabel: importLabel)
        root.needsLayout = true
    }

    private func importTokenFile() {
        guard let file = config?.tokenFile, let raw = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        adopt(token: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Token prüfen (`/ich`), erst dann speichern und verbinden.
    private func adopt(token: String) {
        guard let config else { return }
        guard MyzelKeychain.looksValid(token) else {
            askForToken(reason: "Das sieht nicht nach einem Menschen-Token aus (mzm_ + 64 Hex-Zeichen).")
            return
        }
        let probe = MyzelClient(server: config.server, token: token)
        Task { @MainActor in
            defer { probe.invalidate() }
            do {
                _ = try await probe.me()
                guard MyzelKeychain.store(token, host: config.host) else {
                    self.askForToken(reason: "Schlüsselbund hat das Token nicht angenommen.")
                    return
                }
                self.root.setup.field.stringValue = ""
                self.connect(token: token, server: config.server)
            } catch {
                self.askForToken(reason: "Server sagt: \(error)")
            }
        }
    }

    private func connect(token: String, server: URL) {
        root.setup.isHidden = true
        client?.invalidate()
        client = MyzelClient(server: server, token: token)
        setPhase(.connecting)
        reconnect()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkStall() }
    }

    /// `/ich` holen (Teilnehmer, eigene id, prüft das Token), dann den Strom ab der letzten gesehenen id.
    private func reconnect() {
        retryWork?.cancel()
        guard let client, !closed else { return }
        Task { @MainActor [weak self] in
            do {
                let me = try await client.me()
                guard let self, !self.closed, client === self.client else { return }
                self.me = me
                self.chat.setParticipants(me.teilnehmer)
                self.connectedAt = Date()
                client.startStream(after: self.chat.lastID, onFrame: { [weak self] frame in
                    self?.receive(frame)
                }, onEnd: { [weak self] failure in
                    self?.streamEnded(failure)
                })
                self.setPhase(.live)
                self.attempt = 0
                self.scheduleRefresh()
            } catch let failure as MyzelClient.Failure {
                self?.streamEnded(failure)
            } catch {
                self?.streamEnded(MyzelClient.Failure(status: 0, message: "\(error)"))
            }
        }
    }

    private func streamEnded(_ failure: MyzelClient.Failure?) {
        guard !closed else { return }
        if let failure, failure.isAuth {
            client?.invalidate()
            client = nil
            watchdog?.invalidate()
            askForToken(reason: "Der Server nimmt das gespeicherte Token nicht mehr an (\(failure.message)).")
            return
        }
        if failure?.status == 404, chat.lastID != nil {
            // Unbekanntes `nach` (Server neu aufgesetzt): Verlauf von vorn.
            chat = MyzelChat()
            root.timeline.reset()
        }
        attempt += 1
        setPhase(.offline(failure?.description ?? "Verbindung beendet"))
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MyzelBackoff.delay(attempt: attempt), execute: work)
    }

    /// Strom still (kein `: puls` seit > 70 s): neu verbinden.
    private func checkStall() {
        guard phase == .live, let client, client.streamSilence > 70 else { return }
        client.stopStream()
        streamEnded(MyzelClient.Failure(status: 0, message: "Strom hängt"))
    }

    private func receive(_ frame: MyzelSSEParser.Frame) {
        guard let event = try? JSONDecoder().decode(MyzelEvent.self, from: Data(frame.data.utf8)) else { return }
        guard chat.apply(event) else { return }
        let live = (event.date ?? .distantPast) > connectedAt.addingTimeInterval(-5)
        if live, event.typ == "nachricht", event.von != me?.id {
            delegate?.contentHasNews()
        }
        if live, let jobID = event.typ == "auftrag" ? event.id : event.auftrag { announce(jobID) }
        if event.typ == "status", let jobID = event.auftrag,
           let status = event.status.flatMap(MyzelJobStatus.init(rawValue:)), status.isEnd {
            MyzelLaunch.revoke(jobID: jobID, stateFolder: Self.stateFolder)   // Token ist ohnehin tot
            if let open = draftSheet, open.job == jobID {
                open.sheet.end()   // anderswo gesendet/verworfen/abgebrochen
                draftSheet = nil
            }
        }
        scheduleRefresh()
    }

    /// Mehrere Ereignisse (Verlauf beim Verbinden) in einem Rutsch zeichnen.
    private func scheduleRefresh() {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWork = nil
            self.root.timeline.update(chat: self.chat, me: self.me?.id ?? "")
            self.composer.participantIDs = self.chat.participants.map(\.id)
            self.composer.me = self.me?.id
            self.refreshWaiting()
            self.refreshHeader()
            self.delegate?.contentStyleChanged()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func setPhase(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        refreshHeader()
        delegate?.contentStyleChanged()
    }

    private func refreshHeader() {
        guard flashWork == nil else { return }
        let theme = ThemeStore.shared.theme
        let host = config?.host ?? "Myzel"
        switch phase {
        case .setup: root.header.show("\(host) · einrichten", tone: theme.yellow)
        case .connecting: root.header.show("\(host) · verbinde …", tone: theme.yellow, pulsing: true)
        case .offline(let reason): root.header.show("\(host) · \(reason) — neuer Versuch gleich", tone: theme.red)
        case .live:
            let others = chat.participants.filter { !$0.isAgent && $0.id != me?.id }.map { chat.displayName($0.id) }
            let who = others.isEmpty ? "" : " · mit " + others.joined(separator: ", ")
            root.header.show("\(chat.displayName(me?.id ?? "")) @ \(host)\(who)", tone: theme.green)
        }
    }

    // MARK: Aufträge

    /// Banner, wenn ein fremder Auftrag auf mich wartet oder ein Entwurf fertig ist — ohne Chattext (Sperrbildschirm).
    private func announce(_ jobID: String) {
        guard let mine = me?.id, let job = chat.jobs[jobID], job.besitzer == mine else { return }
        guard announced.insert("\(jobID):\(job.status.rawValue)").inserted else { return }
        switch job.status {
        case .wartet:
            delegate?.contentRequestsAttention(AttentionNote(
                title: "Myzel: Auftrag von \(chat.displayName(job.ausloeser))",
                subtitle: "an \(chat.displayName(job.agent))", body: "Wartet auf dein Zulassen."))
        case .bereit:
            delegate?.contentRequestsAttention(AttentionNote(
                title: "Myzel: Entwurf von \(chat.displayName(job.agent))", subtitle: nil, body: "Liegt zum Prüfen bereit."))
        default: break
        }
    }

    /// Knopf „N wartet“ rechts in der Kopfzeile.
    private func refreshWaiting() {
        let waiting = chat.waiting(for: me?.id ?? "")
        if waiting.isEmpty {
            if root.header.trailing.count != 1 { root.header.trailing = [moreButton] }
        } else {
            waitingButton.title = "\(waiting.count) wartet auf dich"
            waitingButton.accent = Tone.waiting.color
            if root.header.trailing.count != 2 { root.header.trailing = [moreButton, waitingButton] }
            root.header.needsLayout = true
        }
        try? scopes.prune(keeping: Set(chat.jobs.values.filter { !$0.status.isEnd }.map(\.id)))
    }

    private func showWaitingMenu() {
        let waiting = chat.waiting(for: me?.id ?? "")
        if waiting.count == 1, let job = waiting.first { return timelineJob(job.id, action: job.status == .wartet ? .approve : .review) }
        let menu = NSMenu()
        for job in waiting {
            let title = job.status == .wartet
                ? "Auftrag von \(chat.displayName(job.ausloeser)) an \(chat.displayName(job.agent)) zulassen …"
                : "Entwurf von \(chat.displayName(job.agent)) prüfen"
            let item = NSMenuItem(title: title, action: #selector(MyzelMenuTarget.fire(_:)), keyEquivalent: "")
            let target = MyzelMenuTarget { [weak self] in
                self?.timelineJob(job.id, action: job.status == .wartet ? .approve : .review)
            }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: waitingButton.bounds.minX, y: waitingButton.bounds.maxY + 4), in: waitingButton)
    }

    func timelineJob(_ jobID: String, action: MyzelJobAction) {
        guard let job = chat.jobs[jobID], let client, let window = root.window else { return }
        root.timeline.scrollTo(message: job.nachricht)
        switch action {
        case .approve:
            let text = chat.message(job.nachricht)?.text ?? ""
            MyzelApproveSheet.run(on: window, trigger: chat.displayName(job.ausloeser), agent: chat.displayName(job.agent),
                                  text: text, projects: config?.projects ?? []) { [weak self] result in
                switch result {
                case .approve(let scope):
                    do { try self?.scopes.set(scope, for: jobID) } catch {
                        return self?.flash("Umfang nicht gespeichert: \(error)") ?? ()
                    }
                    self?.click(jobID, "zulassen")
                case .reject(let reason):
                    self?.click(jobID, "ablehnen", json: reason.map { ["grund": $0] } ?? [:])
                case .cancel:
                    break
                }
            }
        case .reject:
            click(jobID, "ablehnen")
        case .cancel:
            let alert = NSAlert()
            alert.messageText = "Auftrag an \(chat.displayName(job.agent)) abbrechen?"
            alert.informativeText = "Ein laufender Agent verliert seinen Zugang, ein Entwurf verfällt."
            alert.addButton(withTitle: "Abbrechen")
            alert.addButton(withTitle: "Zurück")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.click(jobID, "abbrechen") }
            }
        case .start, .restart:
            startAgent(job, client: client, window: window)
        case .review:
            openDraft(job, client: client, window: window)
        }
    }

    /// Einfacher Klick auf dem Server (`zulassen`, `ablehnen`, `abbrechen`, `verwerfen`, `fehlgeschlagen`).
    private func click(_ jobID: String, _ verb: String, json: [String: Any] = [:], then: (() -> Void)? = nil) {
        guard let client else { return }
        Task { @MainActor [weak self] in
            do {
                try await client.post("/auftrag/\(jobID)/\(verb)", json: json)
                then?()
            } catch {
                self?.flash("\(verb): \(error)")
            }
        }
    }

    /// „Agent dazuholen“ (PROTOKOLL §10.4: nur sichtbar, nur auf Klick): Auftrags-Token holen, Auftragsordner vorbereiten,
    /// Terminal-Kachel direkt neben dieser (zweiter gleichzeitiger Agent als Reiter dahinter) und dort `claude` starten.
    private func startAgent(_ job: MyzelJob, client: MyzelClient, window: NSWindow) {
        guard let config else { return }
        // Fremder Auftrag: Umfang aus dem Zulassen (fehlt er, z. B. auf einem anderen Rechner zugelassen: nur Chat).
        let scope: MyzelScope? = job.isForeign ? (scopes[job.id] ?? .chat) : nil
        Task { @MainActor [weak self] in
            do {
                let data = try await client.post("/auftrag/\(job.id)/starten")
                let reply = try JSONDecoder().decode(MyzelStartReply.self, from: data)
                guard let self, reply.tokenLooksValid else { return }
                var input = MyzelLaunch.Inputs(
                    jobID: job.id, token: reply.token, server: client.server, stateFolder: Self.stateFolder,
                    agentFolder: config.agentFolder, own: scope == nil, trigger: self.chat.displayName(job.ausloeser),
                    after: MyzelLaunch.lastSeen(agentFolder: config.agentFolder))
                if let scope {
                    // §8: Sandbox-Profil (schreiben nur im Auftragsordner, Netz nur Myzel, Sperrliste, Lese-Umfang).
                    input.extraArgs = try MyzelSandbox.prepare(MyzelSandbox.Inputs(
                        jobFolder: Self.stateFolder + "/auftraege/" + job.id, scope: scope, blocklist: config.blocklist,
                        accessFolder: Self.stateFolder + "/zugang", serverHost: config.host,
                        readTools: config.readTools), jobID: job.id)
                }
                let launch = try MyzelLaunch.prepare(input)
                Self.rememberSession(launch.sessionID, job: job.id)
                self.openAgentPane(for: job, launch: launch)
                if let scope { self.flash("Sandbox: \(scope.label)", error: false) }
            } catch {
                self?.flash("Starten: \(error)")
            }
        }
    }

    /// Session-id je Auftrag, außerhalb des Auftragsordners (den ein fremder Agent beschreiben darf — er soll das
    /// Protokoll nicht auf ein anderes Transkript umbiegen können).
    private static func rememberSession(_ id: String, job: String) {
        guard MyzelLaunch.isSafeID(job) else { return }
        let folder = stateFolder + "/sitzungen"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(id.utf8).write(to: URL(fileURLWithPath: folder + "/" + job))
    }

    private static func session(job: String) -> String? {
        guard MyzelLaunch.isSafeID(job),
              let data = FileManager.default.contents(atPath: stateFolder + "/sitzungen/" + job) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Menü ⋯

    private func showMoreMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = MyzelMenuTarget(action)
            let item = NSMenuItem(title: title, action: #selector(MyzelMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        add("Zusammenfassung des Agenten nachführen …") { [weak self] in self?.refreshSummary() }
        add("Agenten-Ordner im Finder zeigen") { [weak self] in
            guard let folder = self?.config?.agentFolder else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
        }
        menu.addItem(.separator())
        add("Token aus dem Schlüsselbund entfernen …") { [weak self] in self?.forgetToken() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 4), in: moreButton)
    }

    /// Neue Nachrichten seit `stand.json` als Datei in den Agenten-Ordner, daneben eine eigene Session, die
    /// `zusammenfassung.md` nachführt — für Gespräche, die ohne eigenen Ping weiterliefen. Kein Server-Zugang nötig.
    private func refreshSummary() {
        guard let config, let me = delegate?.contentPaneID.uuidString else { return }
        let after = MyzelLaunch.lastSeen(agentFolder: config.agentFolder)
        var messages = chat.messages
        if let after, let index = messages.firstIndex(where: { $0.id == after }) { messages = Array(messages[(index + 1)...]) }
        guard let last = messages.last else { return flash("Zusammenfassung ist aktuell.", error: false) }
        let text = messages.suffix(200).map { m in
            "## \(chat.displayName(m.von)) · \(m.ts.prefix(16)) · \(m.id)\n\n\(m.text ?? "")\n"
        }.joined(separator: "\n")
        let file = config.agentFolder + "/neu.md"
        do { try Data(("# Neue Nachrichten seit dem letzten Stand\n\n" + text).utf8).write(to: URL(fileURLWithPath: file)) } catch {
            return flash("neu.md: \(error)")
        }
        let prompt = "Führe zusammenfassung.md anhand von neu.md nach (höchstens ~40 Zeilen, Älteres verdichten, Regeln in "
            + "regeln.md beachten), setze stand.json auf {\"nach\": \"\(last.id)\"} und lösche danach neu.md. Sonst nichts."
        var request = ControlRequest(cmd: "new-pane")
        request.paneID = me
        request.placement = "beside"
        request.focus = false
        request.cwd = config.agentFolder
        request.exec = " claude " + MyzelLaunch.shellQuote(prompt)
        let response = ControlServer.shared.router.route(request)
        if !response.ok { flash("Kachel: \(response.error ?? "ging nicht")") }
    }

    private func forgetToken() {
        guard let config, let window = root.window else { return }
        let alert = NSAlert()
        alert.messageText = "Token für \(config.host) entfernen?"
        alert.informativeText = "Die Kachel trennt die Verbindung und fragt beim nächsten Mal wieder nach dem Token."
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MyzelKeychain.remove(host: config.host)
            self.client?.invalidate()
            self.client = nil
            self.watchdog?.invalidate()
            self.askForToken(reason: nil)
        }
    }

    /// Kacheln, die diese Myzel-Kachel für Aufträge geöffnet hat (Auftrag → Kachel-UUID).
    private var agentPanes: [String: String] = [:]

    private func openAgentPane(for job: MyzelJob, launch: MyzelLaunch) {
        guard let me = delegate?.contentPaneID.uuidString else { return }
        let router = ControlServer.shared.router
        let alive = Set((router.route(ControlRequest(cmd: "list-panes")).panes ?? []).map { $0.id.uppercased() })
        agentPanes = agentPanes.filter { alive.contains($0.value.uppercased()) }
        var request = ControlRequest(cmd: "new-pane")
        request.cwd = launch.jobFolder
        request.exec = launch.command
        request.focus = false
        if let first = agentPanes.values.sorted().first {
            request.paneID = first
            request.placement = "background"   // zweiter Agent: Reiter auf der ersten Agenten-Kachel
        } else {
            request.paneID = me
            request.placement = "beside"
        }
        let response = router.route(request)
        guard response.ok, let pane = response.pane else {
            return flash("Agent-Kachel: \(response.error ?? "ging nicht")")
        }
        agentPanes[job.id] = pane.id
        flash("Agent \(chat.displayName(job.agent)) läuft daneben.", error: false)
    }

    private func openDraft(_ job: MyzelJob, client: MyzelClient, window: NSWindow) {
        guard draftSheet == nil else { return }
        Task { @MainActor [weak self] in
            do {
                let draft = try await client.get("/auftrag/\(job.id)/entwurf", as: MyzelDraft.self)
                guard let self, self.draftSheet == nil else { return }
                let sheet = MyzelDraftSheet(draft: draft, agent: self.chat.displayName(job.agent),
                                            trigger: self.chat.displayName(job.ausloeser),
                                            triggerText: self.chat.message(job.nachricht)?.text ?? "")
                sheet.loadImage = { [weak self] attachment, done in
                    guard let client = self?.client else { return done(nil) }
                    Task { @MainActor in
                        let data = try? await client.data("/auftrag/\(job.id)/entwurf/anhang/\(attachment.id)")
                        done(data.flatMap(NSImage.init(data:)))
                    }
                }
                sheet.openAttachment = { [weak self, weak sheet] attachment in
                    self?.open(attachment, path: "/auftrag/\(job.id)/entwurf/anhang/\(attachment.id)") {
                        sheet?.markOpened(attachment.id)
                    }
                }
                sheet.setAccessLog(Self.session(job: job.id)
                    .flatMap { MyzelTranscript.file(sessionID: $0) }
                    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                    .map { MyzelTranscript.lines(MyzelTranscript.accesses(jsonl: $0)) })
                self.draftSheet = (job.id, sheet)
                sheet.begin(on: window) { [weak self] action in self?.draftAction(action, job: job) }
            } catch {
                self?.flash("Entwurf: \(error)")
            }
        }
    }

    private func draftAction(_ action: MyzelDraftSheet.Action, job: MyzelJob) {
        guard let open = draftSheet, open.job == job.id, let client else { return }
        let sheet = open.sheet
        switch action {
        case .close:
            sheet.end()
            draftSheet = nil
        case .discard:
            click(job.id, "verwerfen") { [weak self] in sheet.end(); self?.draftSheet = nil }
        case .send(let text, let confirmed):
            let body = sheet.draft.sendBody(editedText: text, confirmed: confirmed)
            sheet.showStatus("Sende …", error: false)
            Task { @MainActor [weak self] in
                do {
                    try await client.post("/auftrag/\(job.id)/senden", json: body)
                    sheet.end()
                    self?.draftSheet = nil
                } catch let failure as MyzelClient.Failure where failure.status == 409 {
                    // Entwurf hat sich geändert oder Bestätigung fehlt: neu ansehen (§10.3).
                    if let fresh = try? await client.get("/auftrag/\(job.id)/entwurf", as: MyzelDraft.self) {
                        sheet.reload(fresh, note: "Neu geladen: \(failure.message) — bitte noch einmal ansehen.")
                    } else {
                        sheet.showStatus(failure.message, error: true)
                    }
                } catch {
                    sheet.showStatus("Nicht gesendet: \(error)", error: true)
                }
            }
        }
    }

    // MARK: Schreiben

    /// Kurze Meldung in der Kopfzeile (Fehler rot), danach wieder der Zustand.
    private func flash(_ text: String, error: Bool = true) {
        flashWork?.cancel()
        flashWork = nil
        let theme = ThemeStore.shared.theme
        root.header.show(text, tone: error ? theme.red : theme.green)
        let work = DispatchWorkItem { [weak self] in self?.flashWork = nil; self?.refreshHeader() }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 5 : 2), execute: work)
    }

    private func send(_ text: String) {
        guard let client, phase == .live else { return flash("Nicht verbunden — Nachricht bleibt im Feld.") }
        let body = MyzelCompose.messageBody(text: text, replyTo: composer.replyTo?.id,
                                            attachments: pending.compactMap { $0.uploaded?.id })
        composer.busy = true
        Task { @MainActor [weak self] in
            do {
                try await client.post("/nachricht", json: body)
                guard let self else { return }
                self.composer.busy = false
                self.pending = []
                self.composer.setPending([])
                self.composer.clear()
                self.root.timeline.scrollToBottom()
            } catch {
                self?.composer.busy = false
                self?.flash("Nicht gesendet: \(error)")
            }
        }
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if let problem = MyzelCompose.problem(name: name, bytes: size, alreadyAttached: pending.count) {
                flash(problem)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { flash("\(name): nicht lesbar"); continue }
            upload(data: data, name: name)
        }
    }

    private func upload(data: Data, name: String) {
        guard let client else { return flash("Nicht verbunden.") }
        if let problem = MyzelCompose.problem(name: name, bytes: Int64(data.count), alreadyAttached: pending.count) {
            return flash(problem)
        }
        let item = MyzelComposerView.Pending(localID: UUID(), name: name, uploaded: nil)
        pending.append(item)
        composer.setPending(pending)
        let mime = MyzelCompose.mime(forFileName: name) ?? "application/octet-stream"
        Task { @MainActor [weak self] in
            do {
                let meta = try await client.upload(name: name, mime: mime, data: data)
                guard let self, let index = self.pending.firstIndex(where: { $0.localID == item.localID }) else { return }
                self.pending[index].uploaded = meta
                self.composer.setPending(self.pending)
            } catch {
                guard let self else { return }
                self.pending.removeAll { $0.localID == item.localID }
                self.composer.setPending(self.pending)
                self.flash("\(name): \(error)")
            }
        }
    }

    /// Entfernt nur lokal; der Server löscht nie gesendete Uploads nach 24 h selbst.
    private func removePending(_ id: UUID) {
        pending.removeAll { $0.localID == id }
        composer.setPending(pending)
    }

    // MARK: MyzelTimelineDelegate

    func timelineReply(to id: String) {
        guard let message = chat.message(id) else { return }
        let text = MyzelMarkdown.plain(message.text ?? "")
        composer.setReply((id, "\(chat.displayName(message.von)): \(text.prefix(80))"))
        root.window?.makeFirstResponder(composer.input)
    }

    func timelineImage(for attachment: MyzelAttachment, done: @escaping (NSImage?) -> Void) {
        if let image = images[attachment.id] { return done(image) }
        imageWaiters[attachment.id, default: []].append(done)
        guard imageWaiters[attachment.id]?.count == 1, let client else { return }
        Task { @MainActor in
            let data = try? await client.data("/anhang/\(attachment.id)")
            let image = data.flatMap(NSImage.init(data:))
            if let image { self.images[attachment.id] = image }
            let waiters = self.imageWaiters.removeValue(forKey: attachment.id) ?? []
            waiters.forEach { $0(image) }
        }
    }

    /// Anhang in den Cache laden und mit der Standard-App öffnen (Server liefert nur geprüfte Typen, §7).
    func timelineOpen(_ attachment: MyzelAttachment) {
        open(attachment, path: "/anhang/\(attachment.id)")
    }

    func open(_ attachment: MyzelAttachment, path: String, then: (() -> Void)? = nil) {
        guard let client else { return }
        Task { @MainActor in
            do {
                let data = try await client.data(path)
                let url = try Self.cacheFile(for: attachment)
                try data.write(to: url, options: .atomic)
                NSWorkspace.shared.open(url)
                then?()
            } catch {
                self.root.header.show("Anhang \(attachment.name): \(error)", tone: ThemeStore.shared.theme.red)
            }
        }
    }

    func timelineOpenLink(_ url: URL) {
        guard MyzelMarkdown.isSafe(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// `~/Library/Caches/LatexTerm/myzel/<id>/<name>` — Name ohne Pfadteile.
    static func cacheFile(for attachment: MyzelAttachment) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("LatexTerm/myzel/\(attachment.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = attachment.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        return folder.appendingPathComponent(name.isEmpty ? attachment.id : name)
    }
}

/// Ziel für Menüpunkte mit Closure (NSMenuItem hält sein Ziel nur schwach — `representedObject` hält es fest).
final class MyzelMenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
}
