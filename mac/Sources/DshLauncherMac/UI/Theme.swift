import SwiftUI

/// Graphite instrument panel.
///
/// One graphite ramp, two text tones, four state colors. Color carries meaning
/// only: no gradients, no glows, no colored shadows. Weights stay at 400/500
/// and every reading (PID, port, latency, URL, command) is monospaced.
enum Theme {
    // MARK: - Palette

    static let page = color(0x141415)
    static let deep = color(0x0F0F10)
    static let card = color(0x19191B)
    static let raised = color(0x232325)
    static let text = color(0xEDEDED)
    static let secondary = color(0x8A8A90)
    static let primaryHover = color(0xF6F6F6)
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let positive = color(0x4CC38A)
    static let attention = color(0xD9A441)
    static let off = color(0x5A5A60)
    static let danger = color(0xE5484D)

    // MARK: - Type

    /// Interface text: system sans, weights 400/500 only.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Readings: system monospaced so digits and ports line up.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static var wordmark: Font { sans(13, weight: .medium) }
    static var aggregate: Font { sans(12) }
    static var sectionTitle: Font { sans(11) }
    static var rowName: Font { sans(13, weight: .medium) }
    static var body: Font { sans(12) }
    static var button: Font { sans(11.5) }
    static var caption: Font { sans(10.5) }
    static var dialogTitle: Font { sans(13, weight: .medium) }
    static var reading: Font { mono(11) }
    static var readingSmall: Font { mono(10.5) }

    // MARK: - State

    static func statusColor(_ state: MachineState) -> Color {
        switch state {
        case .running:
            return positive
        case .starting, .needsSetup, .unreachable, .unknown:
            return attention
        case .stopped:
            return off
        }
    }

    static func statusText(_ state: MachineState) -> String {
        state.text
    }

    // MARK: - Helpers

    static func color(_ value: UInt32, alpha: Double = 1.0) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

/// Dimensions on a 4 pt grid, with nested radii (window 12 / card 10 /
/// row 8 / button 7 / input 6).
enum Metrics {
    static let windowWidth: CGFloat = 520
    static let windowHeight: CGFloat = 620
    static let headerPaddingH: CGFloat = 14
    static let listPaddingH: CGFloat = 10
    static let rowHeight: CGFloat = 40
    static let rowRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 7
    static let inputRadius: CGFloat = 6
    static let buttonHeight: CGFloat = 28
    static let buttonPaddingH: CGFloat = 14
    static let bottomBarPaddingH: CGFloat = 14
    static let bottomBarHeight: CGFloat = 44
    static let sectionTopPadding: CGFloat = 12
    static let detailIndent: CGFloat = 18
    static let dialogPadding: CGFloat = 18
    static let dialogWidth: CGFloat = 440
    static let logDialogWidth: CGFloat = 500
    static let toastBottomInset: CGFloat = 54
}
