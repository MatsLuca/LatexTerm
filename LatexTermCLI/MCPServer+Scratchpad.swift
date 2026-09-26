import Foundation

// Scratchpad: ansehen, zeichnen, Karten legen, anheften.

extension MCPServer {
    // MARK: - Scratchpad

    /// Ziel-Scratchpad: `pane`, sonst das von dieser Session geöffnete, das fokussierte oder das einzige.
    func scratchpad(_ a: JSON) throws -> PaneInfo {
        let pane: PaneInfo
        if a["pane"] != nil {
            pane = try target(a).0
            guard pane.kind == "scratchpad" else {
                throw ToolFailure("Kachel \(pane.index) ist kein Scratchpad (\(pane.kind ?? "terminal")).")
            }
        } else {
            let pads = try listPanes().filter { $0.kind == "scratchpad" }
            let mine = pads.filter(isMine)
            if let chosen = defaultPane(mine: mine, all: pads) {
                pane = chosen
            } else if pads.isEmpty {
                throw ToolFailure("Kein Scratchpad offen — open_scratchpad öffnet eins neben dir.")
            } else {
                throw ToolFailure("Mehrere Scratchpads offen (Kacheln \(pads.map { "\($0.index)" }.joined(separator: ", "))) — pane angeben.")
            }
        }
        return pane
    }


    func scratchLook(_ a: JSON) throws -> [JSON] {
        let pad = try scratchpad(a)
        let file = (NSTemporaryDirectory() as NSString).appendingPathComponent("latexterm-look-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: file) }
        let info = try callPane(pad, "look \(file)" + (paneID.map { " as=\($0.prefix(8))" } ?? ""))
        guard let png = FileManager.default.contents(atPath: file), !png.isEmpty else {
            throw ToolFailure("Scratchpad hat kein Bild geliefert.")
        }
        var lines = ["Scratchpad Kachel \(pad.index) (\(pad.id.prefix(8)))."]
        let grid = (info["grid"] as? Double).map { Int($0) }
        if let region = info["region"] as? JSON {
            var line = "Das Bild zeigt \(span(region))"
            if let grid { line += ", Raster alle \(grid) (am Rand beschriftet)" }
            if let ppu = info["pixelsPerUnit"] as? Double { line += String(format: ", %.2f Bildpixel je Einheit", ppu) }
            lines.append(line + ".")
        }
        if let visible = info["visible"] as? JSON {
            lines.append("In der Kachel sichtbar: \(span(visible)) — viewBox-Zeichnungen landen dort.")
        }
        for (key, who) in [("mats", "Nutzer"), ("claude", "Du")] {
            guard let layer = info[key] as? JSON else { continue }
            let count = layer["count"] as? Int ?? 0
            let noun = key == "mats" ? (count == 1 ? "Strich" : "Striche") : (count == 1 ? "Element" : "Elemente")
            var line = "\(who): \(count) \(noun)"
            if let box = layer["bounds"] as? JSON { line += " in \(span(box))" }
            lines.append(line + ".")
        }
        if let cards = info["cards"] as? [JSON], !cards.isEmpty {
            lines.append("Karten (\(cards.count); ändern/verschieben per scratch_cards mit id):")
            for card in cards {
                let who = card["author"] as? String == "claude" ? "du" : "Nutzer"
                let box = (card["bounds"] as? JSON).map(span) ?? "?"
                var meta = "\(card["id"] as? String ?? "?"), \(who), \(box), \(card["color"] as? String ?? "")"
                if let style = card["style"] as? JSON, !style.isEmpty {
                    meta += ", " + style.keys.sorted().map { "\($0)=\(style[$0]!)" }.joined(separator: " ")
                }
                let title = (card["title"] as? String).map { "**\($0)** " } ?? ""
                if let zone = card["zone"] as? [String] { meta += ", Zone um " + zone.joined(separator: ", ") }
                lines.append("- [\(meta)] " + title + ((card["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " / "))
                if let visible = card["visible"] as? String {
                    lines.append("  angeradiert, noch lesbar: " + visible.replacingOccurrences(of: "\n", with: " / "))
                }
                // Absätze einzeln (26.09.): Karten/Pfeile an einen Punkt eines langen Blocks legen, nicht nur an den Block.
                if let parts = card["parts"] as? [JSON], !parts.isEmpty, let id = card["id"] as? String {
                    for (n, part) in parts.enumerated() {
                        let text = part["text"] as? String ?? ""
                        let short = text.count > 48 ? String(text.prefix(47)) + "…" : text
                        lines.append("  \(id).\(n + 1) \((part["bounds"] as? JSON).map(span) ?? "?") „\(short)“")
                    }
                }
            }
        }
        if let links = info["links"] as? [JSON], !links.isEmpty {
            lines.append("Pfeile (eingerastet): " + links.map {
                let label = ($0["label"] as? String).flatMap { $0.isEmpty ? nil : " „\($0)“" } ?? ""
                return "\($0["from"] as? String ?? "?") → \($0["to"] as? String ?? "?")\(label)\($0["by"] as? String == "claude" ? "" : " (Nutzer)")"
            }.joined(separator: ", "))
        }
        if let images = info["images"] as? [JSON], !images.isEmpty {
            lines.append("Bilder: " + images.map { img in
                ((img["bounds"] as? JSON).map(span) ?? "?") + (img["cut"] as? Bool == true ? " (angeradiert)" : "")
            }.joined(separator: "; "))
        }
        if let order = info["order"] as? [String], order.count > 1 {
            var line = "Lesereihenfolge der Karten: " + order.joined(separator: " → ")
            if let groups = info["groups"] as? [[String]], !groups.isEmpty {
                line += " · Gruppen (nah beieinander): " + groups.map { "[" + $0.joined(separator: ", ") + "]" }.joined(separator: " ")
            }
            lines.append(line)
        }
        if let changes = info["changes"] as? JSON {
            lines.append(changes.isEmpty ? "Seit deinem letzten Blick: nichts geändert." : "Seit deinem letzten Blick:")
            func who(_ v: Any?) -> String { v as? String == "claude" ? "du" : "Nutzer" }
            let kinds = ["stroke": "Striche", "shape": "Formen", "text": "Beschriftungen", "card": "Karten"]
            for e in (changes["cardsAdded"] as? [JSON]) ?? [] {
                lines.append("- neue Karte \(e["id"] as? String ?? "?") (\(who(e["by"]))) in \((e["bounds"] as? JSON).map(span) ?? "?"): \(e["text"] as? String ?? "")")
            }
            for e in (changes["cardsRemoved"] as? [JSON]) ?? [] {
                lines.append("- Karte \(e["id"] as? String ?? "?") entfernt: \(e["text"] as? String ?? "")")
            }
            for e in (changes["moved"] as? [JSON]) ?? [] {
                let what = e["what"] as? String ?? "?"
                lines.append("- verschoben: \(kinds[what].map { "ein Element (\($0))" } ?? what) von \((e["from"] as? JSON).map(span) ?? "?") nach \((e["to"] as? JSON).map(span) ?? "?")")
            }
            for e in (changes["edited"] as? [JSON]) ?? [] {
                if e["look"] as? Bool == true { lines.append("- \(e["what"] as? String ?? "?"): Aussehen geändert") }
                else { lines.append("- \(e["what"] as? String ?? "?") Text: „\(e["before"] as? String ?? "")“ → „\(e["after"] as? String ?? "")“") }
            }
            for (key, verb) in [("added", "neu"), ("erased", "radiert")] {
                for e in (changes[key] as? [JSON]) ?? [] {
                    lines.append("- \(verb): \(e["count"] as? Int ?? 0) \(kinds[e["kind"] as? String ?? ""] ?? "Elemente") (\(who(e["by"]))) in \((e["bounds"] as? JSON).map(span) ?? "?")")
                }
            }
        }
        lines.append("Weltkoordinaten: 0,0 = Kachelmitte, y nach unten. Zeichnen mit scratch_draw (ohne viewBox in diesen Koordinaten).")
        if let rev = info["rev"] as? String {
            lines.append("Stand: rev=\(rev) — scratch_cards und scratch_draw brauchen ihn; ändert sich das Brett, erst wieder hinsehen.")
        }
        return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": lines.joined(separator: "\n")]]
    }

    func scratchDraw(_ a: JSON) throws -> String {
        guard let svg = nonEmpty(a["svg"]) else { throw ToolFailure("svg fehlt") }
        guard svg.utf8.count <= 600_000 else { throw ToolFailure("SVG zu groß (\(svg.utf8.count / 1000) KB, max 600 KB)") }
        guard let rev = nonEmpty(a["rev"]) else { throw ToolFailure("rev fehlt — erst scratch_look (liefert rev), dann zeichnen") }
        var head = "draw rev=\(rev)"
        if let replace = a["replace"] as? String {
            guard ["mats", "claude", "all"].contains(replace) else { throw ToolFailure("replace muss mats, claude oder all sein") }
            head += " replace=\(replace)"
        }
        let pad = try scratchpad(a)
        let info = try callPane(pad, head + "\n" + svg)
        let added = info["added"] as? Int ?? 0, removed = info["removed"] as? Int ?? 0
        var text = "Kachel \(pad.index): \(added) \(added == 1 ? "Element" : "Elemente") gezeichnet"
        if let box = info["bounds"] as? JSON { text += " in \(span(box))" }
        if info["fitted"] as? Bool == true { text += ", viewBox in den sichtbaren Bereich eingepasst" }
        if removed > 0 { text += "; vorher \(removed) entfernt (\(a["replace"] as? String ?? "?"))" }
        text += "."
        if let rev = info["rev"] as? String { text += " Neuer Stand rev=\(rev)." }
        if let warnings = info["warnings"] as? [String], !warnings.isEmpty {
            text += " Hinweise: " + warnings.joined(separator: "; ") + "."
        }
        return text + " Ergebnis prüfen mit scratch_look; zurücknehmen mit pane_action undo."
    }

    /// Karten setzen; gesetzt (nicht probe) hängt das Bild des Bretts danach an — das Ergebnis ansehen gehört dazu.
    func scratchCardsContent(_ a: JSON) throws -> [JSON] {
        let (text, pad, probe) = try scratchCards(a)
        guard !probe else { return [["type": "text", "text": text]] }
        var look = a
        look["pane"] = pad.id
        let image = try scratchLook(look).filter { $0["type"] as? String == "image" }
        return image + [["type": "text", "text": text + " Das Bild zeigt das Brett jetzt — prüfen, ob es aussieht wie geplant."]]
    }

    func scratchCards(_ a: JSON) throws -> (String, PaneInfo, Bool) {
        guard let cards = a["cards"] as? [JSON], !cards.isEmpty else { throw ToolFailure("cards fehlt (Liste mit {text, x, y})") }
        let probe = a["probe"] as? Bool ?? false
        var head = "cards"
        if let rev = nonEmpty(a["rev"]) { head += " rev=\(rev)" }
        else if !probe { throw ToolFailure("rev fehlt — erst scratch_look (liefert rev und zeigt, wo Platz ist), dann bewusst setzen") }
        if probe { head += " probe" }
        if let replace = a["replace"] as? String {
            guard replace == "cards" else { throw ToolFailure("replace kann nur cards sein") }
            head += " replace=cards"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cards) else { throw ToolFailure("cards ist kein JSON") }
        let pad = try scratchpad(a)
        let info = try callPane(pad, head + "\n" + String(decoding: data, as: UTF8.self))
        func list(_ key: String) -> [String] {
            ((info[key] as? [JSON]) ?? []).map { "\($0["id"] as? String ?? "?") \(($0["bounds"] as? JSON).map(span) ?? "")" }
        }
        var parts: [String] = []
        let added = list("added"), updated = list("updated"), removed = (info["removed"] as? [String]) ?? []
        if !added.isEmpty { parts.append((probe ? "würde setzen: " : "neu: ") + added.joined(separator: "; ")) }
        if !updated.isEmpty { parts.append((probe ? "würde ändern: " : "geändert: ") + updated.joined(separator: "; ")) }
        if !removed.isEmpty { parts.append((probe ? "würde entfernen: " : "entfernt: ") + removed.joined(separator: ", ")) }
        if let arrows = info["arrows"] as? [JSON], !arrows.isEmpty {
            parts.append("Pfeile: " + arrows.map { arrow in
                let points = ((arrow["points"] as? [[Double]]) ?? []).map { "\(Int($0[0])),\(Int($0[1]))" }.joined(separator: " ")
                return "\(arrow["from"] as? String ?? "?") → \(arrow["to"] as? String ?? "?") [\(points)]"
            }.joined(separator: "; "))
        }
        var text = "Kachel \(pad.index)\(probe ? " (Probe, nichts gesetzt)" : ""): " + (parts.isEmpty ? "nichts geändert" : parts.joined(separator: " · ")) + "."
        if let problems = info["problems"] as? [String], !problems.isEmpty {
            text += "\nGinge so nicht:\n- " + problems.joined(separator: "\n- ")
        } else if probe {
            text += " Keine Konflikte."
        }
        if let notes = info["notes"] as? [String], !notes.isEmpty { text += "\nHinweise:\n- " + notes.joined(separator: "\n- ") }
        if let visible = info["visible"] as? JSON { text += "\nSichtbar: \(span(visible))." }
        if !probe, let rev = info["rev"] as? String { text += " Neuer Stand rev=\(rev); zurücknehmen mit pane_action undo." }
        return (text, pad, probe)
    }

    func scratchPin(_ a: JSON) throws -> String {
        let pad = try scratchpad(a)
        let info: JSON
        if let file = nonEmpty(a["file"]) {
            info = try callPane(pad, "pin " + resolve(file) + (a["overwrite"] as? Bool == true ? " replace" : ""))
        } else {
            info = try callPane(pad, "state")
        }
        guard let pinned = info["pinned"] as? String else {
            let count = info["elements"] as? Int ?? 0
            return "Kachel \(pad.index): nicht angeheftet (\(count) Element\(count == 1 ? "" : "e")) — ⌘W würde die Zeichnung löschen. Mit file anheften."
        }
        let png = (info["png"] as? String).map { " · Bild: \(tilde($0) ?? $0)" } ?? ""
        return "Kachel \(pad.index) angeheftet: \(tilde(pinned) ?? pinned)\(png). Schließen ist jetzt verlustfrei; wieder öffnen mit open_scratchpad file."
    }


    /// pane_action clear … an ein Scratchpad: Anzahl entfernt/übrig.
    func scratchClear(_ pad: PaneInfo, who: String) throws -> String {
        let info = try callPane(pad, "clear \(who)")
        let removed = info["removed"] as? Int ?? 0
        return "Kachel \(pad.index): \(removed) entfernt, \(info["left"] as? Int ?? 0) übrig. Rückgängig mit pane_action undo."
    }

    /// „x -400…400, y -300…300“ aus {x, y, w, h}.
    func span(_ rect: JSON) -> String {
        let x = rect["x"] as? Double ?? 0, y = rect["y"] as? Double ?? 0
        let w = rect["w"] as? Double ?? 0, h = rect["h"] as? Double ?? 0
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        return "x \(n(x))…\(n(x + w)), y \(n(y))…\(n(y + h))"
    }
}
