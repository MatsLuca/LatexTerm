import AppKit
import QuartzCore

/// Start-Vorhang der Home-Kachel: liegt über der Home-Ansicht, bis die Claude-Session steht.
///
/// Ein Ring füllt sich einmal — zeitbasiert gegen die erwartete Startdauer (`eta`, gleitender
/// Mittelwert der letzten echten Starts): schnell am Anfang, dann asymptotisch gegen ~94 %,
/// nie „fertig" ohne Signal. Kommt `status=ready`, schließt sich der Ring (`finish`), pulst
/// kurz, und der Vorhang blendet aus. Ohne Signal (Timeout) blendet er nur aus — der Ring
/// lügt nicht.
///
/// Der Ring läuft als EINE Keyframe-Animation auf dem Layer (kein Timer für die Optik);
/// nur die Sekundenanzeige tickt (10 Hz). Fokus: die View ist selbst First Responder und
/// schluckt Tastendrücke — so bleibt der Baum darunter taub und ⌘⏎/⌘W erreichen weiter die
/// Kachel (`HomePaneView.performKeyEquivalent`).
final class LaunchOverlayView: NSView {

    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    /// Eigene Ebene (nicht view-backed): Anker in der Mitte, damit der Puls um den
    /// Mittelpunkt skaliert — AppKit-Layer haben Anker (0,0) und setzen ihn zurück.
    private let dial = CALayer()
    private let ringHost = NSView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var ringSize: NSLayoutConstraint!
    private var clock: Timer?
    private let started = Date()
    private var finished = false

    /// Anteil des Rings, den der Start ohne Signal höchstens erreicht.
    private static let ceiling: CGFloat = 0.94
    /// Steilheit: bei t = eta sind ≈ 84 % erreicht (ceiling · (1 − e^−k)).
    private static let steepness: CGFloat = 2.2
    /// Länger als das plant die Kurve nicht — TerminalPane bricht bei 12 s ohnehin ab.
    private static let horizon: TimeInterval = 12

    init(frame: NSRect, label: String, accent: NSColor, fg: NSColor, dim: NSColor,
         font: (CGFloat, NSFont.Weight) -> NSFont, eta: TimeInterval) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1).cgColor

        ringHost.wantsLayer = true
        ringHost.translatesAutoresizingMaskIntoConstraints = false
        dial.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringHost.layer?.addSublayer(dial)
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineCap = .round
            dial.addSublayer(shape)
        }
        track.strokeColor = fg.withAlphaComponent(0.10).cgColor
        ring.strokeColor = accent.cgColor
        ring.strokeEnd = 0

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
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(ringHost)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(6, after: title)   // erst NACH dem Einhängen — sonst NSInvalidArgumentException
        addSubview(stack)

        ringSize = ringHost.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            ringSize,
            ringHost.heightAnchor.constraint(equalTo: ringHost.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.82),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            sub.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])

        startRing(eta: max(0.4, min(eta, 8)))
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

    // MARK: Geometrie (klein bei kleinen Kacheln)

    override func layout() {
        super.layout()
        let small = min(bounds.width, bounds.height) < 220
        let tiny = bounds.height < 120 || bounds.width < 140
        let d: CGFloat = small ? 32 : 44
        if ringSize.constant != d { ringSize.constant = d }
        title.isHidden = tiny
        sub.isHidden = tiny || bounds.height < 170
        stack.spacing = small ? 10 : 14
        let width: CGFloat = small ? 2 : 2.5
        let rect = NSRect(x: 0, y: 0, width: d, height: d).insetBy(dx: width, dy: width)
        // Start oben (12 Uhr), im Uhrzeigersinn. Die Ebene ist nicht geflippt (y nach oben):
        // 12 Uhr = 90°, und CoreGraphics' `clockwise: true` läuft dort sichtbar im Uhrzeigersinn.
        let path = CGMutablePath()
        path.addArc(center: NSPoint(x: d / 2, y: d / 2), radius: rect.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dial.frame = CGRect(x: 0, y: 0, width: d, height: d)
        for shape in [track, ring] {
            shape.frame = CGRect(x: 0, y: 0, width: d, height: d)
            shape.path = path
            shape.lineWidth = width
        }
        CATransaction.commit()
    }

    // MARK: Ring

    /// Zeitkurve als Keyframes: p(t) = ceiling · (1 − e^(−k·t/eta)), über den ganzen Horizont.
    private func startRing(eta: TimeInterval) {
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
        ring.add(anim, forKey: "progress")
    }

    /// Session steht: Ring schließen, kurz pulsen, dann `completion` (Aufrufer blendet aus).
    /// `success == false` (Timeout): kein Abschluss vortäuschen, sofort weiter.
    func finish(success: Bool, completion: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        clock?.invalidate(); clock = nil
        guard success else { completion(); return }

        let current = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAnimation(forKey: "progress")
        sub.stringValue = "bereit"

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            // Kurzer Puls des Rings — die Belohnung, nicht mehr.
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0; pulse.toValue = 1.07
            pulse.duration = 0.11
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.dial.add(pulse, forKey: "pulse")
            self.track.strokeColor = self.ring.strokeColor?.copy(alpha: 0.35)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: completion)
        }
        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = current
        close.toValue = 1.0
        close.duration = 0.16
        close.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 1.0
        ring.add(close, forKey: "close")
        CATransaction.commit()
    }

    // MARK: Eingaben schlucken

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { }      // kein Beep, kein Durchreichen
    override func mouseDown(with event: NSEvent) { }    // kein Fokuswechsel in den Baum darunter
}
