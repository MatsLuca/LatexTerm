import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Vorschau-Kachel (Kacheln Runde 2, Platz 1 — Plan claude-werkstatt `plans/kacheln-runde-2_2026-09-22.md`):
/// ein PDF, Bild oder Dokument neben der Session, von selbst neu geladen, sobald die Datei sich ändert
/// (`FileWatcher`) — Seite, Zoom und Ausschnitt bleiben stehen; die Datei darf beim Öffnen noch fehlen.
///
/// PDF (PDFKit): Seitenbreite als Grundzoom, ⌘F Suche, ⌘L gehe zu Seite, ⌥⌘1/2/3 Seitenleiste
/// (aus/Miniaturen/Inhalt), `dark`. Nach dem Neuladen springt sie zur ersten geänderten Seite (⌘[ zurück);
/// mit SyncTeX führt `sync datei.tex:zeile` vom Quelltext zur Stelle im PDF.
/// Bild: nie über 1:1 vergrößert, Doppelklick 1:1/zurück, Ziehen, Pinch. Dokumente (Word, PowerPoint,
/// Excel, Text …) über QuickLook. Ordner: alle PDFs/Bilder darin, neueste zuerst, neue Dateien rücken vor.
///
/// Rückkanal (22.–23.09., wie ➤ im Scratchpad): Text markieren oder mit ⌥ einen Rahmen ziehen, Notiz, „Merken“
/// sammelt, ➤ / ⇧⌘⏎ fügt alle Stellen — Seite, SyncTeX-Zeile, Text, Notiz, Ausschnitt als PNG — in die
/// Agenten-Kachel ein. Agenten sehen die Kachel per `call look` (MCP `preview_look`).
final class PreviewContent: NSObject, PaneContent {
    static let kind = "preview"
    static let displayName = "PDF, Bild oder Dokument in neuer Kachel …"
    static let manual = PaneKindManual(
        summary: "Zeigt ein PDF, Bild (PNG, JPG, SVG …), Office-/Textdokument oder einen ganzen Ordner mit Plots neben der Session "
            + "und lädt von selbst neu, sobald sich die Datei ändert — Seite und Zoom bleiben, nach einer Änderung springt das PDF "
            + "zur ersten geänderten Seite. Für kompilierte LaTeX-PDFs, Plots, Renders, Screenshots. Die Datei darf noch fehlen "
            + "(wartet auf den ersten Build). Der Nutzer kann Stellen markieren und dir mit Seite, SyncTeX-Zeile und Ausschnitt "
            + "schicken; mit preview_look siehst du selbst, was die Kachel zeigt. HTML → open_web.",
        args: [PaneKindArg(name: "url", summary: "absoluter Pfad der Datei oder eines Ordners (auch ~/…)", required: true),
               PaneKindArg(name: "page", summary: "PDF: Startseite ab 1", required: false),
               PaneKindArg(name: "zoom", summary: "width (Seitenbreite, Default PDF), fit (ganz sichtbar, Default Bild) oder Prozent wie 150",
                           required: false)],
        actions: [PaneKindAction(name: "sync <datei.tex>:<zeile>", summary: "PDF: per SyncTeX zur Stelle dieser Quelltext-Zeile springen und sie aufleuchten lassen (Pfad relativ zum PDF oder absolut; nach dem Kompilieren zeigen, wo eine Änderung gelandet ist)"),
                  PaneKindAction(name: "page <n>", summary: "PDF: zu Seite n springen"),
                  PaneKindAction(name: "next", summary: "PDF: nächste Seite"),
                  PaneKindAction(name: "prev", summary: "PDF: vorige Seite"),
                  PaneKindAction(name: "find <text>", summary: "PDF: Text suchen und markieren; nochmal = nächster Treffer"),
                  PaneKindAction(name: "zoom <width|fit|prozent>", summary: "Zoom setzen"),
                  PaneKindAction(name: "sidebar <off|thumbs|toc>", summary: "PDF: Seitenleiste mit Miniaturen oder Inhaltsverzeichnis"),
                  PaneKindAction(name: "dark", summary: "PDF: dunkle Darstellung an/aus"),
                  PaneKindAction(name: "file <next|prev|newest>", summary: "Ordner: andere Datei zeigen"),
                  PaneKindAction(name: "load <pfad>", summary: "andere Datei oder Ordner in derselben Kachel zeigen"),
                  PaneKindAction(name: "reload", summary: "sofort neu laden (sonst automatisch)")])

    enum Zoom: Equatable {
        case width, fit, percent(Double)

        init?(_ raw: String) {
            let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch text {
            case "width", "breite": self = .width
            case "fit", "ganz", "page", "seite": self = .fit
            default:
                let number = text.hasSuffix("%") ? String(text.dropLast()).trimmingCharacters(in: .whitespaces) : text
                guard let value = Double(number.replacingOccurrences(of: ",", with: ".")), (5...3200).contains(value) else { return nil }
                self = .percent(value)
            }
        }

        var arg: String {
            switch self {
            case .width: return "width"
            case .fit: return "fit"
            case .percent(let p): return String(Int(p.rounded()))
            }
        }
    }

    nonisolated enum FileType { case pdf, image, document }

    weak var delegate: PaneContentDelegate?
    let root = PreviewRootView()
    private(set) var file: URL
    private(set) var type: FileType
    private var watcher: FileWatcher?
    private var zoom: Zoom
    private var startPage: Int?
    private var dark = false
    /// Nach dem Neuladen zur ersten geänderten Seite springen.
    private var follow = true
    /// Laden nach Ruhe gescheitert (PDF halb geschrieben …): so oft noch versuchen.
    private var retries = 0
    private var problem: String?
    private var pdfObservers: [NSObjectProtocol] = []
    /// Eigene Scale-Änderungen (fit, Reload) sollen den Zoom-Modus nicht auf Prozent kippen.
    private var settingScale = false
    private var findResults: [PDFSelection] = []
    private var findIndex = 0
    private var findText = ""
    /// Wohin ⌘[ zurückführt (nach Sprung zur Änderung, `sync`, Gehe-zu).
    private var back: PDFDestination?
    private var sidebar: PreviewSidebar.Mode?

    // Ordner-Modus
    private(set) var folder: URL?
    private var folderItems: [URL] = []
    private var folderWatcher: FolderWatcher?

    // Markierungen
    private(set) var marks: [PreviewMark] = []
    private var pending: PreviewMark?
    private var markAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var flashAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var sending = false

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["url", "page", "zoom", "dark", "sidebar", "item", "follow"], kind: Self.kind)
        guard let raw = args["url"] else { throw PaneArgsError("preview braucht --arg url=/pfad/datei.pdf") }
        let target = try Self.resolve(raw)
        var zoomArg: Zoom?
        if let raw = args["zoom"] {
            guard let zoom = Zoom(raw) else { throw PaneArgsError("preview: zoom = width, fit oder Prozent (5–3200), bekam „\(raw)“") }
            zoomArg = zoom
        }
        switch target {
        case .file(let url, let type):
            (file, self.type) = (url, type)
        case .folder(let url):
            let items = FolderWatcher.items(in: url)
            let chosen = args["item"].flatMap { name in items.first { $0.lastPathComponent == name } } ?? items.first
            folder = url
            folderItems = items
            file = chosen ?? url.appendingPathComponent("…")
            type = chosen.flatMap { Self.fileType($0) } ?? .image
        }
        zoom = zoomArg ?? (type == .pdf ? .width : .fit)
        if let raw = args["page"] {
            guard let page = Int(raw), page >= 1 else { throw PaneArgsError("preview: page muss eine Zahl ab 1 sein, bekam „\(raw)“") }
            startPage = page
        }
        dark = args["dark"] == "1"
        follow = args["follow"] != "0"
        sidebar = args["sidebar"].flatMap(PreviewSidebar.Mode.init(rawValue:))
        super.init()
        wire()
        if let folder { watchFolder(folder) }
        open(file)
    }

    /// Menü „Kachel → PDF, Bild oder Dokument …“: Datei oder Ordner wählen. Abbrechen = nil.
    static func menuArgs() -> [String: String]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "PDF, Bild, Dokument — oder einen Ordner mit Plots"
        return panel.runModal() == .OK ? panel.url.map { ["url": $0.path] } : nil
    }

    enum Target { case file(URL, FileType), folder(URL) }

    /// Absoluter Pfad, `~/…` oder `file://…`. Die Datei darf fehlen (erster Build steht aus), ihr Ordner nicht.
    static func resolve(_ raw: String) throws -> Target {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: path), let scheme = url.scheme?.lowercased() {
            guard scheme == "file" else { throw PaneArgsError("preview zeigt nur lokale Dateien, keine \(scheme)-Adressen") }
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw PaneArgsError("preview braucht einen absoluten Pfad (z. B. \"$PWD/\(raw)\"), bekam „\(raw)“")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            guard !["app", "bundle", "framework"].contains(url.pathExtension.lowercased()) else {
                throw PaneArgsError("preview zeigt keine Programme: \(path)")
            }
            return .folder(url)
        }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw PaneArgsError("Ordner nicht gefunden: \(url.deletingLastPathComponent().path)")
        }
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            throw PaneArgsError("HTML zeigt die Kachelart web (open_web), nicht preview")
        }
        return .file(url, fileType(url) ?? .document)
    }

    static func fileType(_ url: URL) -> FileType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .document
    }

    private func wire() {
        root.findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        root.findBar.onClose = { [weak self] in self?.closeFind() }
        root.gotoBar.onSearch = { [weak self] text, _ in self?.goto(text) }
        root.gotoBar.onClose = { [weak self] in self?.closeGoto() }
        root.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
        root.onLayout = { [weak self] in self?.refit() }
        root.onActivate = { [weak self] in
            guard let self else { return }
            self.root.window?.makeFirstResponder(self.keyView)
        }
        root.toolbar.onAction = { [weak self] id in self?.toolbarAction(id) }
        root.markBar.onKeep = { [weak self] note in self?.keepPending(note: note) }
        root.markBar.onSend = { [weak self] note in self?.send(note: note, choose: NSEvent.modifierFlags.contains(.option)) }
        root.markBar.onDiscard = { [weak self] in self?.discardPending() }
        root.markBar.onClear = { [weak self] in self?.clearMarks() }
        root.image.onZoomChange = { [weak self] in self?.imageZoomChanged() }
        root.image.canvas.onRegion = { [weak self] rect in self?.imageRegion(rect) }
        root.image.canvas.onArrow = { [weak self] step in self?.stepFile(step) ?? false }
        root.pdf.onRegion = { [weak self] page, rect in self?.pdfRegion(page: page, rect: rect) }
        root.sidebar.onMode = { [weak self] mode in self?.setSidebar(mode) }
        root.sidebar.onJump = { [weak self] item in self?.jump(to: item) }
    }

    // MARK: Laden

    private func open(_ url: URL) {
        watcher?.stop()
        file = url
        closeFind()
        closeGoto()
        marks = []
        pending = nil
        markAnnotations = []
        flashAnnotations = []
        back = nil
        root.show(type)
        applyDarkFilter()
        root.setSidebar(type == .pdf ? sidebar : nil)
        watcher = FileWatcher(url: url) { [weak self] event in
            switch event {
            case .changed: self?.reload(announce: true)
            case .missing: self?.showProblem("\(url.lastPathComponent) fehlt — die Kachel wartet, bis sie wieder da ist.")
            }
        }
        reload(announce: false, initial: true)
        updateMarkUI()
    }

    /// Von der Platte lesen (ganz, nicht gemappt: latexmk überschreibt sonst unter PDFKit weg) und zeigen.
    /// Ansicht bleibt stehen; `initial` wendet Startseite und Zoom aus den Args an.
    private func reload(announce: Bool, initial: Bool = false) {
        if folder != nil, folderItems.isEmpty {
            root.setMessage("Ordner \(folder?.lastPathComponent ?? "") enthält noch keine PDFs oder Bilder — die Kachel wartet.")
            delegate?.contentStyleChanged()
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            showProblem(initial ? "Warte auf \(file.lastPathComponent) …" : "\(file.lastPathComponent) fehlt — die Kachel wartet, bis sie wieder da ist.",
                        waiting: initial)
            return
        }
        var note: String?
        switch type {
        case .pdf:
            guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return loadFailed("Kein lesbares PDF (wird es gerade geschrieben?)") }
            note = showPDF(doc, initial: initial)
        case .image:
            guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
                return loadFailed("Bild lässt sich nicht lesen (wird es gerade geschrieben?)")
            }
            root.image.show(image, keepView: !initial, fit: zoom == .fit)
            if initial, case .percent(let p) = zoom { root.image.setZoom(p / 100) }
            refreshMarks()
        case .document:
            root.showDocument(file, refresh: !initial)
        }
        retries = 0
        problem = nil
        root.setMessage(nil)
        if announce { root.pill.flash(note ?? ("↻ neu geladen · " + Self.clock.string(from: Date())), hold: note == nil ? 1.3 : 3) }
        delegate?.contentStyleChanged()
        updateToolbar()
    }

    private func loadFailed(_ reason: String) {
        if retries < 8 {
            retries += 1
            watcher?.retry()
        }
        // Alter Stand bleibt stehen; nur ohne Inhalt die Meldung groß zeigen.
        if !root.hasContent { showProblem(reason) } else { problem = reason; delegate?.contentStyleChanged() }
    }

    private func showProblem(_ text: String, waiting: Bool = false) {
        problem = waiting ? nil : text
        if waiting || !root.hasContent { root.setMessage(text) } else { root.pill.flash("⚠ " + text, hold: 3) }
        delegate?.contentStyleChanged()
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Ordner

    private func watchFolder(_ folder: URL) {
        folderWatcher = FolderWatcher(url: folder) { [weak self] items in self?.folderChanged(items) }
    }

    /// Neue Datei ganz vorn, während die bisher neueste gezeigt wird → vorrücken. Sonst bleibt die gezeigte.
    private func folderChanged(_ items: [URL]) {
        let wasNewest = folderItems.first == file || folderItems.isEmpty
        folderItems = items
        guard let newest = items.first else { return delegate?.contentStyleChanged() ?? () }
        if (wasNewest && newest != file) || !items.contains(file) {
            show(item: newest)
            root.pill.flash("neu: " + newest.lastPathComponent, hold: 2)
        } else {
            delegate?.contentStyleChanged()
            updateToolbar()
        }
    }

    private func show(item: URL) {
        guard let type = Self.fileType(item), type != .document else { return }
        self.type = type
        zoom = type == .pdf ? .width : .fit
        startPage = nil
        open(item)
    }

    /// -1 / +1 (älter/neuer in der Liste = rechts/links). true = Ordner-Modus hat es verbraucht.
    @discardableResult
    private func stepFile(_ step: Int) -> Bool {
        guard folder != nil, !folderItems.isEmpty else { return false }
        let index = folderItems.firstIndex(of: file) ?? 0
        let next = min(max(index + step, 0), folderItems.count - 1)
        if next != index { show(item: folderItems[next]) } else { NSSound.beep() }
        return true
    }

    // MARK: PDF

    var pdfView: PreviewPDFView { root.pdf }

    /// Zeigt `doc`, hält die Stelle; liefert die Pillen-Meldung, wenn zur geänderten Seite gesprungen wurde.
    private func showPDF(_ doc: PDFDocument, initial: Bool) -> String? {
        if pdfObservers.isEmpty { observePDF() }
        let old = pdfView.document
        var anchor: (index: Int, point: NSPoint)?
        if !initial, let old, let dest = pdfView.currentDestination, let page = dest.page {
            anchor = (old.index(for: page), dest.point)
        }
        let changed = initial || old == nil ? [] : Self.changedPages(old!, doc)
        let scale = pdfView.scaleFactor
        settingScale = true
        markAnnotations = []
        flashAnnotations = []
        pdfView.document = doc
        switch zoom {
        case .width: pdfView.autoScales = true
        case .fit: pdfView.autoScales = false; pdfView.scaleFactor = fitScale()
        case .percent(let p): pdfView.autoScales = false; pdfView.scaleFactor = old == nil ? p / 100 : scale
        }
        pdfView.layoutDocumentView()
        if let anchor, let page = doc.page(at: min(anchor.index, doc.pageCount - 1)) {
            pdfView.go(to: PDFDestination(page: page, at: anchor.point))
        } else if initial, let startPage, let page = doc.page(at: min(startPage, doc.pageCount) - 1) {
            pdfView.go(to: page)
        }
        settingScale = false
        root.sidebar.setDocument(doc, pdfView: pdfView)
        if !findText.isEmpty { rerunFind() }
        refreshMarks()
        guard let anchor, let first = changed.first else { return nil }
        if changed.contains(anchor.index) { return "↻ neu · diese Seite geändert" }
        guard follow, let page = doc.page(at: first) else {
            return "↻ neu · Änderung auf S. \(first + 1)"
        }
        back = pdfView.currentDestination
        pdfView.go(to: page)
        flash(page: page, rects: [page.bounds(for: .cropBox).insetBy(dx: 2, dy: 2)], filled: false)
        return "↻ Änderung auf S. \(first + 1) · ⌘[ zurück"
    }

    /// Seiten, deren Text sich geändert hat (plus hinzugekommene/weggefallene am Ende). Bis 600 Seiten.
    static func changedPages(_ old: PDFDocument, _ new: PDFDocument) -> [Int] {
        guard max(old.pageCount, new.pageCount) <= 600 else { return [] }
        var changed: [Int] = []
        for index in 0..<min(old.pageCount, new.pageCount) where old.page(at: index)?.string != new.page(at: index)?.string {
            changed.append(index)
        }
        if old.pageCount != new.pageCount { changed.append(min(old.pageCount, new.pageCount) - (new.pageCount < old.pageCount ? 1 : 0)) }
        return changed.filter { $0 >= 0 && $0 < new.pageCount }
    }

    private func observePDF() {
        let center = NotificationCenter.default
        pdfObservers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.delegate?.contentStyleChanged()
            if let (page, count) = self.pageInfo {
                if !self.root.toolbar.hovered { self.root.pill.flash("\(page) / \(count)") }
                if let doc = self.pdfView.document { self.root.sidebar.follow(pageIndex: page - 1, in: doc) }
            }
            self.updateToolbar()
        })
        pdfObservers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self, !self.settingScale, !self.pdfView.autoScales else { return }
            // Pinch oder ⌘± → fester Prozentwert (bleibt beim Neuladen stehen).
            self.zoom = .percent(Double(self.pdfView.scaleFactor) * 100)
            self.delegate?.contentStyleChanged()
            self.updateToolbar()
        })
        pdfObservers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pdfSelectionChanged()
        })
    }

    var pageInfo: (Int, Int)? {
        guard type == .pdf, let doc = pdfView.document, let page = pdfView.currentPage else { return nil }
        return (doc.index(for: page) + 1, doc.pageCount)
    }

    /// Scale, bei der die aktuelle Seite ganz in die Kachel passt.
    private func fitScale() -> CGFloat {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return 1 }
        var size = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let available = NSSize(width: pdfView.bounds.width - 24, height: pdfView.bounds.height - 24)
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(available.width / size.width, available.height / size.height)
    }

    private func setZoom(_ new: Zoom) {
        zoom = new
        switch type {
        case .pdf:
            settingScale = true
            switch new {
            case .width: pdfView.autoScales = true
            case .fit: pdfView.autoScales = false; pdfView.scaleFactor = fitScale()
            case .percent(let p): pdfView.autoScales = false; pdfView.scaleFactor = p / 100
            }
            settingScale = false
        case .image:
            switch new {
            case .fit, .width: root.image.fitToView()
            case .percent(let p): root.image.setZoom(p / 100)
            }
        case .document:
            return
        }
        root.pill.flash(zoomLabel)
        delegate?.contentStyleChanged()
        updateToolbar()
    }

    /// ⌘+ / ⌘− / ⌘0.
    private func zoomStep(_ step: Int) {
        guard step != 0 else { return setZoom(type == .pdf ? .width : .fit) }
        let factor: CGFloat = step > 0 ? 1.25 : 0.8
        switch type {
        case .pdf: setZoom(.percent(Double(pdfView.scaleFactor * factor) * 100))
        case .image: setZoom(.percent(Double(root.image.magnification * factor) * 100))
        case .document: break
        }
    }

    /// Größenänderung der Kachel: „ganz sichtbar“ bleibt ganz sichtbar.
    private func refit() {
        guard zoom == .fit, type == .pdf, pdfView.document != nil else { return }
        settingScale = true
        pdfView.scaleFactor = fitScale()
        settingScale = false
    }

    private func imageZoomChanged() {
        zoom = root.image.isFitted ? .fit : .percent(Double(root.image.magnification) * 100)
        delegate?.contentStyleChanged()
        updateToolbar()
    }

    private var zoomLabel: String {
        switch type {
        case .pdf:
            if pdfView.autoScales { return "Seitenbreite" }
            if zoom == .fit { return "ganze Seite" }
            return "\(Int((pdfView.scaleFactor * 100).rounded())) %"
        case .image:
            let percent = "\(Int((root.image.magnification * 100).rounded())) %"
            return root.image.isFitted ? "eingepasst · \(percent)" : percent
        case .document:
            return ""
        }
    }

    @discardableResult
    private func go(page number: Int) -> Bool {
        guard type == .pdf, let doc = pdfView.document, number >= 1, let page = doc.page(at: min(number, doc.pageCount) - 1) else { return false }
        back = pdfView.currentDestination
        pdfView.go(to: page)
        return true
    }

    private func goBack() {
        guard let target = back else { NSSound.beep(); return }
        back = pdfView.currentDestination
        pdfView.go(to: target)
    }

    private func applyDarkFilter() {
        root.setDark(type == .pdf && dark)
    }

    /// Stelle kurz aufleuchten lassen (Sprung zur Änderung, `sync`).
    private func flash(page: PDFPage, rects: [NSRect], filled: Bool) {
        let accent = ThemeStore.shared.accentColor
        var added: [(PDFPage, PDFAnnotation)] = []
        for rect in rects {
            let note = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            note.color = accent
            if filled { note.interiorColor = accent.withAlphaComponent(0.25) }
            let border = PDFBorder()
            border.lineWidth = filled ? 1.5 : 3
            note.border = border
            note.isReadOnly = true
            page.addAnnotation(note)
            added.append((page, note))
        }
        flashAnnotations += added
        DispatchQueue.main.asyncAfter(deadline: .now() + (filled ? 2.6 : 1.4)) { [weak self] in
            for (page, note) in added { page.removeAnnotation(note) }
            self?.flashAnnotations.removeAll { pair in added.contains { $0.1 === pair.1 } }
        }
    }

    private func setSidebar(_ mode: PreviewSidebar.Mode?) {
        guard type == .pdf else { return }
        sidebar = mode
        root.setSidebar(mode)
        if let doc = pdfView.document, let (page, _) = pageInfo { root.sidebar.follow(pageIndex: page - 1, in: doc) }
        updateToolbar()
    }

    private func jump(to item: PDFOutline) {
        let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
        guard let destination else { return }
        back = pdfView.currentDestination
        pdfView.go(to: destination)
    }

    // MARK: SyncTeX vorwärts

    /// `datei.tex:zeile` (relativ zum PDF oder absolut) oder nur `zeile` (dann `<pdf-stamm>.tex`) → Seite (1-basiert).
    func sync(_ spec: String) throws -> Int {
        guard type == .pdf, let doc = pdfView.document else { throw PaneArgsError("sync geht nur bei einem geladenen PDF") }
        guard SyncTeX.available(for: file) else {
            throw PaneArgsError("Keine SyncTeX-Daten neben \(file.lastPathComponent) — mit latexmk -synctex=1 kompilieren")
        }
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        var source = file.deletingPathExtension().appendingPathExtension("tex").path
        var lineText = trimmed
        if let colon = trimmed.lastIndex(of: ":") {
            let path = String(trimmed[..<colon])
            lineText = String(trimmed[trimmed.index(after: colon)...])
            let expanded = (path as NSString).expandingTildeInPath
            source = expanded.hasPrefix("/") ? expanded : file.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL.path
        }
        guard let line = Int(lineText), line > 0 else { throw PaneArgsError("sync braucht <datei.tex>:<zeile>, bekam „\(spec)“") }
        let boxes = SyncTeX.view(pdf: file, source: source, line: line)
        guard let first = boxes.first, let page = doc.page(at: first.page - 1) else {
            throw PaneArgsError("SyncTeX kennt \((source as NSString).lastPathComponent):\(line) nicht (Zeile ohne Satz, oder PDF älter als die Quelle?)")
        }
        let height = page.bounds(for: .mediaBox).height
        let rects = boxes.filter { $0.page == first.page }.map {
            NSRect(x: $0.rect.minX - 2, y: height - $0.rect.maxY - 2, width: $0.rect.width + 4, height: $0.rect.height + 4)
        }
        back = pdfView.currentDestination
        let top = rects.map(\.maxY).max() ?? height
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: min(height, top + 60))))
        flash(page: page, rects: rects, filled: true)
        return first.page
    }

    // MARK: Suche, Gehe zu

    private func showFind() {
        guard type == .pdf else { return }
        closeGoto()
        root.findBar.show(text: findText)
        root.window?.makeFirstResponder(root.findBar.field)
    }

    private func closeFind() {
        guard root.findBar.isVisible || !findText.isEmpty else { return }
        // Vor dem Ausblenden fragen: danach hat AppKit den Fokus schon ans Fenster gegeben (Kachel verlor ihn, 23.09.).
        let hadFocus = (root.window?.firstResponder as? NSView)?.isDescendant(of: root.findBar) == true
        if hadFocus { root.window?.makeFirstResponder(keyView) }
        root.findBar.hide()
        findText = ""
        findResults = []
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    /// Gleicher Text = nächster Treffer (bzw. voriger), neuer Text = neue Suche ab der aktuellen Seite.
    private func find(_ text: String, backwards: Bool = false) {
        guard type == .pdf, let doc = pdfView.document else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { closeFind(); return }
        if text != findText {
            findText = text
            findResults = doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            let current = pdfView.currentPage.map { doc.index(for: $0) } ?? 0
            findIndex = findResults.firstIndex { sel in sel.pages.first.map { doc.index(for: $0) >= current } ?? false } ?? 0
        } else if !findResults.isEmpty {
            findIndex = (findIndex + (backwards ? -1 : 1) + findResults.count) % findResults.count
        }
        showFindResult()
    }

    private func rerunFind() {
        guard let doc = pdfView.document else { return }
        findResults = doc.findString(findText, withOptions: [.caseInsensitive, .diacriticInsensitive])
        findIndex = min(findIndex, max(findResults.count - 1, 0))
        showFindResult(scroll: false)
    }

    private func showFindResult(scroll: Bool = true) {
        for sel in findResults { sel.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        pdfView.highlightedSelections = findResults.isEmpty ? nil : findResults
        guard !findResults.isEmpty else {
            root.findBar.setCount("keine Treffer")
            return
        }
        let sel = findResults[findIndex]
        if scroll {
            pdfView.setCurrentSelection(sel, animate: true)
            pdfView.go(to: sel)
        }
        root.findBar.setCount("\(findIndex + 1) / \(findResults.count)")
    }

    private func showGoto() {
        guard type == .pdf, let doc = pdfView.document else { return }
        closeFind()
        root.gotoBar.field.stringValue = ""
        root.gotoBar.show(text: "")
        root.gotoBar.setCount("von \(doc.pageCount)")
        root.window?.makeFirstResponder(root.gotoBar.field)
    }

    private func closeGoto() {
        guard root.gotoBar.isVisible else { return }
        let hadFocus = (root.window?.firstResponder as? NSView)?.isDescendant(of: root.gotoBar) == true
        if hadFocus { root.window?.makeFirstResponder(keyView) }
        root.gotoBar.hide()
    }

    /// Zahl = Seite; sonst Seitenlabel aus dem PDF („iv“, „A-3“).
    private func goto(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let doc = pdfView.document, !trimmed.isEmpty else { return closeGoto() }
        if let number = Int(trimmed) {
            go(page: number)
        } else if let index = (0..<doc.pageCount).first(where: { doc.page(at: $0)?.label?.lowercased() == trimmed.lowercased() }) {
            go(page: index + 1)
        } else {
            NSSound.beep()
            return
        }
        closeGoto()
    }

    // MARK: Markieren und an die Session geben

    private func pdfSelectionChanged() {
        guard let doc = pdfView.document else { return }
        if let selection = pdfView.currentSelection, !selection.isFindResult(in: findResults),
           let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let page = selection.pages.first {
            let lines = selection.selectionsByLine().filter { $0.pages.first == page }.map { $0.bounds(for: page) }
            let rect = lines.reduce(selection.bounds(for: page)) { $0.union($1) }
            pending = PreviewMark(kind: .text, page: doc.index(for: page), rect: rect, lines: lines,
                                  text: Self.wholeWords(selection, lines: lines, on: page) ?? text)
            refreshMarks()
            updateMarkUI()
        } else if pending?.kind == .text {
            pending = nil
            updateMarkUI()
        }
    }

    /// Text der Auswahl auf ganze Wörter erweitert („ücke ist“ → „Lücke ist“) — halb getroffene Wörter beim Ziehen sind normal.
    private static func wholeWords(_ selection: PDFSelection, lines: [NSRect], on page: PDFPage) -> String? {
        guard let first = lines.first, let last = lines.last,
              let copy = selection.copy() as? PDFSelection else { return nil }
        if let start = page.selectionForWord(at: NSPoint(x: first.minX + 1, y: first.midY)) { copy.add(start) }
        if let end = page.selectionForWord(at: NSPoint(x: last.maxX - 1, y: last.midY)) { copy.add(end) }
        return copy.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pdfRegion(page: PDFPage, rect: NSRect) {
        guard let doc = pdfView.document else { return }
        pdfView.clearSelection()
        let text = page.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pending = PreviewMark(kind: .region, page: doc.index(for: page), rect: rect, text: text)
        refreshMarks()
        updateMarkUI()
    }

    private func imageRegion(_ rect: NSRect) {
        pending = PreviewMark(kind: .region, page: 0, rect: rect)
        refreshMarks()
        updateMarkUI()
    }

    private func keepPending(note: String) {
        guard var mark = pending else { return }
        mark.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        marks.append(mark)
        pending = nil
        pdfView.clearSelection()
        refreshMarks()
        updateMarkUI()
        root.window?.makeFirstResponder(keyView)
        root.pill.flash(marks.count == 1 ? "1 Stelle gemerkt · ⇧⌘⏎ senden" : "\(marks.count) Stellen gemerkt · ⇧⌘⏎ senden", hold: 2)
    }

    private func discardPending() {
        pending = nil
        pdfView.clearSelection()
        refreshMarks()
        updateMarkUI()
        root.window?.makeFirstResponder(keyView)
    }

    private func clearMarks() {
        marks = []
        refreshMarks()
        updateMarkUI()
    }

    private func updateMarkUI() {
        var summary: String?
        if let pending {
            let place = type == .pdf ? "S. \(pending.page + 1)" : "Bereich"
            let text = pending.text.replacingOccurrences(of: "\n", with: " ")
            summary = text.isEmpty ? "\(place) · Rahmen" : "\(place) · „\(text.prefix(60))\(text.count > 60 ? "…" : "")“"
        }
        root.markBar.update(selection: summary, count: marks.count)
        updateToolbar()
    }

    /// Hervorhebungen neu setzen: PDF über Annotationen (scrollen mit), Bild über die Leinwand.
    private func refreshMarks() {
        switch type {
        case .image:
            root.image.canvas.marks = marks.map(\.rect)
            root.image.canvas.pending = pending?.rect
        case .pdf:
            for (page, note) in markAnnotations { page.removeAnnotation(note) }
            markAnnotations = []
            guard let doc = pdfView.document else { return }
            let accent = ThemeStore.shared.accentColor
            for (index, mark) in marks.enumerated() {
                guard let page = doc.page(at: mark.page) else { continue }
                annotate(mark, on: page, color: accent, number: index + 1, dashed: false)
            }
            if let pending, let page = doc.page(at: pending.page) {
                annotate(pending, on: page, color: accent, number: nil, dashed: true)
            }
        case .document:
            break
        }
    }

    private func annotate(_ mark: PreviewMark, on page: PDFPage, color: NSColor, number: Int?, dashed: Bool) {
        func add(_ note: PDFAnnotation) {
            note.isReadOnly = true
            page.addAnnotation(note)
            markAnnotations.append((page, note))
        }
        if mark.kind == .text {
            for line in mark.lines {
                let note = PDFAnnotation(bounds: line, forType: .highlight, withProperties: nil)
                note.color = color.withAlphaComponent(0.35)
                add(note)
            }
        } else {
            let note = PDFAnnotation(bounds: mark.rect, forType: .square, withProperties: nil)
            note.color = color
            note.interiorColor = color.withAlphaComponent(0.08)
            let border = PDFBorder()
            border.lineWidth = 1.5
            if dashed { border.style = .dashed; border.dashPattern = [4, 3] }
            note.border = border
            add(note)
        }
        if let number {
            // Im linken Seitenrand auf Höhe der ersten Zeile — nie über dem Text (verdeckte sonst den Wortanfang, 23.09.).
            let box = page.bounds(for: .cropBox)
            let top = (mark.lines.first ?? mark.rect).maxY
            let badge = PDFAnnotation(bounds: NSRect(x: box.minX + 14, y: top - 13, width: 15, height: 14),
                                      forType: .freeText, withProperties: nil)
            badge.contents = "\(number)"
            badge.font = .boldSystemFont(ofSize: 9)
            badge.fontColor = .black
            badge.color = color
            badge.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            badge.border = border
            add(badge)
        }
    }

    /// Alle gemerkten Stellen plus die aktuelle Auswahl an eine Agenten-Kachel: Text mit Seite, SyncTeX-Zeile,
    /// Notiz und je einem Ausschnitt als PNG. Enter drückt der Nutzer (er kann noch etwas dazuschreiben).
    func send(note: String, choose: Bool) {
        guard !sending else { return }
        var batch = marks
        if var current = pending {
            current.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            batch.append(current)
        }
        guard !batch.isEmpty else {
            NSSound.beep()
            root.pill.flash("Erst markieren: Text auswählen oder mit ⌥ einen Rahmen ziehen", hold: 3)
            return
        }
        switch AgentHandoff.target(delegate, choose: choose) {
        case .none(let reason):
            NSSound.beep()
            root.pill.flash(reason, hold: 3)
        case .direct(let pane):
            deliver(batch, to: pane)
        case .choose(let agents):
            let title = batch.count == 1 ? "Stelle an …" : "\(batch.count) Stellen an …"
            let menu = AgentHandoff.menu(agents, header: title, opener: delegate?.contentOpener) { [weak self] pane in
                self?.deliver(batch, to: pane)
            }
            let anchor = root.markBar.isHidden ? root.toolbar : root.markBar
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY + 4), in: root)
        }
    }

    private func deliver(_ batch: [PreviewMark], to pane: PaneInfo) {
        sending = true
        root.pill.flash("➤ bereite \(batch.count == 1 ? "Stelle" : "\(batch.count) Stellen") vor …", hold: 5)
        let file = file, type = type, doc = pdfView.document
        let image = root.image.canvas.image, pointSize = root.image.pointSize, pixelSize = root.image.pixelSize
        let synctex = type == .pdf && SyncTeX.available(for: file)
        // Ausschnitte auf dem Main-Thread (PDFKit/NSImage), SyncTeX-Aufrufe im Hintergrund.
        var crops: [URL?] = []
        for mark in batch {
            var png: Data?
            if type == .pdf, let page = doc?.page(at: mark.page) {
                // Textstellen über die ganze Seitenbreite (ganze Zeilen lesbar), Rahmen genau wie gezogen.
                let box = page.bounds(for: .cropBox)
                let area = mark.kind == .text
                    ? NSRect(x: box.minX, y: mark.rect.minY - 14, width: box.width, height: mark.rect.height + 28)
                    : mark.rect.insetBy(dx: -6, dy: -6)
                png = PreviewRender.crop(page, rect: area)
            } else if type == .image, let image {
                png = PreviewRender.crop(image, pointRect: mark.rect, pointSize: pointSize)
            }
            crops.append(png.flatMap { try? AgentHandoff.writePNG($0, prefix: "Vorschau") })
        }
        let heights = batch.map { doc?.page(at: $0.page)?.bounds(for: .mediaBox).height ?? 0 }
        let pages = doc?.pageCount
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var located = batch
            if synctex {
                for index in located.indices {
                    let mark = located[index], height = heights[index]
                    // Seitenkoordinaten (unten links) → SyncTeX (oben links).
                    let top = NSRect(x: mark.rect.minX, y: height - mark.rect.maxY, width: mark.rect.width, height: mark.rect.height)
                    located[index].source = SyncTeX.span(pdf: file, page: mark.page + 1, top: top)
                }
            }
            let text = Self.compose(located, crops: crops, file: file, type: type, pages: pages,
                                    pixelSize: pixelSize, pointSize: pointSize)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                guard self.delegate?.contentPaste(text, intoPaneID: pane.id) == true else {
                    NSSound.beep()
                    self.root.pill.flash("Kachel \(pane.index) nimmt nichts an", hold: 3)
                    return
                }
                self.marks = []
                self.pending = nil
                self.pdfView.clearSelection()
                self.refreshMarks()
                self.updateMarkUI()
                self.root.pill.flash("➤ \(batch.count == 1 ? "Stelle liegt" : "\(batch.count) Stellen liegen") in Kachel \(pane.index)", hold: 2.5)
            }
        }
    }

    /// Der eingefügte Text: Kopf mit Datei, je Stelle eine Zeile mit Ort, Quelle, Text, Notiz, Ausschnitt.
    nonisolated static func compose(_ marks: [PreviewMark], crops: [URL?], file: URL, type: FileType, pages: Int?,
                        pixelSize: NSSize, pointSize: NSSize) -> String {
        let tilde = (file.path as NSString).abbreviatingWithTildeInPath
        let base = file.deletingLastPathComponent()
        var head = "Aus der Vorschau \(tilde)"
        if let pages { head += " (\(pages) S.)" }
        if type == .image { head += " (\(Int(pixelSize.width))×\(Int(pixelSize.height)) px)" }
        head += marks.count == 1 ? ":" : " — \(marks.count) Stellen:"
        var lines = [head]
        for (index, mark) in marks.enumerated() {
            var place: [String] = []
            if type == .pdf { place.append("S. \(mark.page + 1)") }
            if let source = mark.source { place.append(source.label(relativeTo: base)) }
            if type == .image, pointSize.width > 0 {
                let sx = pixelSize.width / pointSize.width, sy = pixelSize.height / pointSize.height
                place.append("Bereich x \(Int(mark.rect.minX * sx))–\(Int(mark.rect.maxX * sx)), y \(Int(mark.rect.minY * sy))–\(Int(mark.rect.maxY * sy)) px")
            } else if mark.kind == .region {
                place.append("Rahmen")
            }
            var line = "\(index + 1). " + place.joined(separator: " · ")
            let text = mark.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { line += " — „\(text.prefix(400))\(text.count > 400 ? "…" : "")“" }
            lines.append(line)
            if !mark.note.isEmpty { lines.append("   Notiz: \(mark.note)") }
            if let crop = crops[index] { lines.append("   Ausschnitt: \(crop.path)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Werkzeugleiste und Tasten

    private func updateToolbar() {
        var items: [PreviewToolbar.Item] = []
        if type == .pdf {
            items.append(.init(id: "sidebar", symbol: "sidebar.left", tooltip: "Seitenleiste (⌥⌘2 Miniaturen, ⌥⌘3 Inhalt)", active: sidebar != nil))
        }
        if type != .document {
            items.append(.init(id: "zoom-out", symbol: "minus.magnifyingglass", tooltip: "Verkleinern (⌘−)"))
            items.append(.init(id: "zoom-toggle", symbol: nil, title: zoomLabel,
                               tooltip: type == .pdf ? "Seitenbreite ↔ ganze Seite (⌘0 Seitenbreite)" : "Eingepasst ↔ 1:1 (⌘0 eingepasst)"))
            items.append(.init(id: "zoom-in", symbol: "plus.magnifyingglass", tooltip: "Vergrößern (⌘+)"))
        }
        if type == .pdf {
            items.append(.init(id: "dark", symbol: "circle.lefthalf.filled", tooltip: "Dunkle Darstellung", active: dark))
        }
        if folder != nil, !folderItems.isEmpty {
            let index = (folderItems.firstIndex(of: file) ?? 0) + 1
            items.append(.init(id: "file-next", symbol: "chevron.left", tooltip: "Neuere Datei (⌥⌘←, im Bild ←)"))
            items.append(.init(id: "file-list", symbol: nil, title: "\(index)/\(folderItems.count) \(file.lastPathComponent.prefix(24))",
                               tooltip: "Dateien im Ordner, neueste zuerst"))
            items.append(.init(id: "file-prev", symbol: "chevron.right", tooltip: "Ältere Datei (⌥⌘→, im Bild →)"))
        }
        if type != .document {
            items.append(.init(id: "send", symbol: "paperplane", tooltip: "Markierte Stellen an die Claude-/Codex-Kachel (⇧⌘⏎) — erst Text auswählen oder mit ⌥ einen Rahmen ziehen",
                               active: !marks.isEmpty || pending != nil))
        }
        items.append(.init(id: "open", symbol: "arrow.up.forward.app", tooltip: "Im Standardprogramm öffnen"))
        root.toolbar.setItems(items)
    }

    private func toolbarAction(_ id: String) {
        switch id {
        case "sidebar": setSidebar(sidebar == nil ? .thumbs : nil)
        case "zoom-out": zoomStep(-1)
        case "zoom-in": zoomStep(1)
        case "zoom-toggle":
            if type == .pdf { setZoom(zoom == .width ? .fit : .width) } else { setZoom(root.image.isFitted ? .percent(100) : .fit) }
        case "dark": dark.toggle(); applyDarkFilter(); updateToolbar()
        case "file-next": stepFile(-1)
        case "file-prev": stepFile(1)
        case "file-list": showFileMenu()
        case "send": send(note: root.markBar.note.stringValue, choose: NSEvent.modifierFlags.contains(.option))
        case "open": NSWorkspace.shared.open(file)
        default: break
        }
        root.window?.makeFirstResponder(keyView)
    }

    private func showFileMenu() {
        let menu = NSMenu()
        for (index, item) in folderItems.prefix(40).enumerated() {
            let entry = ClosureMenuItem(title: item.lastPathComponent, keyEquivalent: "") { [weak self] in self?.show(item: item) }
            entry.state = item == file ? .on : .off
            if index == 0 { entry.title += "  (neueste)" }
            menu.addItem(entry)
        }
        let anchor = root.toolbar.frame
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), in: root)
    }

    /// Kürzel der Vorschau (die Hülle hat ⌘T/⌘W/⌘1–9 vorher verteilt, ⌘⏎ fällt zu ihr durch).
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch mods {
        case .command:
            switch key {
            case "+", "=": zoomStep(1)
            case "-": zoomStep(-1)
            case "0": zoomStep(0)
            case "g":
                guard root.findBar.isVisible else { return false }
                find(root.findBar.field.stringValue)
            case "l": guard type == .pdf else { return false }; showGoto()
            case "[": guard type == .pdf else { return false }; goBack()
            default: return false
            }
        case [.command, .shift]:
            if isReturn { send(note: root.markBar.note.stringValue, choose: false); return true }
            switch key.lowercased() {
            case "+": zoomStep(1)
            case "g":
                guard root.findBar.isVisible else { return false }
                find(root.findBar.field.stringValue, backwards: true)
            default: return false
            }
        case [.command, .shift, .option]:
            guard isReturn else { return false }
            send(note: root.markBar.note.stringValue, choose: true)
        case [.command, .option]:
            switch event.keyCode {
            case 123: return stepFile(-1)   // ←
            case 124: return stepFile(1)    // →
            default: break
            }
            guard type == .pdf else { return false }
            switch key {
            case "1", "¡": setSidebar(nil)
            case "2", "“": setSidebar(.thumbs)
            case "3", "¶": setSidebar(.toc)
            default:
                // Auf deutscher Tastatur liefert ⌥ andere Zeichen — über den Tastencode gehen.
                switch event.keyCode {
                case 18: setSidebar(nil)
                case 19: setSidebar(.thumbs)
                case 20: setSidebar(.toc)
                default: return false
                }
            }
        default:
            return false
        }
        return true
    }

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView {
        guard root.hasContent else { return root }
        switch type {
        case .pdf: return pdfView
        case .image: return root.image.canvas
        case .document: return root.quickLook ?? root
        }
    }
    var title: String { file.lastPathComponent }
    var directory: String? { (folder ?? file.deletingLastPathComponent()).path }

    var chip: StatusChip? {
        let tilde = ((folder ?? file).path as NSString).abbreviatingWithTildeInPath
        var prefix = ""
        if folder != nil, !folderItems.isEmpty { prefix = "\((folderItems.firstIndex(of: file) ?? 0) + 1)/\(folderItems.count) · " }
        if !marks.isEmpty { prefix = "✎\(marks.count) · " + prefix }
        if let problem {
            return StatusChip(long: "⚠ " + problem, short: "⚠", glyph: "⚠", tone: ThemeStore.shared.theme.yellow, tooltip: tilde)
        }
        guard root.hasContent else {
            return StatusChip(long: "wartet auf Datei", short: "wartet", glyph: "…", tone: ThemeStore.shared.theme.dim, tooltip: tilde)
        }
        switch type {
        case .pdf:
            guard let (page, count) = pageInfo else { return nil }
            return StatusChip(long: prefix + "S. \(page)/\(count) · \(zoomLabel)", short: "\(page)/\(count)", glyph: "\(page)",
                              tone: ThemeStore.shared.accentColor, tooltip: tilde)
        case .image:
            let px = root.image.pixelSize
            return StatusChip(long: prefix + "\(Int(px.width))×\(Int(px.height)) · \(zoomLabel)",
                              short: "\(Int((root.image.magnification * 100).rounded())) %", tone: ThemeStore.shared.accentColor, tooltip: tilde)
        case .document:
            return StatusChip(long: prefix + file.pathExtension.uppercased(), short: file.pathExtension.uppercased(),
                              tone: ThemeStore.shared.accentColor, tooltip: tilde)
        }
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
        refreshMarks()
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (verb, rest) = trimmed.firstIndex(of: " ").map {
            (String(trimmed[..<$0]).lowercased(), String(trimmed[$0...]).trimmingCharacters(in: .whitespaces))
        } ?? (trimmed.lowercased(), "")
        switch verb {
        case "reload": reload(announce: true)
        case "load":
            guard let target = try? Self.resolve(rest) else { return false }
            folderWatcher?.stop()
            folderWatcher = nil
            switch target {
            case .file(let url, let type):
                folder = nil
                folderItems = []
                self.type = type
                zoom = type == .pdf ? .width : .fit
                startPage = nil
                open(url)
            case .folder(let url):
                folder = url
                folderItems = FolderWatcher.items(in: url)
                watchFolder(url)
                if let newest = folderItems.first { show(item: newest) } else { open(url.appendingPathComponent("…")) }
            }
        case "page": return Int(rest).map { go(page: $0) } ?? false
        case "next":
            guard type == .pdf else { return false }
            if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        case "prev", "previous":
            guard type == .pdf else { return false }
            if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        case "back": guard type == .pdf else { return false }; goBack()
        case "find":
            guard type == .pdf, !rest.isEmpty else { return false }
            root.findBar.show(text: rest)
            find(rest)
        case "zoom":
            guard type != .document, let zoom = Zoom(rest) else { return false }
            setZoom(zoom)
        case "sync":
            return (try? sync(rest)) != nil
        case "sidebar":
            guard type == .pdf else { return false }
            switch rest.lowercased() {
            case "", "toggle": setSidebar(sidebar == nil ? .thumbs : nil)
            case "off", "aus", "0": setSidebar(nil)
            case "thumbs", "seiten": setSidebar(.thumbs)
            case "toc", "inhalt": setSidebar(.toc)
            default: return false
            }
        case "dark":
            guard type == .pdf else { return false }
            switch rest.lowercased() {
            case "", "toggle": dark.toggle()
            case "on", "an", "1": dark = true
            case "off", "aus", "0": dark = false
            default: return false
            }
            applyDarkFilter()
            updateToolbar()
        case "follow":
            follow = !["off", "aus", "0"].contains(rest.lowercased())
        case "file":
            guard folder != nil else { return false }
            switch rest.lowercased() {
            case "next", "older", "prev-newer": return stepFile(1)
            case "prev", "newer": return stepFile(-1)
            case "newest", "neueste": if let newest = folderItems.first { show(item: newest) }
            default:
                guard let item = folderItems.first(where: { $0.lastPathComponent == rest }) else { return false }
                show(item: item)
            }
        case "marks":
            guard rest == "clear" else { return false }
            clearMarks()
        default: return false
        }
        return true
    }

    /// `state` → JSON (Datei, Art, Seite, Zoom, Marken); `look <png> [page=N]` → Bild der Seite/des Bilds + Text;
    /// `sync <datei>:<zeile>` → Seite.
    func call(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var reply: [String: Any]
        if trimmed == "state" {
            reply = state()
        } else if trimmed.hasPrefix("look ") {
            reply = try look(String(trimmed.dropFirst(5)))
        } else if trimmed.hasPrefix("sync ") {
            reply = ["page": try sync(String(trimmed.dropFirst(5)))]
        } else {
            throw PaneArgsError("preview versteht call state, look <png> [page=N], sync <datei.tex>:<zeile>")
        }
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func state() -> [String: Any] {
        var state: [String: Any] = ["file": file.path, "type": "\(type)", "zoom": zoom.arg, "loaded": root.hasContent,
                                    "marks": marks.count, "follow": follow]
        if let problem { state["problem"] = problem }
        if let (page, count) = pageInfo {
            state["page"] = page
            state["pages"] = count
            state["dark"] = dark
            state["synctex"] = SyncTeX.available(for: file)
            state["sidebar"] = sidebar?.rawValue ?? "off"
        }
        if type == .image { state["pixels"] = [Int(root.image.pixelSize.width), Int(root.image.pixelSize.height)] }
        if let folder {
            state["folder"] = folder.path
            state["items"] = folderItems.count
        }
        return state
    }

    /// Bild für den Agenten: PDF-Seite (aktuelle oder `page=N`) samt Text, sonst das Bild bzw. die Ansicht.
    private func look(_ spec: String) throws -> [String: Any] {
        var parts = spec.split(separator: " ").map(String.init)
        guard let path = parts.first, path.hasPrefix("/") else { throw PaneArgsError("look braucht einen absoluten PNG-Pfad") }
        parts.removeFirst()
        var reply = state()
        var png: Data?
        switch type {
        case .pdf:
            guard let doc = pdfView.document else { throw PaneArgsError("Noch kein PDF geladen") }
            var index = pdfView.currentPage.map { doc.index(for: $0) } ?? 0
            if let arg = parts.first(where: { $0.hasPrefix("page=") }), let number = Int(arg.dropFirst(5)) {
                index = min(max(number, 1), doc.pageCount) - 1
            }
            guard let page = doc.page(at: index) else { throw PaneArgsError("Seite fehlt") }
            png = PreviewRender.page(page)
            reply["shownPage"] = index + 1
            reply["label"] = page.label
            let text = page.string ?? ""
            reply["text"] = String(text.prefix(6000))
            let visible = pdfView.visiblePages.map { doc.index(for: $0) + 1 }
            if let first = visible.min(), let last = visible.max() { reply["visible"] = [first, last] }
        case .image:
            if let cg = root.image.canvas.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                png = PreviewRender.scaled(cg, maxPixels: 1600)
            }
        case .document:
            png = root.quickLook.flatMap { PreviewRender.snapshot($0) }
        }
        guard let png else { throw PaneArgsError("Kein Bild verfügbar") }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        reply["image"] = path
        reply["markList"] = marks.enumerated().map { index, mark in
            ["n": index + 1, "page": mark.page + 1, "text": String(mark.text.prefix(200)), "note": mark.note]
        }
        return reply
    }

    func handle(_ command: PaneCommand) -> Bool {
        guard command == .find, type == .pdf else { return false }
        showFind()
        return true
    }

    func willClose() {
        watcher?.stop()
        watcher = nil
        folderWatcher?.stop()
        folderWatcher = nil
        pdfObservers.forEach(NotificationCenter.default.removeObserver)
        pdfObservers = []
        root.teardown()
    }

    /// Nach ⌥⌘R dieselbe Datei (bzw. derselbe Ordner) auf derselben Seite mit demselben Zoom.
    func snapshotArgs() -> [String: String]? {
        var args = ["url": (folder ?? file).path]
        if folder != nil, root.hasContent { args["item"] = file.lastPathComponent }
        if let (page, _) = pageInfo, page > 1 { args["page"] = String(page) }
        if type != .document, zoom != (type == .pdf ? .width : .fit) { args["zoom"] = zoom.arg }
        if dark && type == .pdf { args["dark"] = "1" }
        if let sidebar, type == .pdf { args["sidebar"] = sidebar.rawValue }
        if !follow { args["follow"] = "0" }
        return args
    }
}

private extension PDFSelection {
    /// Ist diese Auswahl nur der aktuelle Suchtreffer (dann keine Markierung anbieten)?
    func isFindResult(in results: [PDFSelection]) -> Bool {
        guard let text = string, let page = pages.first else { return false }
        return results.contains { $0.pages.first == page && $0.string == text && $0.bounds(for: page) == bounds(for: page) }
    }
}

// MARK: - Views

/// Wurzel der Vorschau: Grund in Theme-Farbe, darin PDF-, Bild- oder QuickLook-Ansicht, Seitenleiste, Leisten.
final class PreviewRootView: NSView {
    let pdf = PreviewPDFView()
    let image = ImagePreviewView()
    let sidebar = PreviewSidebar()
    let pill = PreviewPill()
    let findBar = PreviewFindBar(placeholder: "Im PDF suchen")
    let gotoBar = PreviewFindBar(placeholder: "Gehe zu Seite")
    let toolbar = PreviewToolbar()
    let markBar = PreviewMarkBar()
    private(set) var quickLook: QLPreviewView?
    private let message = NSTextField(wrappingLabelWithString: "")
    private var theme = ThemeStore.shared.theme
    private var type: PreviewContent.FileType = .pdf
    private var sidebarShown = false
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onLayout: (() -> Void)?
    /// Klick irgendwo in die Kachel (auch auf den Grund neben Seite/Bild) → Fokus an den Inhalt.
    var onActivate: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.pageShadowsEnabled = true
        pdf.minScaleFactor = 0.05
        pdf.maxScaleFactor = 16
        pdf.autoScales = true
        message.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.isSelectable = false
        for view in [pdf, image, sidebar, message, pill, markBar, findBar, gotoBar, toolbar] as [NSView] { addSubview(view) }
        // Nur die Seite bzw. das Bild wollten den Fokus; Grund und Scroll-Fläche nicht. Der Erkenner sieht jeden
        // Klick in der Kachel, hält aber keinen auf (PDF-Auswahl, Ziehen, Doppelklick laufen ungestört).
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        click.delaysSecondaryMouseButtonEvents = false
        click.delaysOtherMouseButtonEvents = false
        addGestureRecognizer(click)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        pdf.isHidden = true
        image.isHidden = true
        message.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() {
        if (window?.firstResponder as? NSView)?.isDescendant(of: self) != true { onActivate?() }
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func mouseMoved(with event: NSEvent) { toolbar.poke() }
    override func mouseEntered(with event: NSEvent) { toolbar.poke() }

    func show(_ type: PreviewContent.FileType) {
        self.type = type
        pdf.document = nil
        image.clear()
        quickLook?.previewItem = nil
        pdf.isHidden = true
        image.isHidden = true
        quickLook?.isHidden = true
        markBar.update(selection: nil, count: 0)
    }

    func showDocument(_ file: URL, refresh: Bool) {
        if quickLook == nil, let view = QLPreviewView(frame: bounds, style: .normal) {
            view.autostarts = true
            addSubview(view, positioned: .below, relativeTo: sidebar)
            quickLook = view
        }
        if refresh, (quickLook?.previewItem as? URL) == file { quickLook?.refreshPreviewItem() } else { quickLook?.previewItem = file as NSURL }
        needsLayout = true
    }

    var hasContent: Bool {
        switch type {
        case .pdf: return pdf.document != nil
        case .image: return image.hasImage
        case .document: return quickLook?.previewItem != nil
        }
    }

    func setMessage(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        pdf.isHidden = type != .pdf || !hasContent
        image.isHidden = type != .image || !hasContent
        quickLook?.isHidden = type != .document || !hasContent
        needsLayout = true
    }

    func setSidebar(_ mode: PreviewSidebar.Mode?) {
        sidebarShown = mode != nil
        sidebar.isHidden = mode == nil
        if let mode { sidebar.setMode(mode) }
        needsLayout = true
    }

    func setDark(_ on: Bool) {
        pdf.wantsLayer = true
        pdf.layerUsesCoreImageFilters = true
        if on, let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            pdf.contentFilters = [invert, hue]
        } else {
            pdf.contentFilters = []
        }
        // Schatten würden invertiert zu hellen Rändern.
        pdf.pageShadowsEnabled = !on
        // Invertiert wird auch der Grund — also vorher umkehren, damit er am Ende Theme-Farbe hat.
        pdf.backgroundColor = on ? theme.background.invertedForFilter : theme.background
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.withAlphaComponent(1).cgColor
        pdf.backgroundColor = pdf.contentFilters.isEmpty ? theme.background : theme.background.invertedForFilter
        image.applyTheme(theme)
        sidebar.applyTheme(theme)
        message.textColor = theme.dim
        pill.applyTheme(theme)
        findBar.applyTheme(theme)
        gotoBar.applyTheme(theme)
        toolbar.applyTheme(theme)
        markBar.applyTheme(theme)
    }

    override func layout() {
        super.layout()
        let left = sidebarShown && type == .pdf ? PreviewSidebar.width : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: PreviewSidebar.width, height: bounds.height)
        let content = NSRect(x: left, y: 0, width: bounds.width - left, height: bounds.height)
        pdf.frame = content
        image.frame = content
        quickLook?.frame = content
        let width = min(content.width - 48, 420)
        let height = message.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        message.frame = NSRect(x: content.minX + (content.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        pill.layoutIn(bounds, left: left)
        findBar.layoutIn(bounds)
        gotoBar.layoutIn(bounds)
        toolbar.layoutIn(bounds, left: left + 10)
        markBar.layoutIn(bounds)
        if left > 0 { markBar.frame.origin.x = max(markBar.frame.origin.x, left + 12) }
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.withAlphaComponent(1).setFill()
        dirtyRect.fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    func teardown() {
        pdf.document = nil
        image.clear()
        quickLook?.close()
        quickLook = nil
    }
}

/// PDFView mit ⌥-Rahmen: ⌥ gedrückt ziehen = Bereich markieren (statt Text auswählen).
final class PreviewPDFView: PDFView {
    var onRegion: ((PDFPage, NSRect) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), onRegion != nil else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        guard let page = page(for: start, nearest: true) else { return }
        let band = NSView()
        band.wantsLayer = true
        band.layer?.borderColor = ThemeStore.shared.accentColor.cgColor
        band.layer?.borderWidth = 1.5
        band.layer?.backgroundColor = ThemeStore.shared.accentColor.withAlphaComponent(0.1).cgColor
        addSubview(band)
        var end = start
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            end = convert(next.locationInWindow, from: nil)
            band.frame = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if next.type == .leftMouseUp { break }
        }
        band.removeFromSuperview()
        guard abs(end.x - start.x) > 6, abs(end.y - start.y) > 6 else { return }
        let a = convert(start, to: page), b = convert(end, to: page)
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(page.bounds(for: .cropBox))
        guard rect.width > 2, rect.height > 2 else { return }
        onRegion?(page, rect)
    }
}

private extension NSColor {
    /// Farbe, die nach `CIColorInvert` + Farbton 180° wieder (fast) sie selbst ist.
    var invertedForFilter: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let inverted = NSColor(srgbRed: 1 - c.redComponent, green: 1 - c.greenComponent, blue: 1 - c.blueComponent, alpha: 1)
        // Farbton um 180° drehen hebt die Drehung des Filters auf (Grautöne unberührt).
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        inverted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + 0.5).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
    }
}
