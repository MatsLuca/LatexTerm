import AppKit

/// Eingabe direkt im Home statt eines modalen NSAlert (Mats' Entscheidung 23.09.2026, UI-Inventar B-Dialoge):
/// „Umbenennen“ und „Neues Projekt“. Liegt über der Aktionsspalte, im Stil „Linie“ — Felder nur mit Strich unten,
/// Auswahl als Reiter, Knöpfe randlos, der Hauptknopf in Akzentfarbe mit Strich. ⏎ = bestätigen, Esc = abbrechen,
/// ⇥ springt zum nächsten Feld.
final class HomeInlineForm: NSView, NSTextFieldDelegate {
    struct Field {
        var key: String
        var label: String
        var placeholder: String
        var value: String = ""
    }

    /// Bestätigt: Feldwerte (getrimmt) und gewählter Reiter der Auswahl (0, wenn keine). Rückgabe = Fehlertext, der
    /// im Formular stehen bleibt; nil = fertig, Formular schließt.
    var onSubmit: (([String: String], Int) -> String?)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var fields: [(Field, NSTextField)] = []
    private let choice: LineTabsView?
    private let choiceDetail = NSTextField(labelWithString: "")
    private let submit: LineButton
    private let cancel = LineButton(title: "Abbrechen", hint: "esc")
    private let stack = NSStackView()

    init(title: String, hint: String, fields: [Field], choices: [String]? = nil, submitTitle: String,
         extra: LineButton? = nil) {
        choice = choices.map { LineTabsView(titles: $0) }
        submit = LineButton(title: submitTitle, hint: "⏎")
        super.init(frame: .zero)
        let theme = ThemeStore.shared.theme
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        titleLabel.stringValue = title
        titleLabel.font = HomePaneView.mono(2, .bold)
        titleLabel.textColor = theme.foreground
        hintLabel.stringValue = hint
        hintLabel.font = HomePaneView.mono(-2)
        hintLabel.textColor = theme.dim
        errorLabel.font = HomePaneView.mono(-2, .medium)
        errorLabel.textColor = Tone.error.color
        errorLabel.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(hintLabel)
        stack.setCustomSpacing(22, after: hintLabel)

        for field in fields {
            let row = Self.fieldRow(field)
            stack.addArrangedSubview(row.view)
            row.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.input.delegate = self
            self.fields.append((field, row.input))
        }
        for (i, pair) in self.fields.enumerated() {
            pair.1.nextKeyView = self.fields[(i + 1) % self.fields.count].1
        }

        if let choice {
            choice.font = HomePaneView.mono(-3, .medium)
            let row = NSStackView(views: [Self.rowLabel("Ort"), choice])
            row.spacing = 10
            stack.addArrangedSubview(row)
            choiceDetail.font = HomePaneView.mono(-2)
            choiceDetail.textColor = theme.dim
            choiceDetail.lineBreakMode = .byTruncatingHead
            var detail: [NSView] = [Self.spacer(70), choiceDetail]
            if let extra { extra.font = HomePaneView.mono(-3, .medium); detail.append(extra) }
            let detailRow = NSStackView(views: detail)
            detailRow.spacing = 10
            stack.addArrangedSubview(detailRow)
        }

        stack.addArrangedSubview(errorLabel)
        submit.font = HomePaneView.mono(-2, .semibold)
        submit.accent = ThemeStore.shared.accentColor
        cancel.font = HomePaneView.mono(-2)
        submit.onClick = { [weak self] in self?.commit() }
        cancel.onClick = { [weak self] in self?.onCancel?() }
        let buttons = NSStackView(views: [submit, cancel])
        buttons.spacing = 16
        stack.setCustomSpacing(24, after: errorLabel)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedChoice: Int {
        get { choice?.selectedSegment ?? 0 }
        set { choice?.selectedSegment = newValue }
    }
    var onChoice: ((Int) -> Void)? {
        get { choice?.onChange }
        set { choice?.onChange = newValue }
    }
    func setChoiceDetail(_ text: String) { choiceDetail.stringValue = text }

    func focusFirst() {
        guard let first = fields.first?.1 else { return }
        window?.makeFirstResponder(first)
        first.currentEditor()?.selectAll(nil)
    }

    private func commit() {
        var values: [String: String] = [:]
        for (field, input) in fields { values[field.key] = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let error = onSubmit?(values, selectedChoice) {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Bausteine

    private static func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = HomePaneView.mono(-2)
        l.textColor = ThemeStore.shared.theme.dim
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return l
    }

    private static func spacer(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    /// Feld im Stil „Linie“: Beschriftung links, Eingabe ohne Rahmen, darunter ein Strich.
    private static func fieldRow(_ field: Field) -> (view: NSView, input: NSTextField) {
        let theme = ThemeStore.shared.theme
        let input = NSTextField(string: field.value)
        input.placeholderString = field.placeholder
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = HomePaneView.mono(-1)
        input.textColor = theme.foreground
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.faint).cgColor
        let label = rowLabel(field.label)
        let row = NSView()
        for v in [label, input, line] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.firstBaselineAnchor.constraint(equalTo: input.firstBaselineAnchor),
            input.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            input.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            input.topAnchor.constraint(equalTo: row.topAnchor),
            line.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            line.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 3),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return (row, input)
    }
}
