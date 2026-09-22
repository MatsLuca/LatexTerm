import AppKit
import WebKit
import PDFKit

/// Eine vom Nutzer gewählte Stelle auf der Seite (Textauswahl oder ⌥-Klick auf ein Element), in Dokument-Koordinaten.
struct WebMark {
    enum Kind: String { case text, element }
    var kind: Kind
    var text: String
    var selector: String
    var tag: String
    var rect: CGRect
    var lines: [CGRect] = []
    var html: String?
    var note = ""
}

/// Agenten-Seite der Web-Kachel: Rückkanal (Stellen → Session), `latexterm.send` (board), `look` (sehen) und
/// `act` (bedienen). Kern in `WebContent.swift`.
extension WebContent {

    // MARK: Nachrichten des Seitenskripts

    func pageMessage(_ body: [String: Any]) {
        switch body["kind"] as? String {
        case "selection":
            let text = body["text"] as? String ?? ""
            if text.isEmpty {
                if pendingMark?.kind == .text { pendingMark = nil; updateMarkUI(); showMarksInPage() }
                return
            }
            pendingMark = WebMark(kind: .text, text: text, selector: body["selector"] as? String ?? "",
                                  tag: body["tag"] as? String ?? "", rect: Self.rect(body["rect"]),
                                  lines: (body["lines"] as? [Any] ?? []).map(Self.rect))
            updateMarkUI()
        case "element":
            pendingMark = WebMark(kind: .element, text: body["text"] as? String ?? "", selector: body["selector"] as? String ?? "",
                                  tag: body["tag"] as? String ?? "", rect: Self.rect(body["rect"]), html: body["html"] as? String)
            updateMarkUI()
            showMarksInPage()
            root.window?.makeFirstResponder(root.markBar.note)
        case "prompt":
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            boardPrompt(text, submit: body["submit"] as? Bool ?? true)
        default:
            break
        }
    }

    private static func rect(_ any: Any?) -> CGRect {
        guard let r = any as? [String: Any] else { return .zero }
        let n = { (key: String) in (r[key] as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
    }

    // MARK: Rückkanal — Stellen merken und an die Session

    func updateMarkUI() {
        var summary: String?
        if let pending = pendingMark {
            let text = pending.text.replacingOccurrences(of: "\n", with: " ")
            let quoted = text.isEmpty ? "" : " „\(text.prefix(50))\(text.count > 50 ? "…" : "")“"
            summary = pending.kind == .element ? "<\(pending.tag)>" + quoted : String(quoted.dropFirst())
        }
        root.markBar.update(selection: summary, count: marks.count)
    }

    /// Gemerkte Stellen (nummeriert) und die aktuelle (gestrichelt) über die Seite zeichnen.
    func showMarksInPage() {
        var list: [[String: Any]] = marks.enumerated().map { index, mark in Self.json(mark, number: index + 1, pending: false) }
        if let pendingMark, pendingMark.kind == .element { list.append(Self.json(pendingMark, number: nil, pending: true)) }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        let accent = Self.css(ThemeStore.shared.accentColor)
        webView.evaluateJavaScript("window.__lt && (window.__lt.accent = '\(accent)', window.__lt.showMarks(\(String(decoding: data, as: UTF8.self))))")
    }

    private static func json(_ mark: WebMark, number: Int?, pending: Bool) -> [String: Any] {
        let box = { (r: CGRect) -> [String: Double] in ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height] }
        var entry: [String: Any] = ["kind": mark.kind.rawValue, "rect": box(mark.rect), "lines": mark.lines.map(box), "pending": pending]
        if let number { entry["n"] = number }
        return entry
    }

    func keepPending(note: String) {
        guard var mark = pendingMark else { return }
        mark.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        marks.append(mark)
        pendingMark = nil
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        showMarksInPage()
        updateMarkUI()
        root.window?.makeFirstResponder(webView)
        root.pill.flash(marks.count == 1 ? "1 Stelle gemerkt · ⇧⌘⏎ senden" : "\(marks.count) Stellen gemerkt · ⇧⌘⏎ senden", hold: 2)
    }

    func discardPending() {
        pendingMark = nil
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        showMarksInPage()
        updateMarkUI()
        root.window?.makeFirstResponder(webView)
    }

    func clearMarks() {
        marks = []
        showMarksInPage()
        updateMarkUI()
    }

    /// Alle gemerkten Stellen plus die aktuelle an eine Agenten-Kachel: je Stelle Selektor, Quellzeile, Text, Notiz und
    /// ein Ausschnitt-Bild. Enter drückt der Nutzer (er kann noch etwas dazuschreiben).
    func send(note: String, choose: Bool) {
        guard !sending else { return }
        var batch = marks
        if var current = pendingMark {
            current.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            batch.append(current)
        }
        guard !batch.isEmpty else {
            NSSound.beep()
            root.pill.flash("Erst markieren: Text auswählen oder mit ⌥ auf ein Element klicken", hold: 3)
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
            let anchor = root.markBar.frame
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.maxY + 4), in: root)
        }
    }

    private func deliver(_ batch: [WebMark], to pane: PaneInfo) {
        sending = true
        root.pill.flash("➤ bereite \(batch.count == 1 ? "Stelle" : "\(batch.count) Stellen") vor …", hold: 5)
        // Hervorhebungen weg, damit die Ausschnitte die Seite zeigen, nicht unsere Kästen.
        webView.evaluateJavaScript("window.__lt && window.__lt.showMarks([]); window.getSelection().removeAllRanges(); [scrollX, scrollY]") { [weak self] result, _ in
            guard let self else { return }
            let xy = (result as? [NSNumber]).map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) } ?? .zero
            self.crops(batch, scroll: xy, index: 0, into: []) { crops in
                let text = self.compose(batch, crops: crops)
                self.sending = false
                guard self.delegate?.contentPaste(text, intoPaneID: pane.id) == true else {
                    NSSound.beep()
                    self.showMarksInPage()
                    self.root.pill.flash("Kachel \(pane.index) nimmt nichts an", hold: 3)
                    return
                }
                self.marks = []
                self.pendingMark = nil
                self.showMarksInPage()
                self.updateMarkUI()
                self.root.pill.flash("➤ \(batch.count == 1 ? "Stelle liegt" : "\(batch.count) Stellen liegen") in Kachel \(pane.index)", hold: 2.5)
            }
        }
    }

    /// Ausschnitt je Stelle aus dem sichtbaren Bereich (Stellen außerhalb bekommen keinen), nacheinander.
    private func crops(_ batch: [WebMark], scroll: CGPoint, index: Int, into done: [URL?], finish: @escaping ([URL?]) -> Void) {
        guard index < batch.count else { finish(done); return }
        let zoom = webView.pageZoom
        let mark = batch[index]
        let area = CGRect(x: (mark.rect.minX - scroll.x) * zoom, y: (mark.rect.minY - scroll.y) * zoom,
                          width: mark.rect.width * zoom, height: mark.rect.height * zoom)
            .insetBy(dx: -12, dy: -10).intersection(webView.bounds)
        guard area.width > 4, area.height > 4 else {
            crops(batch, scroll: scroll, index: index + 1, into: done + [nil], finish: finish)
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = area
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            var url: URL?
            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = PreviewRender.scaled(cg, maxPixels: 1600) {
                url = try? AgentHandoff.writePNG(png, prefix: "Web")
            }
            self.crops(batch, scroll: scroll, index: index + 1, into: done + [url], finish: finish)
        }
    }

    private func compose(_ batch: [WebMark], crops: [URL?]) -> String {
        var head = "Aus der Web-Kachel \(pageLabel)"
        if let title = webView.title, !title.isEmpty { head += " („\(title)“)" }
        var lines = [head + ":"]
        let source = page.isFileURL && Self.isHTML(page) ? (try? String(contentsOf: page, encoding: .utf8)) : nil
        for (index, mark) in batch.enumerated() {
            var line = "\(batch.count > 1 ? "\(index + 1). " : "")"
            line += mark.kind == .element ? "Element <\(mark.tag)>" : "Text in <\(mark.tag)>"
            if !mark.selector.isEmpty { line += " `\(mark.selector)`" }
            if let source, let number = Self.sourceLine(of: mark, in: source) { line += " · \(page.lastPathComponent):\(number)" }
            let text = mark.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { line += ": „\(text.prefix(mark.kind == .text ? 600 : 200))\(text.count > (mark.kind == .text ? 600 : 200) ? "…" : "")“" }
            if !mark.note.isEmpty { line += " — \(mark.note)" }
            if index < crops.count, let crop = crops[index] { line += " · Ausschnitt: \(crop.path)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Zeile im HTML-Quelltext: über die id, sonst über den Textanfang (Leerraum zusammengezogen).
    static func sourceLine(of mark: WebMark, in source: String) -> Int? {
        let lines = source.components(separatedBy: "\n")
        if let id = mark.selector.split(separator: " ").last.flatMap({ $0.hasPrefix("#") ? String($0.dropFirst()) : nil }),
           !id.contains(":"), !id.contains(".") {
            let plain = id.replacingOccurrences(of: "\\", with: "")
            if let hit = lines.firstIndex(where: { $0.contains("id=\"\(plain)\"") || $0.contains("id='\(plain)'") }) { return hit + 1 }
        }
        let squash = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        for length in [40, 20] {
            let needle = String(squash(mark.text).prefix(length))
            guard needle.count >= 6 else { continue }
            if let hit = lines.firstIndex(where: { squash($0).contains(needle) }) { return hit + 1 }
        }
        return nil
    }

    // MARK: board — die Seite schreibt der Session

    /// `latexterm.send(text)` aus einem Klick auf einer lokalen Seite: an die Session, die die Kachel geöffnet hat.
    /// Claude: über den Briefkasten eingereicht (wartet, bis die Session ruht); sonst oder mit `submit: false` nur
    /// eingefügt. Mengenbremse, Herkunftszeile, nie aus http-Seiten.
    func boardPrompt(_ text: String, submit: Bool) {
        guard showsLocalFile else { log("warn", "latexterm.send gibt es nur für lokale Dateien"); return }
        if acting { actSends.append(text); return }
        let now = Date()
        boardTimes = boardTimes.filter { now.timeIntervalSince($0) < 60 }
        if let last = boardTimes.last, now.timeIntervalSince(last) < 1.5 || boardTimes.count >= 12 {
            log("warn", "latexterm.send gebremst (höchstens alle 1,5 s und 12 pro Minute)")
            root.pill.flash("⏸ zu viele Nachrichten an die Session", hold: 2)
            return
        }
        boardTimes.append(now)
        let prompt = "[Von der Seite \(page.lastPathComponent) in der Web-Kachel, per Klick des Nutzers]\n" + text
        let agents = delegate?.contentAgentPanes() ?? []
        let owner = delegate?.contentOpener.flatMap { opener in agents.first { $0.id.caseInsensitiveCompare(opener) == .orderedSame } }
        if let owner {
            if submit, owner.runningAgent == "claude", (try? Self.postToMailbox(prompt, pane: owner.id)) != nil {
                root.pill.flash("➤ an Kachel \(owner.index) · wird eingereicht, sobald die Session ruht", hold: 2.5)
                return
            }
            paste(prompt, into: owner)
            return
        }
        // Von Hand geöffnet: keine Eigentümer-Session — einfügen (Enter drückt der Nutzer), bei mehreren wählen.
        switch AgentHandoff.target(delegate, choose: false) {
        case .none(let reason):
            root.pill.flash("Seite will an Claude schreiben — \(reason)", hold: 3)
        case .direct(let pane):
            paste(prompt, into: pane)
        case .choose(let agents):
            let menu = AgentHandoff.menu(agents, header: "Nachricht der Seite an …", opener: nil) { [weak self] pane in
                self?.paste(prompt, into: pane)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: root.bounds.midX - 120, y: 60), in: root)
        }
    }

    private func paste(_ prompt: String, into pane: PaneInfo) {
        if delegate?.contentPaste(prompt, intoPaneID: pane.id) == true {
            root.pill.flash("➤ in Kachel \(pane.index) eingefügt — Enter drückst du dort", hold: 2.5)
        } else {
            root.pill.flash("Kachel \(pane.index) nimmt nichts an", hold: 3)
        }
    }

    /// Wie `latexterm mcp`: Punkt-Datei schreiben, dann umbenennen — der Empfänger (Mod) sieht nur fertige `*.md`.
    static func postToMailbox(_ prompt: String, pane: String) throws {
        let dir = ControlProtocol.mailboxPath(forPane: pane)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(stamp.string(from: Date()))-web.md"
        let temp = (dir as NSString).appendingPathComponent(".\(name).tmp")
        try (prompt + "\n").write(toFile: temp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(atPath: temp, toPath: (dir as NSString).appendingPathComponent(name))
    }

    // MARK: Sehen — `call look <png> [full]`

    /// Wartet, bis die Seite geladen ist und kurz geruht hat (Diagramme rendern per JS nach), dann Bild(er) + Daten.
    /// `full` = ganze Seite (über `createPDF`, in bis zu vier Streifen), sonst der sichtbare Ausschnitt.
    func look(writingTo path: String, started: Date, full: Bool, extra: [String: Any] = [:], logSince: Date? = nil) {
        if webView.isLoading, Date().timeIntervalSince(started) < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.look(writingTo: path, started: started, full: full, extra: extra, logSince: logSince)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let js = """
            JSON.stringify({x: scrollX, y: scrollY, w: innerWidth, h: innerHeight,
              sw: document.documentElement.scrollWidth, sh: document.documentElement.scrollHeight,
              text: document.body ? document.body.innerText.slice(0, 6000) : ''})
            """
            self.webView.evaluateJavaScript(js) { result, _ in
                var meta = self.state().merging(extra) { _, new in new }
                if let json = result as? String, let data = json.data(using: .utf8),
                   let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    meta["page"] = page
                }
                let entries = logSince.map { since in self.console.filter { $0.time >= since } } ?? self.console
                meta["log"] = entries.suffix(40).map { ["level": $0.level, "text": $0.text] }
                if logSince != nil { meta["logSince"] = true }
                if full { self.fullPage(path, meta: meta) } else { self.viewport(path, meta: meta) }
            }
        }
    }

    private func viewport(_ path: String, meta: [String: Any]) {
        var meta = meta
        webView.takeSnapshot(with: nil) { image, error in
            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = PreviewRender.scaled(cg, maxPixels: 1600) {
                try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
                meta["images"] = [path]
            } else {
                meta["problem"] = "kein Bild: " + (error?.localizedDescription ?? "Kachel nicht sichtbar?")
            }
            Self.writeMeta(meta, to: path + ".json")
        }
    }

    /// Ganze Seite: WebKit legt sie als PDF an (eine lange Seite), daraus Streifen im Seitenverhältnis ~1:1,3.
    private func fullPage(_ path: String, meta: [String: Any]) {
        var meta = meta
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            guard let self else { return }
            guard case .success(let data) = result, let doc = PDFDocument(data: data), doc.pageCount > 0 else {
                meta["problem"] = "ganze Seite ging nicht — sichtbarer Ausschnitt statt dessen"
                self.viewport(path, meta: meta)
                return
            }
            var paths: [String] = []
            var truncated = false
            pages: for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index) else { continue }
                let box = page.bounds(for: .cropBox)
                let tile = min(box.height, box.width * 1.3)
                let scale = min(2, 1400 / max(box.width, 1))
                var top = box.maxY
                while top > box.minY + 1 {
                    guard paths.count < 4 else { truncated = true; break pages }
                    let rect = NSRect(x: box.minX, y: max(box.minY, top - tile), width: box.width, height: min(tile, top - box.minY))
                    let target = paths.isEmpty ? path : (path as NSString).deletingPathExtension + "-\(paths.count + 1).png"
                    if let png = PreviewRender.crop(page, rect: rect, scale: scale) {
                        try? png.write(to: URL(fileURLWithPath: target), options: .atomic)
                        paths.append(target)
                    }
                    top -= tile
                }
            }
            meta["images"] = paths
            meta["full"] = true
            if truncated { meta["truncated"] = true }
            Self.writeMeta(meta, to: path + ".json")
        }
    }

    static func writeMeta(_ meta: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: Bedienen — `call act <png> <json>`

    /// Schritte in der Seite ausführen (WebActions), dann wie `look` — mit den Ergebnissen und nur der neuen Konsole.
    /// Navigiert ein Klick weg, endet das Skript mit der alten Seite; das zählt als Erfolg, geschaut wird auf die neue.
    func act(writingTo path: String, steps: [[String: Any]], look: Bool, full: Bool) {
        let started = Date()
        let startURL = webView.url
        acting = true
        actSends = []
        var finished = false
        let finish: (Any?, String?) -> Void = { [weak self] parsed, failure in
            guard let self, !finished else { return }
            finished = true
            self.acting = false
            var extra: [String: Any] = [:]
            let navigated = self.webView.url != startURL || self.webView.isLoading
            if let parsed {
                extra["act"] = parsed
            } else {
                extra["act"] = [["ok": navigated, "do": "navigation", "note": navigated ? "Seite hat gewechselt" : (failure ?? "keine Antwort")]]
            }
            if navigated { extra["navigated"] = self.webView.url?.absoluteString ?? "" }
            if !self.actSends.isEmpty { extra["sends"] = self.actSends }
            // Kurz Zeit für Reaktionen (Animationen, fetch), dann schauen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if look {
                    self.look(writingTo: path, started: Date(), full: full, extra: extra, logSince: started)
                } else {
                    var meta = self.state().merging(extra) { _, new in new }
                    meta["log"] = self.console.filter { $0.time >= started }.suffix(40).map { ["level": $0.level, "text": $0.text] }
                    meta["logSince"] = true
                    Self.writeMeta(meta, to: path + ".json")
                }
            }
        }
        webView.callAsyncJavaScript(WebActions.body, arguments: ["steps": steps], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                let parsed = (value as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                finish(parsed, nil)
            case .failure(let error):
                finish(nil, error.localizedDescription)
            }
        }
        // Wechselt die Seite mitten im Skript, meldet WebKit das Ende nie — Wächter: Seitenwechsel oder 30 s.
        func watch(_ tick: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !finished else { return }
                if self.webView.url != startURL, !self.webView.isLoading || tick > 40 { finish(nil, nil); return }
                if tick >= 120 { finish(nil, "keine Antwort nach 30 s"); return }
                watch(tick + 1)
            }
        }
        watch(0)
    }
}
