import WidgetKit
import SwiftUI

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let isPlaceholder: Bool
}

/// Ein Provider für beide Widgets: liest den Schnappschuss, plant die nächste Lesung in 15 min.
/// Die App stößt nach jedem `projekte widget` zusätzlich `reloadAllTimelines()` an.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample, isPlaceholder: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snap = context.isPreview ? WidgetSnapshot.sample : (SnapshotStore.load() ?? .sample)
        completion(SnapshotEntry(date: Date(), snapshot: snap, isPlaceholder: false))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: SnapshotStore.load(), isPlaceholder: false)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Bausteine

enum Ink {
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let track = Color.white.opacity(0.10)
    static let overdue = Color(hex: "#ff5f5f")
    static let today = Color(hex: "#ffaf00")
    static let accent = Color(hex: "#d97757")   // Claude-Orange der Kachelpalette
}

struct WidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: "#1b1b22"), Color(hex: "#0e0e12")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Circle().fill(Ink.accent.opacity(0.10)).frame(width: 220, height: 220).blur(radius: 60).offset(x: 60, y: -90)
            }
    }
}

struct Caption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(Ink.dim)
    }
}

struct Ring: View {
    let ring: WidgetSnapshot.Ring
    var size: CGFloat = 44
    var body: some View {
        let color = Color(hex: ring.color)
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Ink.track, lineWidth: size * 0.11)
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(ring.percent) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(ring.percent)")
                    .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Ink.text)
            }
            .frame(width: size, height: size)
            Text(ring.label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(Ink.dim)
                .lineLimit(1)
        }
        .opacity(ring.stale == true ? 0.5 : 1)
    }
}

struct DueRow: View {
    let item: WidgetSnapshot.Due
    /// 1 = eine Zeile, Frist rechts in fester Spalte; 2 = zwei Zeilen, Frist fließt hinter dem Titel mit
    /// (keine zweite Spalte, der Titel bekommt die volle Breite).
    var lines: Int = 1
    var body: some View {
        let dot: Color = item.overdue ? Ink.overdue : (item.daysLeft <= 1 ? Ink.today : Ink.faint)
        let whenColor: Color = item.overdue ? Ink.overdue : Ink.dim
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6).padding(.top, 4)
            Image(systemName: item.kind == "wiedervorlage" ? "arrow.uturn.backward.circle" : "checklist")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.faint)
                .frame(width: 10)
                .padding(.top, 2)
            if lines > 1 {
                (Text(item.title).foregroundColor(Ink.text)
                 + Text("  " + item.when).foregroundColor(whenColor).font(.system(size: 10, weight: .semibold, design: .rounded)))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(lines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(item.when)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(whenColor)
                    .lineLimit(1)
            }
        }
    }
}

struct LinkedDueRow: View {
    let item: WidgetSnapshot.Due
    var lines: Int = 1
    var body: some View {
        if let s = item.url, let url = URL(string: s) {
            Link(destination: url) { DueRow(item: item, lines: lines) }
        } else {
            DueRow(item: item, lines: lines)
        }
    }
}

struct Bars: View {
    let bars: [WidgetSnapshot.Bar]
    var count: Int = 28
    var height: CGFloat = 34
    var body: some View {
        let shown = Array(bars.suffix(count))
        let peak = max(1, shown.map(\.sessions).max() ?? 1)
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                let isLast = i == shown.count - 1
                Capsule()
                    .fill(isLast ? Ink.accent : (b.sessions == 0 ? Ink.track : Ink.accent.opacity(0.45)))
                    .frame(height: max(3, height * CGFloat(b.sessions) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 20, weight: .light)).foregroundStyle(Ink.dim)
            Text("LatexTerm einmal starten").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Ink.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget 1: Cockpit (Kontingent + Fälliges)

struct CockpitView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                switch family {
                case .systemSmall: small(snap)
                case .systemLarge: large(snap)
                default: medium(snap)
                }
            } else {
                EmptyHint()
            }
        }
        .containerBackground(for: .widget) { WidgetBackground() }
        .widgetURL(URL(string: "latexterm://home"))
    }

    /// Groß: Ringe als Zeile oben, darunter die volle Liste (bis 8 Einträge, zwei Zeilen je Titel).
    private func large(_ snap: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(snap, title: "Claude")
            HStack(alignment: .top, spacing: 14) {
                ForEach(snap.rings.prefix(3)) { r in Ring(ring: r, size: 46) }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    if let s = snap.rings.first, let reset = s.resetsIn, !reset.isEmpty {
                        Text("\(s.label) in \(reset)")
                    }
                    ForEach(snap.codexRings ?? []) { c in
                        Text("Codex \(c.label) \(c.percent) %").foregroundStyle(c.percent >= 90 ? Ink.overdue : Ink.dim)
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Ink.dim)
                .padding(.top, 4)
            }
            Rectangle().fill(Ink.track).frame(height: 1)
            HStack {
                Caption(text: "Fällig")
                Spacer()
                let overdue = snap.due.filter(\.overdue).count
                if overdue > 0 {
                    Text("\(overdue) überfällig")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Ink.overdue))
                }
            }
            if snap.due.isEmpty {
                Spacer()
                HStack { Spacer(); Text("nichts offen").font(.system(size: 11, design: .rounded)).foregroundStyle(Ink.faint); Spacer() }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snap.due.prefix(8)) { item in LinkedDueRow(item: item, lines: 2) }
                }
                if snap.due.count > 8 {
                    Text("+ \(snap.due.count - 8) weitere")
                        .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Ink.faint)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ snap: WidgetSnapshot, title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Caption(text: title)
            Spacer()
            Text(snap.generatedLabel ?? "")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Ink.faint)
        }
    }

    private func small(_ snap: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(snap, title: "Claude")
            HStack(spacing: 0) {
                ForEach(snap.rings.prefix(3)) { r in
                    Ring(ring: r, size: 40).frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            footer(snap)
        }
    }

    private func footer(_ snap: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let s = snap.rings.first, let reset = s.resetsIn, !reset.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold))
                    Text("\(s.label) in \(reset)")
                }
            }
            if let codex = snap.codexRings?.first {
                Text("Codex \(codex.label) \(codex.percent) %").foregroundStyle(codex.percent >= 90 ? Ink.overdue : Ink.dim)
            }
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Ink.dim)
        .lineLimit(1)
    }

    private func medium(_ snap: WidgetSnapshot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header(snap, title: "Claude")
                HStack(spacing: 6) {
                    ForEach(snap.rings.prefix(3)) { r in Ring(ring: r, size: 35) }
                }
                Spacer(minLength: 0)
                footer(snap)
            }
            .frame(width: 118)
            Rectangle().fill(Ink.track).frame(width: 1).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Caption(text: "Fällig")
                    Spacer()
                    let overdue = snap.due.filter(\.overdue).count
                    if overdue > 0 {
                        Text("\(overdue)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Ink.overdue))
                    }
                }
                if snap.due.isEmpty {
                    Spacer()
                    HStack { Spacer(); Text("nichts offen").font(.system(size: 11, design: .rounded)).foregroundStyle(Ink.faint); Spacer() }
                    Spacer()
                } else {
                    ForEach(snap.due.prefix(3)) { item in LinkedDueRow(item: item, lines: 2) }
                    if snap.due.count > 3 {
                        Text("+ \(snap.due.count - 3) weitere")
                            .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Ink.faint)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct CockpitWidget: Widget {
    let kind = "LatexTerm.Cockpit"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            CockpitView(entry: entry)
        }
        .configurationDisplayName("Claude-Cockpit")
        .description("Kontingente (5h · 7d · Modell) und was fällig ist: Wiedervorlagen und Erinnerungen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget 2: Wrapped (Live-Statistik)

struct WrappedView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                switch family {
                case .systemSmall: small(snap.stats)
                default: medium(snap.stats)
                }
            } else {
                EmptyHint()
            }
        }
        .containerBackground(for: .widget) { WidgetBackground() }
        .widgetURL(URL(string: "latexterm://home"))
    }

    private func bigNumber(_ n: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(n)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Ink.text)
            Text(unit)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Ink.dim)
        }
    }

    private func streak(_ s: WidgetSnapshot.Stats) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.today)
            Text("\(s.streakDays) Tage Serie")
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(Ink.text)
    }

    private func small(_ s: WidgetSnapshot.Stats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(text: "Heute")
            bigNumber(s.sessionsToday, "Sessions")
            Text("\(Fmt.grouped(s.repliesToday)) Antworten · \(Fmt.compact(s.tokensToday)) Tokens")
                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Ink.dim).lineLimit(1)
            Spacer(minLength: 2)
            Bars(bars: s.bars, count: 14, height: 26)
            streak(s)
        }
    }

    private func medium(_ s: WidgetSnapshot.Stats) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Caption(text: "Heute")
                bigNumber(s.sessionsToday, "Sessions")
                Text("\(Fmt.grouped(s.repliesToday)) Antworten")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Ink.dim).lineLimit(1)
                Text("\(Fmt.grouped(s.toolsToday)) Tools · \(Fmt.compact(s.tokensToday)) Tokens")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Ink.dim).lineLimit(1)
                HStack(spacing: 6) {
                    if let m = s.topModelToday {
                        Text(m)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Ink.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(Ink.accent.opacity(0.16)))
                    }
                }
                Spacer(minLength: 0)
                streak(s)
            }
            .frame(width: 132, alignment: .leading)
            Rectangle().fill(Ink.track).frame(width: 1).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Caption(text: "28 Tage")
                    Spacer()
                    Text("\(s.activeDays) aktive Tage")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Ink.faint)
                }
                Bars(bars: s.bars, count: 28, height: 44)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("\(Fmt.grouped(s.sessionsTotal)) Sessions")
                        if let since = Fmt.monthYear(s.since) { Text(" seit \(since)") }
                    }
                    HStack(spacing: 0) {
                        Text("\(Fmt.grouped(s.promptsTotal)) Prompts")
                        if let h = s.favoriteHour { Text(" · meist \(h) Uhr") }
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Ink.dim)
                .lineLimit(1)
            }
        }
    }
}

struct WrappedWidget: Widget {
    let kind = "LatexTerm.Wrapped"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            WrappedView(entry: entry)
        }
        .configurationDisplayName("Claude Wrapped")
        .description("Heute in Zahlen: Sessions, Antworten, Tokens, Serie und die letzten 28 Tage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Bundle

@main
struct LatexTermWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CockpitWidget()
        WrappedWidget()
    }
}
