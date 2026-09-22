import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Vorschau-Kachel (Kacheln Runde 2, Platz 1 — Plan claude-werkstatt `plans/kacheln-runde-2_2026-09-22.md`):
/// ein PDF oder Bild neben der Session, eingepasst auf dem Grund des Themes, und von selbst neu geladen,
/// sobald die Datei sich ändert (`FileWatcher`) — Seite, Zoom und Ausschnitt bleiben dabei stehen. Gedacht
/// für kompilierte LaTeX-PDFs, MATLAB-/matplotlib-Plots, Renders und Screenshots. Die Datei darf beim Öffnen
/// noch fehlen: die Kachel wartet dann auf den ersten Build.
///
/// PDF: PDFKit, fortlaufend, Seitenbreite als Grundzoom, ⌘F-Suche, ⌘±/⌘0 Zoom, `dark` invertiert für die
/// Nacht. Bild: eigene Ansicht, die nie über 1:1 (Bildpixel = Bildschirmpixel) vergrößert, Doppelklick
/// wechselt zwischen eingepasst und 1:1 an der Klickstelle, Ziehen verschiebt, Pinch zoomt; transparente
/// Flächen zeigen ein dezentes Schachbrett.
final class PreviewContent: NSObject, PaneContent {
    static let kind = "preview"
    static let displayName = "PDF oder Bild in neuer Kachel …"
    static let manual = PaneKindManual(
        summary: "Zeigt ein PDF oder Bild (PNG, JPG, GIF, HEIC, TIFF, SVG …) neben der Session, eingepasst auf dunklem Grund, "
            + "und lädt es von selbst neu, sobald sich die Datei ändert — Seite und Zoom bleiben stehen, kein reload nötig. "
            + "Für kompilierte LaTeX-PDFs, Plots, Renders, Screenshots. Die Datei darf noch fehlen (die Kachel wartet auf den "
            + "ersten Build). HTML → open_web.",
        args: [PaneKindArg(name: "url", summary: "absoluter Pfad der Datei (auch ~/…)", required: true),
               PaneKindArg(name: "page", summary: "PDF: Startseite ab 1", required: false),
               PaneKindArg(name: "zoom", summary: "width (Seitenbreite, Default PDF), fit (ganz sichtbar, Default Bild) oder Prozent wie 150",
                           required: false)],
        actions: [PaneKindAction(name: "page <n>", summary: "PDF: zu Seite n springen"),
                  PaneKindAction(name: "next", summary: "PDF: nächste Seite"),
                  PaneKindAction(name: "prev", summary: "PDF: vorige Seite"),
                  PaneKindAction(name: "find <text>", summary: "PDF: Text suchen und markieren; nochmal = nächster Treffer"),
                  PaneKindAction(name: "zoom <width|fit|prozent>", summary: "Zoom setzen"),
                  PaneKindAction(name: "dark", summary: "PDF: dunkle Darstellung an/aus (invertiert, Farben bleiben erkennbar)"),
                  PaneKindAction(name: "load <pfad>", summary: "andere Datei in derselben Kachel zeigen"),
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

    enum FileType { case pdf, image }

    weak var delegate: PaneContentDelegate?
    private let root = PreviewRootView()
    private(set) var file: URL
    private var type: FileType
    private var watcher: FileWatcher?
    private var zoom: Zoom
    private var startPage: Int?
    private var dark = false
    /// Laden nach Ruhe gescheitert (PDF halb geschrieben …): so oft noch versuchen.
    private var retries = 0
    private var problem: String?
    private var pdfObservers: [NSObjectProtocol] = []
    /// Eigene Scale-Änderungen (fit, Reload) sollen den Zoom-Modus nicht auf Prozent kippen.
    private var settingScale = false
    private var findResults: [PDFSelection] = []
    private var findIndex = 0
    private var findText = ""

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["url", "page", "zoom", "dark"], kind: Self.kind)
        guard let raw = args["url"] else { throw PaneArgsError("preview braucht --arg url=/pfad/datei.pdf") }
        (file, type) = try Self.resolve(raw)
        if let raw = args["page"] {
            guard let page = Int(raw), page >= 1 else { throw PaneArgsError("preview: page muss eine Zahl ab 1 sein, bekam „\(raw)“") }
            startPage = page
        }
        if let raw = args["zoom"] {
            guard let zoom = Zoom(raw) else { throw PaneArgsError("preview: zoom = width, fit oder Prozent (5–3200), bekam „\(raw)“") }
            self.zoom = zoom
        } else {
            zoom = type == .pdf ? .width : .fit
        }
        dark = args["dark"] == "1"
        super.init()
        root.findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        root.findBar.onClose = { [weak self] in self?.closeFind() }
        root.onZoomKey = { [weak self] step in self?.zoomStep(step) }
        root.onLayout = { [weak self] in self?.refit() }
        root.image.onZoomChange = { [weak self] in self?.imageZoomChanged() }
        open(file)
    }

    /// Menü „Kachel → PDF oder Bild …“: Datei wählen. Abbrechen = nil.
    static func menuArgs() -> [String: String]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        panel.message = "PDF oder Bild für die neue Kachel"
        return panel.runModal() == .OK ? panel.url.map { ["url": $0.path] } : nil
    }

    /// Absoluter Pfad, `~/…` oder `file://…`. Die Datei darf fehlen (erster Build steht aus), ihr Ordner nicht.
    static func resolve(_ raw: String) throws -> (URL, FileType) {
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
            throw PaneArgsError("preview zeigt Dateien, keinen Ordner: \(path)")
        }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw PaneArgsError("Ordner nicht gefunden: \(url.deletingLastPathComponent().path)")
        }
        guard let type = fileType(url) else {
            let hint = ["html", "htm"].contains(url.pathExtension.lowercased()) ? " — HTML zeigt die Kachelart web" : ""
            throw PaneArgsError("preview zeigt PDF und Bilder, nicht „.\(url.pathExtension)“\(hint)")
        }
        return (url, type)
    }

    static func fileType(_ url: URL) -> FileType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    // MARK: Laden

    private func open(_ url: URL) {
        watcher?.stop()
        file = url
        closeFind()
        root.show(type)
        applyDarkFilter()
        watcher = FileWatcher(url: url) { [weak self] event in
            switch event {
            case .changed: self?.reload(announce: true)
            case .missing: self?.showProblem("\(url.lastPathComponent) fehlt — die Kachel wartet, bis sie wieder da ist.")
            }
        }
        reload(announce: false, initial: true)
    }

    /// Von der Platte lesen (ganz, nicht gemappt: latexmk überschreibt sonst unter PDFKit weg) und zeigen.
    /// Ansicht bleibt stehen; `initial` wendet Startseite und Zoom aus den Args an.
    private func reload(announce: Bool, initial: Bool = false) {
        guard let data = try? Data(contentsOf: file) else {
            showProblem(initial ? "Warte auf \(file.lastPathComponent) …" : "\(file.lastPathComponent) fehlt — die Kachel wartet, bis sie wieder da ist.",
                        waiting: initial)
            return
        }
        switch type {
        case .pdf:
            guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return loadFailed("Kein lesbares PDF (wird es gerade geschrieben?)") }
            showPDF(doc, initial: initial)
        case .image:
            guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
                return loadFailed("Bild lässt sich nicht lesen (wird es gerade geschrieben?)")
            }
            root.image.show(image, keepView: !initial, fit: zoom == .fit)
            if initial, case .percent(let p) = zoom { root.image.setZoom(p / 100) }
        }
        retries = 0
        problem = nil
        root.setMessage(nil)
        if announce { root.pill.flash("↻ neu geladen · " + Self.clock.string(from: Date())) }
        delegate?.contentStyleChanged()
    }

    private func loadFailed(_ reason: String) {
        if retries < 8 {
            retries += 1
            watcher?.retry()
        }
        // Altes Bild bleibt stehen; nur ohne Inhalt die Meldung groß zeigen.
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

    // MARK: PDF

    private var pdfView: PreviewPDFView { root.pdf }

    private func showPDF(_ doc: PDFDocument, initial: Bool) {
        if pdfObservers.isEmpty { observePDF() }
        let old = pdfView.document
        var anchor: (index: Int, point: NSPoint)?
        if !initial, let old, let dest = pdfView.currentDestination, let page = dest.page {
            anchor = (old.index(for: page), dest.point)
        }
        let scale = pdfView.scaleFactor
        settingScale = true
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
        if !findText.isEmpty { rerunFind() }
    }

    private func observePDF() {
        let center = NotificationCenter.default
        pdfObservers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.delegate?.contentStyleChanged()
            if let (page, count) = self.pageInfo { self.root.pill.flash("\(page) / \(count)") }
        })
        pdfObservers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self, !self.settingScale, !self.pdfView.autoScales else { return }
            // Pinch oder ⌘± → fester Prozentwert (bleibt beim Neuladen stehen).
            self.zoom = .percent(Double(self.pdfView.scaleFactor) * 100)
            self.delegate?.contentStyleChanged()
        })
    }

    private var pageInfo: (Int, Int)? {
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
        }
        root.pill.flash(zoomLabel)
        delegate?.contentStyleChanged()
    }

    /// ⌘+ / ⌘− / ⌘0.
    private func zoomStep(_ step: Int) {
        guard step != 0 else { return setZoom(type == .pdf ? .width : .fit) }
        let factor: CGFloat = step > 0 ? 1.25 : 0.8
        switch type {
        case .pdf: setZoom(.percent(Double(pdfView.scaleFactor * factor) * 100))
        case .image: setZoom(.percent(Double(root.image.magnification * factor) * 100))
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
    }

    private var zoomLabel: String {
        switch type {
        case .pdf: return pdfView.autoScales ? "Seitenbreite" : "\(Int((pdfView.scaleFactor * 100).rounded())) %"
        case .image: return root.image.isFitted ? "eingepasst · \(Int((root.image.magnification * 100).rounded())) %"
            : "\(Int((root.image.magnification * 100).rounded())) %"
        }
    }

    private func go(page number: Int) -> Bool {
        guard let doc = pdfView.document, number >= 1, let page = doc.page(at: min(number, doc.pageCount) - 1) else { return false }
        pdfView.go(to: page)
        return true
    }

    private func applyDarkFilter() {
        root.setDark(type == .pdf && dark)
    }

    // MARK: Suche

    private func showFind() {
        guard type == .pdf else { return }
        root.findBar.show(text: findText)
        root.window?.makeFirstResponder(root.findBar.field)
    }

    private func closeFind() {
        guard root.findBar.isVisible || !findText.isEmpty else { return }
        root.findBar.hide()
        findText = ""
        findResults = []
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        if root.window?.firstResponder === root.findBar.field.currentEditor() || root.window?.firstResponder === root.findBar.field {
            root.window?.makeFirstResponder(keyView)
        }
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

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView {
        switch type {
        case .pdf: return root.hasContent ? pdfView : root
        case .image: return root.hasContent ? root.image.canvas : root
        }
    }
    var title: String { file.lastPathComponent }
    var directory: String? { file.deletingLastPathComponent().path }

    var chip: StatusChip? {
        let tilde = (file.path as NSString).abbreviatingWithTildeInPath
        if let problem {
            return StatusChip(long: "⚠ " + problem, short: "⚠", glyph: "⚠", tone: ThemeStore.shared.theme.yellow,
                              tooltip: tilde)
        }
        guard root.hasContent else {
            return StatusChip(long: "wartet auf Datei", short: "wartet", glyph: "…", tone: ThemeStore.shared.theme.dim, tooltip: tilde)
        }
        switch type {
        case .pdf:
            guard let (page, count) = pageInfo else { return nil }
            return StatusChip(long: "S. \(page)/\(count) · \(zoomLabel)", short: "\(page)/\(count)", glyph: "\(page)",
                              tone: ThemeStore.shared.accentColor, tooltip: tilde)
        case .image:
            let px = root.image.pixelSize
            return StatusChip(long: "\(Int(px.width))×\(Int(px.height)) · \(zoomLabel)", short: "\(Int((root.image.magnification * 100).rounded())) %",
                              tone: ThemeStore.shared.accentColor, tooltip: tilde)
        }
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (verb, rest) = trimmed.firstIndex(of: " ").map {
            (String(trimmed[..<$0]).lowercased(), String(trimmed[$0...]).trimmingCharacters(in: .whitespaces))
        } ?? (trimmed.lowercased(), "")
        switch verb {
        case "reload": reload(announce: true)
        case "load":
            guard let (url, type) = try? Self.resolve(rest) else { return false }
            self.type = type
            zoom = type == .pdf ? .width : .fit
            startPage = nil
            open(url)
        case "page":
            guard type == .pdf, let number = Int(rest) else { return false }
            return go(page: number)
        case "next":
            guard type == .pdf, pdfView.canGoToNextPage else { return type == .pdf }
            pdfView.goToNextPage(nil)
        case "prev", "previous":
            guard type == .pdf, pdfView.canGoToPreviousPage else { return type == .pdf }
            pdfView.goToPreviousPage(nil)
        case "find":
            guard type == .pdf, !rest.isEmpty else { return false }
            root.findBar.show(text: rest)
            find(rest)
        case "zoom":
            guard let zoom = Zoom(rest) else { return false }
            setZoom(zoom)
        case "dark":
            guard type == .pdf else { return false }
            switch rest.lowercased() {
            case "", "toggle": dark.toggle()
            case "on", "an", "1": dark = true
            case "off", "aus", "0": dark = false
            default: return false
            }
            applyDarkFilter()
        default: return false
        }
        return true
    }

    /// `state` → JSON: Datei, Art, Seite, Zoom — für Skripte und Tests.
    func call(_ text: String) throws -> String {
        guard text.trimmingCharacters(in: .whitespaces) == "state" else { throw PaneArgsError("preview versteht nur call state") }
        var state: [String: Any] = ["file": file.path, "type": type == .pdf ? "pdf" : "image", "zoom": zoom.arg,
                                    "loaded": root.hasContent]
        if let problem { state["problem"] = problem }
        if let (page, count) = pageInfo { state["page"] = page; state["pages"] = count; state["dark"] = dark }
        if type == .image { state["pixels"] = [Int(root.image.pixelSize.width), Int(root.image.pixelSize.height)] }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func handle(_ command: PaneCommand) -> Bool {
        guard command == .find, type == .pdf else { return false }
        showFind()
        return true
    }

    func willClose() {
        watcher?.stop()
        watcher = nil
        pdfObservers.forEach(NotificationCenter.default.removeObserver)
        pdfObservers = []
        root.teardown()
    }

    /// Nach ⌥⌘R dieselbe Datei auf derselben Seite mit demselben Zoom.
    func snapshotArgs() -> [String: String]? {
        var args = ["url": file.path]
        if let (page, _) = pageInfo, page > 1 { args["page"] = String(page) }
        if zoom != (type == .pdf ? .width : .fit) { args["zoom"] = zoom.arg }
        if dark && type == .pdf { args["dark"] = "1" }
        return args
    }
}

// MARK: - Views

/// Wurzel der Vorschau: Grund in Theme-Farbe, darin PDF- oder Bildansicht, Meldung, Seiten-Pille, Suchleiste.
final class PreviewRootView: NSView {
    let pdf = PreviewPDFView()
    let image = ImagePreviewView()
    let pill = PreviewPill()
    let findBar = PreviewFindBar()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var theme = ThemeStore.shared.theme
    private var type: PreviewContent.FileType = .pdf
    /// ⌘+ = 1, ⌘− = −1, ⌘0 = 0.
    var onZoomKey: ((Int) -> Void)?
    var onLayout: (() -> Void)?

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
        for view in [pdf, image, message, pill, findBar] as [NSView] { addSubview(view) }
        pdf.isHidden = true
        image.isHidden = true
        message.isHidden = true
        findBar.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ type: PreviewContent.FileType) {
        self.type = type
        pdf.document = nil
        image.clear()
        pdf.isHidden = true
        image.isHidden = true
    }

    var hasContent: Bool {
        switch type {
        case .pdf: return pdf.document != nil
        case .image: return image.hasImage
        }
    }

    func setMessage(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        pdf.isHidden = type != .pdf || !hasContent
        image.isHidden = type != .image || !hasContent
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
        message.textColor = theme.dim
        pill.applyTheme(theme)
        findBar.applyTheme(theme)
    }

    override func layout() {
        super.layout()
        pdf.frame = bounds
        image.frame = bounds
        let width = min(bounds.width - 48, 420)
        let height = message.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        message.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        pill.layoutIn(bounds)
        findBar.layoutIn(bounds)
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.withAlphaComponent(1).setFill()
        dirtyRect.fill()
    }

    /// ⌘+ / ⌘− / ⌘0 zoomen die Vorschau statt der Terminal-Schrift, ⌘G/⇧⌘G blättern Treffer. Kachel-Kürzel
    /// verteilt vorher die Hülle; ⌘⏎ fällt durch zu ihr.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self),
              mods == .command || mods == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        switch (event.charactersIgnoringModifiers ?? "", mods == .command) {
        case ("+", _), ("=", true): onZoomKey?(1)
        case ("-", true): onZoomKey?(-1)
        case ("0", true): onZoomKey?(0)
        case ("g", true), ("G", false), ("g", false):
            guard findBar.isVisible else { return super.performKeyEquivalent(with: event) }
            findBar.onSearch?(findBar.field.stringValue, mods != .command)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func teardown() {
        pdf.document = nil
        image.clear()
    }
}

final class PreviewPDFView: PDFView {
    override var mouseDownCanMoveWindow: Bool { false }
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

/// Kurz eingeblendete Pille unten mittig: Seite, Zoom, „neu geladen“.
final class PreviewPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        alphaValue = 0
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.badgeBackground.cgColor
        layer?.borderColor = theme.faint.cgColor
        layer?.borderWidth = 0.5
        label.textColor = theme.foreground
    }

    func flash(_ text: String, hold: TimeInterval = 1.3) {
        label.stringValue = text
        if let superview { layoutIn(superview.bounds) }
        fadeWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    func layoutIn(_ bounds: NSRect) {
        let size = label.intrinsicContentSize
        let width = min(size.width + 24, bounds.width - 24)
        frame = NSRect(x: (bounds.width - width) / 2, y: 14, width: width, height: 22)
        label.frame = NSRect(x: 12, y: (22 - size.height) / 2, width: width - 24, height: size.height)
    }
}

/// Suchleiste oben rechts (⌘F): ⏎ nächster, ⇧⏎ voriger Treffer, Esc schließt.
final class PreviewFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { !isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        field.placeholderString = "Im PDF suchen"
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.delegate = self
        field.focusRingType = .none
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        addSubview(field)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.keyHelpBackground.cgColor
        layer?.borderColor = theme.faint.cgColor
        layer?.borderWidth = 0.5
        count.textColor = theme.dim
    }

    func show(text: String) {
        isHidden = false
        if !text.isEmpty { field.stringValue = text }
        if let superview { layoutIn(superview.bounds) }
    }

    func hide() {
        isHidden = true
        count.stringValue = ""
    }

    func setCount(_ text: String) { count.stringValue = text }

    func layoutIn(_ bounds: NSRect) {
        let width = min(300, bounds.width - 20)
        frame = NSRect(x: bounds.width - width - 10, y: bounds.height - 42, width: width, height: 32)
        count.frame = NSRect(x: width - 84, y: 8, width: 76, height: 16)
        field.frame = NSRect(x: 6, y: 5, width: width - 94, height: 22)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch?(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// Bildansicht: eingepasst und zentriert, nie über 1:1 (ein Bildpixel = ein Bildschirmpixel) vergrößert,
/// solange „eingepasst“ gilt. Doppelklick = 1:1 an der Klickstelle bzw. zurück, Ziehen verschiebt,
/// Pinch zoomt frei.
final class ImagePreviewView: NSScrollView {
    let canvas = ImageCanvas()
    private(set) var isFitted = true
    private(set) var pixelSize = NSSize.zero
    private var pointSize = NSSize.zero
    var onZoomChange: (() -> Void)?
    private var magnifyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 32
        drawsBackground = true
        canvas.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isFitted = false
            self.canvas.needsDisplay = true
            self.onZoomChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    var hasImage: Bool { canvas.image != nil }

    func applyTheme(_ theme: TerminalTheme) {
        backgroundColor = theme.background.withAlphaComponent(1)
        canvas.checker = (theme.background.lightened(by: 0.07), theme.background.lightened(by: 0.12))
        canvas.needsDisplay = true
    }

    func clear() {
        canvas.image = nil
        canvas.frame = .zero
    }

    /// Neues Bild; `keepView` = Zoom und Ausschnitt vom vorigen behalten (Neuladen nach Änderung).
    func show(_ image: NSImage, keepView: Bool, fit: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let bitmap = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 {
            pixelSize = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            pointSize = NSSize(width: CGFloat(bitmap.pixelsWide) / scale, height: CGFloat(bitmap.pixelsHigh) / scale)
        } else {
            // Vektor (SVG, PDF-Bild): natürliche Größe in Punkten.
            pointSize = image.size
            pixelSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let origin = contentView.bounds.origin
        let keep = keepView && hasImage && !isFitted
        canvas.image = image
        canvas.frame = NSRect(origin: .zero, size: pointSize)
        canvas.needsDisplay = true
        if keep {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        } else if fit || !keepView {
            fitToView()
        }
    }

    /// Scale, bei der das Bild ganz sichtbar ist, höchstens 1:1.
    var fitScale: CGFloat {
        guard pointSize.width > 0, pointSize.height > 0 else { return 1 }
        let available = NSSize(width: max(bounds.width - 24, 40), height: max(bounds.height - 24, 40))
        return min(1, available.width / pointSize.width, available.height / pointSize.height)
    }

    func fitToView() {
        isFitted = true
        magnification = fitScale
        canvas.needsDisplay = true
        onZoomChange?()
    }

    func setZoom(_ value: CGFloat) {
        isFitted = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(max(value, minMagnification), maxMagnification), centeredAt: center)
        canvas.needsDisplay = true
        onZoomChange?()
    }

    private func toggleZoom(at point: NSPoint) {
        guard hasImage else { return }
        if isFitted {
            isFitted = false
            let target: CGFloat = fitScale < 0.999 ? 1 : 2
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().setMagnification(target, centeredAt: point)
            }
            canvas.needsDisplay = true
            onZoomChange?()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().magnification = fitScale
            }
            isFitted = true
            canvas.needsDisplay = true
            onZoomChange?()
        }
    }

    override func layout() {
        super.layout()
        if isFitted, hasImage { magnification = fitScale }
    }
}

/// Zentriert das Dokument, solange es kleiner als der sichtbare Bereich ist.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Zeichnet das Bild über einem dezenten Schachbrett (nur unter transparenten Stellen sichtbar);
/// ab doppelter Vergrößerung pixelgenau statt weichgezeichnet.
final class ImageCanvas: NSView {
    var image: NSImage?
    var checker: (NSColor, NSColor) = (.darkGray, .gray)
    var onDoubleClick: ((NSPoint) -> Void)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let tile: CGFloat = 8
        checker.0.setFill()
        bounds.intersection(dirtyRect).fill()
        checker.1.setFill()
        let rect = bounds.intersection(dirtyRect)
        var y = floor(rect.minY / tile) * tile
        while y < rect.maxY {
            var x = floor(rect.minX / tile) * tile
            while x < rect.maxX {
                if (Int(x / tile) + Int(y / tile)) % 2 == 0 { NSRect(x: x, y: y, width: tile, height: tile).intersection(bounds).fill() }
                x += tile
            }
            y += tile
        }
        let magnification = enclosingScrollView?.magnification ?? 1
        NSGraphicsContext.current?.imageInterpolation = magnification >= 2 ? .none : .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        dragStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let scroll = enclosingScrollView else { return }
        let magnification = scroll.magnification
        let dx = (event.locationInWindow.x - dragStart.mouse.x) / magnification
        let dy = (event.locationInWindow.y - dragStart.mouse.y) / magnification
        let target = NSPoint(x: dragStart.origin.x - dx, y: dragStart.origin.y + dy)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: target, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
