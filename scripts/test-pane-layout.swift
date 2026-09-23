import Foundation
import CoreGraphics

/// Kachel-Layout: altes Raster exakt nachgebaut, Baum-Bereinigung, Automatik mit Begleitern,
/// Einsetzen/Entfernen im angepassten Layout, Trennlinien, Absichten samt Mats-Sperre, JSON, Kachel ziehen.
@main
struct PaneLayoutTests {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        guard !condition() else { return }
        failures += 1
        print("FAIL (Zeile \(line)): \(message)")
    }

    // MARK: Das alte Raster, 1:1 aus TerminalSplitView.relayout (vor dem Umbau) kopiert.

    static func legacyFrames(n: Int, W: CGFloat, H: CGFloat, g: CGFloat) -> [NSRect] {
        func gridRows(for n: Int, width: CGFloat, height: CGFloat) -> Int {
            guard n > 1, width > 0, height > 0 else { return 1 }
            let targetLog = log(CGFloat(0.82))
            var bestRows = 1
            var bestScore = CGFloat.greatestFiniteMagnitude
            for rows in 1...n {
                let cols = Int((Double(n) / Double(rows)).rounded(.up))
                let cellAspect = (width / CGFloat(cols)) / (height / CGFloat(rows))
                let score = abs(log(cellAspect) - targetLog)
                if score < bestScore - 1e-9 { bestScore = score; bestRows = rows }
            }
            return bestRows
        }
        let rows = gridRows(for: n, width: W, height: H)
        let base = n / rows, rem = n % rows
        let counts = (0..<rows).map { $0 < rem ? base + 1 : base }
        var frames: [NSRect] = []
        for r in 0..<rows {
            let yTop = (H * CGFloat(r) / CGFloat(rows)).rounded()
            let yBot = (H * CGFloat(r + 1) / CGFloat(rows)).rounded()
            let c = counts[r]
            for k in 0..<c {
                let xL = (W * CGFloat(k) / CGFloat(c)).rounded()
                let xR = (W * CGFloat(k + 1) / CGFloat(c)).rounded()
                let left   = xL + (k == 0 ? 0 : g / 2)
                let right  = xR - (k == c - 1 ? 0 : g / 2)
                let top    = yTop + (r == 0 ? 0 : g / 2)
                let bottom = yBot - (r == rows - 1 ? 0 : g / 2)
                frames.append(NSRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top)))
            }
        }
        return frames
    }

    static let terminal = LayoutPreference(aspect: nil, minWidth: 600, minHeight: 200, comfortWidth: 900)
    static let pdf = LayoutPreference(aspect: 0.71, minWidth: 300, minHeight: 200, comfortWidth: nil)
    static let web = LayoutPreference(aspect: nil, minWidth: 360, minHeight: 200, comfortWidth: nil)

    static func ids(_ n: Int) -> [String] { (0..<n).map { String(format: "0000000%d-AAAA-BBBB-CCCC-DDDDDDDDDDDD", $0) } }

    static func main() {
        legacyEquivalence()
        normalization()
        automaticWithCompanions()
        editing()
        dividers()
        intents()
        coding()
        tabs()
        dragging()
        if failures > 0 { print("pane-layout: \(failures) Fehler"); exit(1) }
        print("pane-layout: ok")
    }

    /// Ohne Begleiter liefert die neue Automatik Pixel für Pixel das alte Raster.
    static func legacyEquivalence() {
        let sizes: [(CGFloat, CGFloat)] = [(1512, 945), (1728, 1079), (3024, 1890), (800, 1200), (1001, 667), (1920.5, 1049.5), (500, 300)]
        for (W, H) in sizes {
            for n in 1...9 {
                let items = ids(n).map { LayoutItem(id: $0, companionOf: nil, preference: terminal) }
                guard let root = AutoLayout.build(items, width: Double(W), height: Double(H), gap: 8) else {
                    check(false, "kein Baum für n=\(n)"); continue
                }
                let slots = LayoutGeometry.layout(root, in: CGRect(x: 0, y: 0, width: W, height: H), gap: 8).slots
                let old = legacyFrames(n: n, W: W, H: H, g: 8)
                check(slots.map(\.pane) == ids(n).map { $0.uppercased() }, "Reihenfolge n=\(n) \(W)×\(H)")
                check(slots.map(\.frame) == old, "Frames n=\(n) \(W)×\(H): \(slots.map(\.frame)) vs \(old)")
            }
        }
        // Außenkanten wie im alten Relayout: oberste Reihe oben, unterste unten.
        let root = AutoLayout.build(ids(5).map { LayoutItem(id: $0, companionOf: nil, preference: terminal) },
                                    width: 1512, height: 945, gap: 8)!
        let slots = LayoutGeometry.layout(root, in: CGRect(x: 0, y: 0, width: 1512, height: 945), gap: 8).slots
        check(slots.filter { $0.outer.contains(.top) }.count == 3 && slots.filter { $0.outer.contains(.bottom) }.count == 2,
              "Außenkanten 5er-Raster")
    }

    static func normalization() {
        let a = "a", b = "b", c = "c"
        // Teilung mit einem Kind löst sich auf, das Kind erbt den Anteil.
        var n = LayoutNode.split(.row, [.split(.column, [.leaf(a)], weight: 3), .leaf(b)]).normalized()!
        check(n.children.count == 2 && n.children[0].pane == "A" && n.children[0].weight == 3, "Ein-Kind-Teilung")
        // Gleiche Richtung bleibt verschachtelt (Block), Anteile bleiben.
        n = LayoutNode.split(.row, [.leaf(a, weight: 1), .split(.row, [.leaf(b), .leaf(c, weight: 3)], weight: 2, setBy: .mats)]).normalized()!
        check(n.children.count == 2 && n.children[1].children.map(\.weight) == [1, 3] && n.children[1].setBy == .mats, "Block bleibt")
        // Unbekannte Kacheln, doppelte, kaputte Gewichte.
        n = LayoutNode.split(.column, [.leaf(a, weight: .nan), .leaf(a), .leaf("x"), .leaf(b, weight: -2)]).normalized(keeping: [a, b])!
        check(n.paneIDs == ["A", "B"] && n.children.allSatisfy { $0.weight == 1 }, "Aufräumen \(n)")
        check(LayoutNode.leaf(a).normalized(keeping: [b]) == nil, "nichts übrig")
    }

    static func automaticWithCompanions() {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let claude = "11111111-0000-0000-0000-000000000000", preview = "22222222-0000-0000-0000-000000000000"
        let webID = "33333333-0000-0000-0000-000000000000", pad = "44444444-0000-0000-0000-000000000000"
        let other = "55555555-0000-0000-0000-000000000000"

        // Eine Session + Vorschau: Session links, Vorschau rechts, Session behält ihre Mindestbreite.
        var items = [LayoutItem(id: claude, companionOf: nil, preference: terminal),
                     LayoutItem(id: preview, companionOf: claude, preference: pdf)]
        var root = AutoLayout.build(items, width: 1728, height: 1079, gap: 8)!
        var slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        check(slots.map(\.pane) == [claude, preview], "Reihenfolge Session | Vorschau")
        check(slots[0].frame.width >= 600 && slots[1].frame.minX > slots[0].frame.minX, "Session links, breit genug")
        check(slots[1].frame.height == 1079, "Vorschau volle Höhe")
        let aspect = slots[1].frame.width / slots[1].frame.height
        check(aspect > 0.4 && aspect < 0.8, "Vorschau hochkant (\(aspect))")

        // Vier Begleiter: die Session wird nicht halbiert, die Nebenspalte wächst nach unten.
        items += [LayoutItem(id: webID, companionOf: claude, preference: web),
                  LayoutItem(id: pad, companionOf: preview, preference: .flexible)]   // Begleiter eines Begleiters
        root = AutoLayout.build(items, width: 1728, height: 1079, gap: 8)!
        slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        let session = slots.first { $0.pane == claude }!
        check(session.frame.width >= 600 && session.frame.height == 1079, "Session bleibt ganze Höhe, ≥ Mindestbreite")
        let column = slots.filter { $0.pane != claude }
        check(Set(column.map { $0.frame.minX }).count == 1, "Begleiter in einer Spalte")
        check(column.map(\.pane) == [preview, webID, pad], "Begleiter in Öffnungsreihenfolge")
        // Live-Befund 23.09.: drei Begleiter dürfen die Spalte nicht schmaler machen als einer.
        let narrow = LayoutPreference(aspect: nil, minWidth: 740, minHeight: 200, comfortWidth: 980)
        let one = AutoLayout.build([LayoutItem(id: claude, companionOf: nil, preference: narrow),
                                    LayoutItem(id: preview, companionOf: claude, preference: pdf)], width: 1512, height: 880, gap: 8)!
        let three = AutoLayout.build([LayoutItem(id: claude, companionOf: nil, preference: narrow),
                                      LayoutItem(id: preview, companionOf: claude, preference: pdf),
                                      LayoutItem(id: webID, companionOf: claude, preference: web),
                                      LayoutItem(id: pad, companionOf: claude, preference: .flexible)], width: 1512, height: 880, gap: 8)!
        let small = CGRect(x: 0, y: 0, width: 1512, height: 880)
        let w1 = LayoutGeometry.rect(of: preview, in: one, bounds: small)!.width
        let w3 = LayoutGeometry.rect(of: preview, in: three, bounds: small)!.width
        check(w3 >= w1 && w3 >= 1512 * 0.38 && LayoutGeometry.rect(of: claude, in: three, bounds: small)!.width >= 740,
              "drei Begleiter: Spalte \(w3) (einer: \(w1)), Session ≥ Minimum")

        // Deterministisch.
        check(AutoLayout.build(items, width: 1728, height: 1079, gap: 8) == root, "deterministisch")

        // Zwei Sessions, eine mit Vorschau: jede bleibt ein Block, die mit Begleiter bekommt mehr Platz.
        items = [LayoutItem(id: claude, companionOf: nil, preference: terminal),
                 LayoutItem(id: preview, companionOf: claude, preference: pdf),
                 LayoutItem(id: other, companionOf: nil, preference: terminal)]
        root = AutoLayout.build(items, width: 3024, height: 1890, gap: 8)!
        slots = LayoutGeometry.layout(root, in: CGRect(x: 0, y: 0, width: 3024, height: 1890), gap: 8).slots
        check(slots.map(\.pane) == [claude, preview, other], "Blöcke nebeneinander (breiter Schirm)")
        // Zu schmal für nebeneinander: Blöcke in Reihen.
        root = AutoLayout.build(items, width: 1100, height: 1079, gap: 8)!
        slots = LayoutGeometry.layout(root, in: CGRect(x: 0, y: 0, width: 1100, height: 1079), gap: 8).slots
        check(slots.first { $0.pane == other }!.frame.minY > 0, "schmal: zweite Session in eigener Reihe")

        // Fehlender Anker und Kreise machen eine Kachel eigenständig.
        let anchors = AutoLayout.anchors(of: [LayoutItem(id: "a", companionOf: "b", preference: .flexible),
                                              LayoutItem(id: "b", companionOf: "a", preference: .flexible),
                                              LayoutItem(id: "c", companionOf: "weg", preference: .flexible)])
        check(anchors["A"] == "A" && anchors["B"] == "B" && anchors["C"] == "C", "Kreis/fehlend → eigenständig \(anchors)")
    }

    static func editing() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let a = "A", b = "B", p1 = "P1", p2 = "P2", t = "T"
        var root = LayoutNode.split(.row, [.leaf(a), .leaf(b)], setBy: .mats)

        // Erster Begleiter: teilt nur den Platz seiner Kachel, Mats' Aufteilung bleibt.
        root = LayoutEdit.insert(p1, companionOf: a, anchorCompanions: [], focusBlock: [], preference: pdf,
                                 anchorPreference: terminal, into: root, bounds: bounds, gap: 8)
        var slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        check(root.paneIDs == [a, p1, b], "Begleiter direkt rechts neben seiner Kachel: \(root.paneIDs)")
        check(abs(slots.first { $0.pane == b }!.rect.width - 800) < 1, "B unverändert halb")
        check(root.setBy == .mats, "Sperre bleibt nach Einsetzen")

        // Zweiter Begleiter: in dieselbe Nebenspalte, untereinander.
        root = LayoutEdit.insert(p2, companionOf: a, anchorCompanions: [p1], focusBlock: [], preference: web,
                                 anchorPreference: terminal, into: root, bounds: bounds, gap: 8)
        slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        let s1 = slots.first { $0.pane == p1 }!, s2 = slots.first { $0.pane == p2 }!
        check(s1.rect.minX == s2.rect.minX && s2.rect.minY > s1.rect.minY, "zweiter Begleiter unter dem ersten")
        check(abs(slots.first { $0.pane == a }!.rect.width - LayoutGeometry.rect(of: a, in: root, bounds: bounds)!.width) < 0.1, "A konsistent")

        // Eigenständige Kachel mit Fokus auf A: teilt den Block aus A und Begleitern, nicht nur A.
        root = LayoutEdit.insert(t, companionOf: nil, anchorCompanions: [], focusBlock: [a, p1, p2], preference: terminal,
                                 anchorPreference: terminal, into: root, bounds: bounds, gap: 8)
        check(root.paneIDs == [a, p1, p2, t, b], "neue Kachel hinter dem Block: \(root.paneIDs)")
        check(LayoutEdit.subtree(exactly: [a, p1, p2], in: root) != nil, "Block bleibt zusammen")

        // Doppelt einsetzen ist ein No-op; Entfernen hält das Verhältnis der anderen.
        check(LayoutEdit.insert(t, companionOf: nil, anchorCompanions: [], focusBlock: [], preference: terminal,
                                anchorPreference: terminal, into: root, bounds: bounds, gap: 8) == root, "doppelt")
        let before = LayoutGeometry.layout(root, in: bounds, gap: 8).slots.first { $0.pane == b }!.rect.width
        root = LayoutEdit.remove(t, from: root)!
        let after = LayoutGeometry.layout(root, in: bounds, gap: 8).slots.first { $0.pane == b }!.rect.width
        check(abs(before - after) < 1, "B unberührt vom Entfernen (\(before) → \(after))")
        root = LayoutEdit.remove(p2, from: root)!
        root = LayoutEdit.remove(p1, from: root)!
        check(root.paneIDs == [a, b] && root.setBy == .mats, "zurück zu A|B mit Sperre")
        check(LayoutEdit.remove(a, from: .leaf(a)) == nil, "letzte Kachel")
    }

    static func dividers() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        var root = LayoutNode.split(.row, [.leaf("A"), .split(.column, [.leaf("B"), .leaf("C")])])
        let lines = LayoutGeometry.layout(root, in: bounds, gap: 8).dividers
        check(lines.count == 2, "zwei Trennlinien")
        let vertical = lines.first { $0.axis == .row }!
        check(vertical.start == 0 && vertical.end == 1000 && abs(vertical.rect.midX - 500) < 0.1, "senkrechte Linie mittig")
        root = LayoutEdit.dragged(root, divider: vertical, to: 300, minimum: 80, actor: .mats)
        var slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        check(slots.first { $0.pane == "A" }!.rect.width == 300 && root.setBy == .mats, "gezogen auf 300, gesperrt")
        // Grenzen: nie unter das Minimum.
        root = LayoutEdit.dragged(root, divider: vertical, to: 5, minimum: 80, actor: .mats)
        slots = LayoutGeometry.layout(root, in: bounds, gap: 8).slots
        check(slots.first { $0.pane == "A" }!.rect.width == 80, "Minimum gehalten")
        let horizontal = LayoutGeometry.layout(root, in: bounds, gap: 8).dividers.first { $0.axis == .column }!
        check(horizontal.path == [1] && horizontal.start == 0 && horizontal.end == 600, "waagrechte Linie in der Spalte")
        root = LayoutEdit.equalized(root, divider: LayoutGeometry.layout(root, in: bounds, gap: 8).dividers.first { $0.axis == .row }!, actor: .mats)
        check(LayoutGeometry.layout(root, in: bounds, gap: 8).slots.first { $0.pane == "A" }!.rect.width == 500, "Doppelklick gleich")
    }

    static func intents() {
        let root = LayoutNode.split(.row, [.leaf("A"), .split(.column, [.leaf("B"), .leaf("C")])])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        func rect(_ id: String, _ node: LayoutNode) -> CGRect { LayoutGeometry.rect(of: id, in: node, bounds: bounds)! }

        var r = try! LayoutEdit.apply(.big("B"), to: root, actor: .agent, overrideMats: false)
        check(rect("B", r).width > 600 && rect("B", r).height > 380 && r.setBy == .agent, "B groß")
        r = try! LayoutEdit.apply(.grow("A"), to: root, actor: .agent, overrideMats: false)
        check(abs(rect("A", r).width - 620) < 1, "A größer um 12 % (\(rect("A", r).width))")
        r = try! LayoutEdit.apply(.shrink("A"), to: root, actor: .agent, overrideMats: false)
        check(abs(rect("A", r).width - 380) < 1, "A kleiner")
        r = try! LayoutEdit.apply(.beside("A", "C"), to: root, actor: .agent, overrideMats: false)
        check(r.paneIDs == ["A", "C", "B"] && rect("C", r).minY == 0 && rect("B", r).height == 600, "C neben A: \(r.paneIDs)")
        r = try! LayoutEdit.apply(.below("A", "B"), to: root, actor: .agent, overrideMats: false)
        check(rect("B", r).minX == 0 && rect("B", r).minY > 0, "B unter A")
        r = try! LayoutEdit.apply(.swap("A", "C"), to: root, actor: .agent, overrideMats: false)
        check(r.paneIDs == ["C", "B", "A"], "tauschen")

        // Mats' Aufteilung ist für Agenten gesperrt — außer auf Auftrag. Tauschen ändert keine Anteile.
        var locked = root
        locked.setBy = .mats
        for op in [LayoutOp.big("B"), .grow("A"), .shrink("A")] {
            do { _ = try LayoutEdit.apply(op, to: locked, actor: .agent, overrideMats: false); check(false, "\(op) hätte abgelehnt werden müssen") }
            catch { check("\(error)".contains("Mats"), "Grund nennt Mats") }
            check((try? LayoutEdit.apply(op, to: locked, actor: .agent, overrideMats: true)) != nil, "\(op) auf Auftrag")
        }
        var inner = root
        inner.children[1].setBy = .mats
        do { _ = try LayoutEdit.apply(.beside("A", "C"), to: inner, actor: .agent, overrideMats: false); check(false, "C aus Mats-Spalte") }
        catch {}
        check((try? LayoutEdit.apply(.swap("A", "B"), to: locked, actor: .agent, overrideMats: false)) != nil, "Tauschen erlaubt")
        do { _ = try LayoutEdit.apply(.grow("A"), to: .leaf("A"), actor: .agent, overrideMats: false); check(false, "eine Kachel") }
        catch {}
        do { _ = try LayoutEdit.apply(.big("X"), to: root, actor: .agent, overrideMats: false); check(false, "unbekannt") }
        catch {}
    }

    static func coding() {
        let root = LayoutNode.split(.row, [.leaf("a", weight: 0.6), .split(.column, [.leaf("b"), .leaf("c")], weight: 0.4, setBy: .mats)])
        let data = try! JSONEncoder().encode(root)
        let back = try! JSONDecoder().decode(LayoutNode.self, from: data)
        check(back == root, "JSON hin und zurück")
        // Nachsichtig beim Lesen: fehlende Gewichte, unbekannte Achse/Sperre.
        let loose = #"{"axis":"quer","setBy":"jemand","children":[{"pane":"a"},{"pane":"b","weight":2}]}"#
        let node = try! JSONDecoder().decode(LayoutNode.self, from: Data(loose.utf8)).normalized()!
        check(node.axis == .row && node.setBy == nil && node.children.map(\.weight) == [1, 2], "nachsichtig: \(node)")
    }
    /// Reiter (Stufe 2): mehrere Kacheln an einem Platz, eine vorn.
    static func tabs() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        // Modell: Reihenfolge, vordere, Bereinigung, JSON.
        let g = LayoutNode.group(["b", "c", "d"], front: "c")
        check(g.isGroup && g.pane == "C" && g.members == ["B", "C", "D"], "Gruppe: \(g)")
        check(LayoutNode.group(["x"]) == .leaf("X"), "eine Kachel = Blatt")
        let root = LayoutNode.split(.row, [.leaf("A"), g])
        check(root.paneIDs == ["A", "B", "C", "D"] && root.hiddenPaneIDs == ["B", "D"], "Lesereihenfolge mit Reitern")
        check(root.normalized(keeping: ["A", "B", "D"])!.children[1] == .group(["B", "D"], front: "D"), "vordere weg → rechter Nachbar vor")
        check(root.normalized(keeping: ["A", "D"])!.children[1] == .leaf("D"), "ein Reiter übrig → Blatt")
        check(LayoutNode.split(.row, [.group(["a", "b"]), .leaf("b")]).normalized()!.paneIDs == ["A", "B"], "doppelte Kachel einmal")
        let back = try! JSONDecoder().decode(LayoutNode.self, from: JSONEncoder().encode(root))
        check(back == root, "JSON mit Reitern")
        check(!String(decoding: try! JSONEncoder().encode(LayoutNode.leaf("a")), as: UTF8.self).contains("tabs"), "Blatt ohne tabs im JSON")
        check(root.withFront { $0 == "D" ? 5 : 0 }.children[1].pane == "D", "zuletzt gezeigte vorn")
        check(root.withFront { _ in 0 }.children[1].pane == "C", "Gleichstand: bisherige bleibt")
        check(root.mappingPanes { $0 == "C" ? nil : $0.lowercased() }!.paneIDs == ["A", "B", "D"], "Umschreiben ohne C")

        // Geometrie: Leiste oben, alle Reiter im selben Frame darunter, hintere verborgen.
        let out = LayoutGeometry.layout(root, in: bounds, gap: 8, tabBarHeight: 28)
        check(out.tabBars.count == 1 && out.tabBars[0].tabs == ["B", "C", "D"] && out.tabBars[0].front == "C", "eine Leiste")
        let bar = out.tabBars[0].rect
        let members = out.slots.filter { ["B", "C", "D"].contains($0.pane) }
        check(Set(members.map(\.frame)).count == 1, "gleicher Frame für alle Reiter")
        check(members.first!.frame.minY == bar.maxY && bar.minY == 0 && bar.height == 28 && members.first!.frame.minX == bar.minX, "Leiste über dem Inhalt")
        check(members.filter { !$0.hidden }.map(\.pane) == ["C"], "nur die vordere sichtbar")
        check(!members.first!.outer.contains(.top), "Inhalt unter der Leiste liegt nicht am Fensterrand")
        check(LayoutGeometry.layout(root, in: bounds, gap: 8).slots.first { $0.pane == "C" }!.frame.minY == 0, "ohne Leistenhöhe wie früher")

        // Automatik: höchstens drei Plätze in der Nebenspalte, der Rest als Reiter auf dem letzten.
        let terminal = LayoutPreference(aspect: nil, minWidth: 480, minHeight: 200, comfortWidth: 640)
        var items = [LayoutItem(id: "S", companionOf: nil, preference: terminal)]
        for id in ["P1", "P2", "P3"] { items.append(LayoutItem(id: id, companionOf: "S", preference: .flexible)) }
        var auto = AutoLayout.build(items, width: 1512, height: 880, gap: 8)!
        check(auto.hiddenPaneIDs.isEmpty && auto.paneIDs == ["S", "P1", "P2", "P3"], "drei Begleiter: drei Plätze")
        items += [LayoutItem(id: "P4", companionOf: "S", preference: .flexible), LayoutItem(id: "P5", companionOf: "S", preference: .flexible)]
        auto = AutoLayout.build(items, width: 1512, height: 880, gap: 8)!
        let column = auto.children[1]
        check(column.axis == .column && column.children.count == 3, "fünf Begleiter: weiter drei Plätze")
        check(column.children[2].members == ["P3", "P4", "P5"], "Rest als Reiter auf dem letzten Platz: \(column.children[2].members)")
        let places = LayoutGeometry.layout(auto, in: CGRect(x: 0, y: 0, width: 1512, height: 880), gap: 8, tabBarHeight: 28).slots
        check(places.filter { !$0.hidden }.allSatisfy { $0.frame.height > 200 }, "kein Platz zu flach")
        check(AutoLayout.companionPlaces(["a", "b"]) == [["a"], ["b"]], "wenige Begleiter einzeln")

        // Angepasst: Spalte voll → neuer Begleiter als Reiter; Entfernen lässt den Platz stehen.
        var manual = AutoLayout.build(Array(items.prefix(4)), width: 1512, height: 880, gap: 8)!
        manual.setBy = .mats
        manual = LayoutEdit.insert("P4", companionOf: "S", anchorCompanions: ["P1", "P2", "P3"], focusBlock: [],
                                   preference: .flexible, anchorPreference: terminal, into: manual,
                                   bounds: CGRect(x: 0, y: 0, width: 1512, height: 880), gap: 8)
        check(manual.children[1].children.count == 3 && manual.children[1].children[2].members == ["P3", "P4"], "Einsetzen als Reiter: \(manual)")
        check(manual.setBy == .mats, "Sperre bleibt")
        let fewer = LayoutEdit.remove("P3", from: manual)!
        check(fewer.children[1].children[2] == .leaf("P4", weight: manual.children[1].children[2].weight), "Reiter weg, Platz bleibt")
        let single = LayoutEdit.insert("Q", companionOf: "S", anchorCompanions: ["P1", "P2"], focusBlock: [], preference: .flexible,
                                       anchorPreference: terminal,
                                       into: .split(.row, [.leaf("S"), .group(["P1", "P2"])]), bounds: bounds, gap: 8)
        check(single.children[1].axis == .column && single.children[1].children.map(\.members) == [["P1", "P2"], ["Q"]], "Platz frei → neuer Platz unter den Reitern")

        // Absichten: als Reiter anlegen, herauslösen, tauschen über Reiter hinweg.
        let flat = LayoutNode.split(.row, [.leaf("A"), .split(.column, [.leaf("B"), .leaf("C")])])
        var r = try! LayoutEdit.apply(.tab("C", into: "B"), to: flat, actor: .agent, overrideMats: false)
        check(r == .split(.row, [.leaf("A"), .group(["B", "C"])]), "C als Reiter hinter B: \(r)")
        check(try! LayoutEdit.apply(.tab("C", into: "B"), to: r, actor: .agent, overrideMats: false) == r, "schon Reiter: nichts")
        let out2 = try! LayoutEdit.apply(.beside("B", "C"), to: r, actor: .agent, overrideMats: false)
        check(out2.paneIDs == ["A", "B", "C"] && out2.hiddenPaneIDs.isEmpty, "herauslösen: \(out2)")
        r = try! LayoutEdit.apply(.swap("A", "C"), to: r, actor: .agent, overrideMats: false)
        check(r == .split(.row, [.leaf("C"), .group(["B", "A"])]), "tauschen mit Reiter: \(r)")
        var locked = LayoutNode.split(.row, [.leaf("A"), .group(["B", "C"])], setBy: .mats)
        check((try? LayoutEdit.apply(.beside("A", "C"), to: locked, actor: .agent, overrideMats: false)) != nil,
              "Reiter lösen ändert keine gesperrte Teilung")
        locked = .split(.row, [.leaf("A"), .leaf("B"), .leaf("C")], setBy: .mats)
        do { _ = try LayoutEdit.apply(.tab("C", into: "B"), to: locked, actor: .agent, overrideMats: false); check(false, "Reiter aus Mats-Teilung") }
        catch { check("\(error)".contains("Mats"), "Grund nennt Mats") }
        check(LayoutGeometry.rect(of: "C", in: r, bounds: bounds) != nil && LayoutGeometry.rect(of: "A", in: r, bounds: bounds) == LayoutGeometry.rect(of: "B", in: r, bounds: bounds), "Reiter teilen den Platz")
    }

    /// Kachel ziehen (Stufe 2, Scheibe B): Zonen, Verschieben an Seiten, als Reiter, Fensterrand, No-ops.
    static func dragging() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        func rect(_ id: String, _ node: LayoutNode) -> CGRect { LayoutGeometry.rect(of: id, in: node, bounds: bounds)! }
        func move(_ id: String, _ target: LayoutDropTarget, _ root: LayoutNode) -> LayoutNode? {
            LayoutEdit.moved(id, to: target, in: root, actor: .mats)
        }

        // Zonen: Mitte = innere Hälfte, Rand nach der nächsten Kante, außerhalb nichts.
        let r = CGRect(x: 100, y: 100, width: 400, height: 200)
        check(LayoutDrop.zone(at: CGPoint(x: 300, y: 200), in: r) == .center, "Mitte")
        check(LayoutDrop.zone(at: CGPoint(x: 110, y: 200), in: r) == .left, "links")
        check(LayoutDrop.zone(at: CGPoint(x: 490, y: 200), in: r) == .right, "rechts")
        check(LayoutDrop.zone(at: CGPoint(x: 300, y: 105), in: r) == .top, "oben")
        check(LayoutDrop.zone(at: CGPoint(x: 300, y: 295), in: r) == .bottom, "unten")
        check(LayoutDrop.zone(at: CGPoint(x: 150, y: 105), in: r) == .top, "Ecke: relativ nähere Kante gewinnt")
        check(LayoutDrop.zone(at: CGPoint(x: 50, y: 50), in: r) == nil, "außerhalb")
        check(LayoutDrop.zone(at: CGPoint(x: 1, y: 1), in: .zero) == nil, "leerer Platz")
        check(LayoutDrop.windowZone(at: CGPoint(x: 5, y: 300), in: bounds, band: 14) == .left, "Fensterrand links")
        check(LayoutDrop.windowZone(at: CGPoint(x: 500, y: 595), in: bounds, band: 14) == .bottom, "Fensterrand unten")
        check(LayoutDrop.windowZone(at: CGPoint(x: 500, y: 300), in: bounds, band: 14) == nil, "innen kein Rand")
        check(LayoutDrop.windowZone(at: CGPoint(x: -3, y: 300), in: bounds, band: 14) == nil, "außerhalb des Fensters")

        let root = LayoutNode.split(.row, [.leaf("A"), .split(.column, [.leaf("B"), .leaf("C")])])

        // Seiten: halbiert den Zielplatz, der alte Platz fällt an die Nachbarn.
        var m = move("C", .place("A", .left), root)!
        check(m.paneIDs == ["C", "A", "B"] && rect("C", m).width == 250 && rect("C", m).height == 600, "C links neben A: \(m.paneIDs)")
        check(rect("B", m) == CGRect(x: 500, y: 0, width: 500, height: 600), "B erbt den Platz von C")
        check(m.children[0].setBy == .mats, "neue Teilung gehört Mats")
        m = move("A", .place("C", .bottom), root)!
        check(rect("A", m).minY == 450 && rect("A", m).width == 1000 && rect("B", m).height == 300, "A unter C, Spalte wird volle Breite: \(m)")
        m = move("B", .place("A", .top), root)!
        check(rect("B", m) == CGRect(x: 0, y: 0, width: 500, height: 300) && rect("C", m).height == 600, "B über A")
        m = move("A", .place("B", .right), root)!
        check(m.paneIDs == ["B", "A", "C"] && rect("A", m).minX == 500, "A rechts neben B")

        // Mitte: als Reiter, vorn; auf sich selbst nichts.
        m = move("A", .place("B", .center), root)!
        check(m == .split(.column, [.group(["B", "A"], front: "A", setBy: .mats), .leaf("C")]), "A als Reiter zu B, vorn: \(m)")
        check(move("A", .place("A", .center), root) == nil && move("A", .place("A", .left), root) == nil, "auf sich selbst: nichts")
        check(move("X", .place("A", .left), root) == nil && move("A", .place("X", .left), root) == nil, "unbekannt: nichts")
        check(move("A", .place("A", .left), .leaf("A")) == nil && move("A", .window(.left), .leaf("A")) == nil, "einzige Kachel")

        // Reiter herauslösen: an die Seite des eigenen Platzes, der Rest bleibt Reiter.
        let grouped = LayoutNode.split(.row, [.leaf("A"), .group(["B", "C", "D"], front: "C")])
        m = move("C", .place("C", .bottom), grouped)!
        check(m.children[1] == .split(.column, [.group(["B", "D"], front: "D"), .leaf("C")], setBy: .mats), "C unter die übrigen Reiter: \(m)")
        m = move("B", .place("D", .left), grouped)!
        check(m.children[1].axis == .row && m.children[1].children[0] == .leaf("B"), "B links neben den eigenen Platz")
        check(move("C", .place("C", .center), grouped) == nil, "Reiter in die eigene Mitte: nichts")
        m = move("A", .place("C", .right), grouped)!
        check(m == .split(.row, [.group(["B", "C", "D"], front: "C"), .leaf("A")], setBy: .mats), "neben einen Reiter-Platz: Gruppe bleibt ganz: \(m)")
        m = move("C", .place("A", .center), grouped)!
        check(m == .split(.row, [.group(["A", "C"], front: "C", setBy: .mats), .group(["B", "D"], front: "D")]), "Reiter zu anderem Platz")
        m = move("B", .place("A", .left), move("D", .place("A", .left), move("C", .place("A", .left), grouped)!)!)!
        check(!m.paneIDs.isEmpty && m.hiddenPaneIDs.isEmpty && Set(m.paneIDs) == ["A", "B", "C", "D"], "alle Reiter herausgelöst: \(m)")

        // Reiterleiste: einfügen an Position, umsortieren im eigenen Platz.
        m = move("A", .tabBar("B", index: 1), grouped)!
        check(m == .group(["B", "A", "C", "D"], front: "A", setBy: .mats), "A an Position 2 der Leiste: \(m)")
        m = move("A", .tabBar("D", index: 99), grouped)!
        check(m.members == ["B", "C", "D", "A"], "Position hinter dem Ende = ans Ende")
        m = move("B", .tabBar("B", index: 3), grouped)!
        check(m.children[1].members == ["C", "D", "B"] && m.children[1].pane == "B", "B ans Ende umsortiert, vorn: \(m)")
        m = move("D", .tabBar("B", index: 0), grouped)!
        check(m.children[1].members == ["D", "B", "C"], "D nach vorn umsortiert")
        check(move("B", .tabBar("B", index: 0), grouped) == nil && move("B", .tabBar("B", index: 1), grouped) == nil, "an eigener Stelle: nichts")
        m = move("A", .tabBar("A", index: 0), root) ?? root
        check(m == root, "Leiste der eigenen einzelnen Kachel: nichts")

        // Fensterrand: ganze Höhe/Breite, ein Teil wie ein weiteres Kind; der Rest bleibt ein Block.
        m = move("C", .window(.right), root)!
        check(rect("C", m) == CGRect(x: 667, y: 0, width: 333, height: 600) && rect("B", m).height == 600, "C als Spalte rechts: \(rect("C", m))")
        m = move("A", .window(.bottom), root)!
        check(rect("A", m) == CGRect(x: 0, y: 400, width: 1000, height: 200), "A als Zeile unten: \(rect("A", m))")
        let three = LayoutNode.split(.row, [.leaf("A"), .leaf("B"), .leaf("C"), .leaf("D")])
        m = move("D", .window(.left), three)!
        check(rect("D", m).width == 250 && m.paneIDs == ["D", "A", "B", "C"], "drei Spalten + eine: ein Viertel")
        check(move("A", .window(.center), root) == nil, "Fenstermitte gibt es nicht")

        // Von Mats gezogene Reiter tragen ✋: überleben Bereinigen, Entfernen und JSON; Agenten nur auf Auftrag.
        let matsTabs = move("C", .place("B", .center), root)!
        check(matsTabs.containsMatsLock, "Reiter von Mats gesperrt")
        check(matsTabs.normalized() == matsTabs, "Bereinigen behält ✋")
        check(try! JSONDecoder().decode(LayoutNode.self, from: JSONEncoder().encode(matsTabs)) == matsTabs, "JSON behält ✋")
        let three2 = move("A", .place("B", .center), matsTabs)!
        check(LayoutEdit.remove("A", from: three2)!.containsMatsLock, "Entfernen eines Reiters behält ✋")
        check(!(LayoutEdit.remove("C", from: matsTabs)!.containsMatsLock), "ein Reiter übrig: Blatt ohne ✋")
        do { _ = try LayoutEdit.apply(.beside("A", "C"), to: three2, actor: .agent, overrideMats: false); check(false, "aus Mats' Reitern") }
        catch { check("\(error)".contains("Reiter"), "Grund nennt Reiter: \(error)") }
        let solo = LayoutNode.split(.row, [.group(["B", "C"], setBy: .mats), .leaf("A"), .leaf("D")])
        do { _ = try LayoutEdit.apply(.tab("D", into: "B"), to: solo, actor: .agent, overrideMats: false); check(false, "in Mats' Reiter") }
        catch {}
        check((try? LayoutEdit.apply(.tab("D", into: "B"), to: solo, actor: .agent, overrideMats: true))?.containsMatsLock == true, "auf Auftrag, ✋ bleibt")
        check((try? LayoutEdit.apply(.tab("D", into: "A"), to: solo, actor: .agent, overrideMats: false)) != nil, "fremde Reiter ohne ✋ frei")

        do { _ = try LayoutEdit.apply(.swap("A", "B"), to: three2, actor: .agent, overrideMats: false) } catch { check(false, "Tauschen im selben Reiter-Platz erlaubt") }
        let swapOut = LayoutNode.split(.row, [.group(["B", "C"], setBy: .mats), .leaf("D")])
        do { _ = try LayoutEdit.apply(.swap("C", "D"), to: swapOut, actor: .agent, overrideMats: false); check(false, "Tauschen aus Mats' Reitern") }
        catch {}
        var full = LayoutNode.split(.row, [.leaf("S"), .split(.column, [.leaf("P1"), .leaf("P2"), .group(["P3", "P4"], setBy: .mats)])])
        full = LayoutEdit.insert("P5", companionOf: "S", anchorCompanions: ["P1", "P2", "P3", "P4"], focusBlock: [], preference: .flexible,
                                 anchorPreference: .flexible, into: full, bounds: bounds, gap: 8)
        check(full.children[1].children.count == 4 && full.children[1].children[2].members == ["P3", "P4"], "Neue Begleiterin nicht in Mats' Reiter: \(full)")
        // Hintergrund: als hinterer Reiter auf den letzten Platz der Nebenspalte, sonst hinter die Kachel selbst; nie in ✋-Reiter.
        let column = LayoutNode.split(.row, [.leaf("S"), .split(.column, [.leaf("P1"), .leaf("P2")])])
        var bg = LayoutEdit.insertBehind("N", anchor: "S", anchorCompanions: ["P1", "P2"], into: column)!
        check(bg.children[1].children[1] == .group(["P2", "N"], front: "P2"), "hinter den letzten Platz: \(bg)")
        check(LayoutGeometry.rect(of: "P1", in: bg, bounds: bounds) == LayoutGeometry.rect(of: "P1", in: column, bounds: bounds), "nimmt keinen Platz")
        bg = LayoutEdit.insertBehind("N", anchor: "S", anchorCompanions: [], into: .split(.row, [.leaf("S"), .leaf("X")]))!
        check(bg.children[0] == .group(["S", "N"], front: "S"), "ohne Nebenspalte hinter die Kachel selbst: \(bg)")
        let lockedColumn = LayoutNode.split(.row, [.leaf("S"), .split(.column, [.leaf("P1"), .group(["P2", "P3"], setBy: .mats)])])
        bg = LayoutEdit.insertBehind("N", anchor: "S", anchorCompanions: ["P1", "P2", "P3"], into: lockedColumn)!
        check(bg.children[0] == .group(["S", "N"], front: "S") && bg.children[1] == lockedColumn.children[1], "✋-Reiter bleiben zu: \(bg)")
        var lockedAll = LayoutNode.split(.row, [.group(["S", "Q"], setBy: .mats), .leaf("X")])
        check(LayoutEdit.insertBehind("N", anchor: "S", anchorCompanions: [], into: lockedAll) == nil, "kein erlaubter Platz → nil")
        lockedAll = .leaf("S")
        check(LayoutEdit.insertBehind("N", anchor: "S", anchorCompanions: [], into: lockedAll) == .group(["S", "N"], front: "S"), "einzige Kachel")
        check(LayoutEdit.insertBehind("S", anchor: "S", anchorCompanions: [], into: lockedAll) == nil, "schon drin")

        // Mats' Sperren anderer Teilungen bleiben; Ergebnis ist bereinigt (keine Ein-Kind-Teilungen).
        var locked = root
        locked.children[1].setBy = .mats
        m = move("A", .place("B", .right), locked)!
        check(m.setBy == .mats || m.children.contains { $0.setBy == .mats }, "Sperre bleibt")
        func noSingles(_ n: LayoutNode) -> Bool { n.isLeaf || (n.children.count > 1 && n.children.allSatisfy(noSingles)) }
        for target in [LayoutDropTarget.place("B", .left), .place("C", .center), .window(.top), .tabBar("B", index: 0)] {
            if let out = move("A", target, root) { check(noSingles(out) && Set(out.paneIDs) == ["A", "B", "C"], "bereinigt nach \(target): \(out)") }
        }
    }
}
