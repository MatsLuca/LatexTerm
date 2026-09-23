import Foundation
import CoreGraphics

/// Kachel-Layout: altes Raster exakt nachgebaut, Baum-Bereinigung, Automatik mit Begleitern,
/// Einsetzen/Entfernen im angepassten Layout, Trennlinien, Absichten samt Mats-Sperre, JSON.
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
        let (_, lines) = LayoutGeometry.layout(root, in: bounds, gap: 8)
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
}
