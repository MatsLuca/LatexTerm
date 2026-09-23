import AppKit
import QuartzCore

/// Start-Vorhang der Home-Kachel: liegt über der Home-Ansicht, bis die Claude-Session steht.
///
/// Stil „Linie“, Variante B (Mats, 23.09.2026): der Rahmen der Kachel selbst ist der Fortschritt — ein 2-pt-Strich
/// in Kachelfarbe zeichnet sich von oben links im Uhrzeigersinn um die Kachel, in der Mitte stehen nur Titel und Uhr.
/// Zeitbasiert gegen die erwartete Startdauer (`eta`, gleitender Mittelwert der letzten echten Starts): schnell am
/// Anfang, dann asymptotisch gegen ~94 %, nie „fertig" ohne Signal. Kommt `status=ready`, schließt sich der Rahmen
/// (`finish`), blitzt einmal auf und geht im normalen Fokusrahmen auf. Ohne Signal (Timeout) blendet er nur aus —
/// der Rahmen lügt nicht. (Vorher: Ring in der Mitte; Entwürfe `claude-werkstatt/plans/start-vorhang-varianten_2026-09-23.html`.)
///
/// Der Strich liegt als eigene Ebene auf der Hülle (`PaneContainerView`), weil der Vorhang selbst im Innenabstand sitzt;
/// er läuft als EINE Keyframe-Animation (kein Timer für die Optik), nur die Sekundenanzeige tickt (10 Hz).
/// Fokus: die View ist selbst First Responder und schluckt Tastendrücke — so bleibt der Baum darunter taub und
/// ⌘⏎/⌘W erreichen weiter die Kachel (`HomePaneView.performKeyEquivalent`).
final class LaunchOverlayView: NSView {

    /// Fortschritt um die Kachel; hängt an der Hülle, solange der Vorhang steht.
    private let edge = CAShapeLayer()
    private weak var host: NSView?
    private var edgeSize: CGSize = .zero
    private let eta: TimeInterval
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var clock: Timer?
    private let started = Date()
    private var finished = false
    private var onReveal: (() -> Void)?
    private let revealButton = NSButton(title: "Terminal anzeigen  ⎋", target: nil, action: nil)

    func allowReveal(_ action: @escaping () -> Void) {
        onReveal = action
        revealButton.target = self
        revealButton.action = #selector(revealNow)
        revealButton.isBordered = false
        revealButton.font = sub.font
        revealButton.contentTintColor = sub.textColor
        revealButton.setAccessibilityLabel("Terminal anzeigen")
        stack.addArrangedSubview(revealButton)
    }

    @objc private func revealNow() { onReveal?() }

    /// Anteil des Rahmens, den der Start ohne Signal höchstens erreicht.
    private static let ceiling: CGFloat = 0.94
    /// Steilheit: bei t = eta sind ≈ 84 % erreicht (ceiling · (1 − e^−k)).
    private static let steepness: CGFloat = 2.2
    /// Länger als das plant die Kurve nicht — TerminalPane bricht bei 12 s ohnehin ab.
    private static let horizon: TimeInterval = 12
    private static let lineWidth: CGFloat = 2

    init(frame: NSRect, label: String, accent: NSColor, fg: NSColor, dim: NSColor,
         font: (CGFloat, NSFont.Weight) -> NSFont, eta: TimeInterval) {
        self.eta = max(0.4, min(eta, 8))
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = ThemeStore.shared.theme.background.cgColor

        edge.fillColor = nil
        edge.strokeColor = accent.cgColor
        edge.lineWidth = Self.lineWidth
        edge.lineCap = .round
        edge.lineJoin = .round
        edge.strokeEnd = 0

        title.stringValue = label
        title.font = font(1, .regular)
        title.textColor = fg
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        sub.font = font(-1, .regular)
        sub.textColor = dim
        sub.alignment = .center
        sub.lineBreakMode = .byClipping
        sub.stringValue = Self.subText(0)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(14, after: sub)   // erst NACH dem Einhängen — sonst NSInvalidArgumentException
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.82),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            sub.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])

        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.sub.stringValue = Self.subText(Date().timeIntervalSince(self.started))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { clock?.invalidate() }

    private static func subText(_ t: TimeInterval) -> String {
        "startet · " + String(format: "%.1f", t).replacingOccurrences(of: ".", with: ",") + " s"
    }

    // MARK: Rahmen an der Hülle

    /// Eingehängt: Strich an die Kachel-Hülle hängen (oder, ohne Hülle, an den Vorhang selbst) und loslaufen lassen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, host == nil else { return }
        var v = superview
        while let current = v, !(current is PaneContainerView) { v = current.superview }
        let target = v ?? self
        host = target
        target.layer?.addSublayer(edge)
        updateEdgePath()
        if !finished { startProgress() }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        // Abgebrochen (Kachel zu, Vorhang weg ohne finish): Strich sofort mitnehmen. Nach finish räumt fadeEdge auf.
        if newSuperview == nil, !finished { edge.removeFromSuperlayer(); host = nil }
    }

    /// Weg: oben links nach dem Eckbogen beginnen, im Uhrzeigersinn um die Kachel — Ecken wie die Hülle (Radius 8).
    /// Die Hülle ist geflippt (y nach unten), Tangenten-Bögen sind richtungsneutral.
    private func updateEdgePath() {
        guard let host else { return }
        let size = host.bounds.size
        guard size != edgeSize, size.width > 20, size.height > 20 else { return }
        edgeSize = size
        let w = Self.lineWidth
        let rect = host.bounds.insetBy(dx: w / 2, dy: w / 2)
        let r = max(0, (host.layer?.cornerRadius ?? 8) - w / 2)
        let flipped = host.isFlipped
        let top = flipped ? rect.minY : rect.maxY, bottom = flipped ? rect.maxY : rect.minY
        let down: CGFloat = flipped ? 1 : -1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + down * r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - down * r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX - r, y: bottom), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom - down * r), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: top + down * r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edge.frame = host.bounds
        edge.path = path
        CATransaction.commit()
    }

    // MARK: Geometrie (klein bei kleinen Kacheln)

    override func layout() {
        super.layout()
        let tiny = bounds.height < 120 || bounds.width < 140
        title.isHidden = tiny
        sub.isHidden = tiny || bounds.height < 90
        updateEdgePath()
    }

    // MARK: Fortschritt

    /// Zeitkurve als Keyframes: p(t) = ceiling · (1 − e^(−k·t/eta)), ab dem Start des Vorhangs.
    private func startProgress() {
        let n = 240
        var values: [CGFloat] = []
        values.reserveCapacity(n + 1)
        for i in 0...n {
            let t = Self.horizon * Double(i) / Double(n)
            values.append(Self.ceiling * (1 - CGFloat(exp(-Double(Self.steepness) * t / eta))))
        }
        let anim = CAKeyframeAnimation(keyPath: "strokeEnd")
        anim.values = values
        anim.duration = Self.horizon
        anim.calculationMode = .linear
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.timeOffset = min(Self.horizon, Date().timeIntervalSince(started))
        edge.add(anim, forKey: "progress")
    }

    /// Session steht: Rahmen schließen, einmal aufblitzen, dann `completion` (Aufrufer blendet aus); der Strich blendet
    /// danach in den normalen Fokusrahmen aus. `success == false` (Timeout): kein Abschluss vortäuschen, nur ausblenden.
    func finish(success: Bool, completion: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        clock?.invalidate(); clock = nil
        guard success else { fadeEdge(after: 0); completion(); return }

        let current = edge.presentation()?.strokeEnd ?? edge.strokeEnd
        edge.removeAnimation(forKey: "progress")
        sub.stringValue = "bereit"

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            // Einmal aufblitzen — die Belohnung, nicht mehr.
            let flash = CABasicAnimation(keyPath: "lineWidth")
            flash.fromValue = Self.lineWidth
            flash.toValue = Self.lineWidth * 1.8
            flash.duration = 0.12
            flash.autoreverses = true
            flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.edge.add(flash, forKey: "flash")
            self.fadeEdge(after: 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: completion)
        }
        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = current
        close.toValue = 1.0
        close.duration = 0.2
        close.timingFunction = CAMediaTimingFunction(name: .easeOut)
        edge.strokeEnd = 1.0
        edge.add(close, forKey: "close")
        CATransaction.commit()
    }

    /// Strich ausblenden und von der Hülle lösen — der normale Fokusrahmen darunter bleibt.
    private func fadeEdge(after delay: TimeInterval) {
        let layer = edge
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: Eingaben schlucken

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onReveal?() }
    }
    override func mouseDown(with event: NSEvent) { }    // kein Fokuswechsel in den Baum darunter
}
