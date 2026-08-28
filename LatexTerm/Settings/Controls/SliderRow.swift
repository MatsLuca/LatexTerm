import SwiftUI

/// Beschriftung · Slider · Wert mit Einheit — die eine Slider-Zeile für alle Seiten.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var decimals: Int = 0

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                Text(String(format: "%.\(decimals)f", value) + unit)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

extension Binding where Value == CGFloat {
    /// Slider wollen `Double`; die Stores rechnen in `CGFloat`.
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = CGFloat($0) })
    }
}
