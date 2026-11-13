import SwiftUI

// MARK: - Status dot

/// The 8 pt lamp. Color is the only signal: no ring, no pulse, no glow.
struct StatusDot: View {
    let state: MachineState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.statusColor(state))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Hairline

struct Hairline: View {
    var color: Color = Theme.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

// MARK: - Section heading

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.secondary)
            Text("\(count)")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.secondary.opacity(0.72))
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.horizontal, 2)
    }
}

// MARK: - Small button

/// Standard 28 pt button: off-white primary, card secondary, text-only quiet.
/// No gradients, no glow; hover/press only shift the surface.
struct SmallButton: View {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    private let title: String
    private let kind: Kind
    private let symbol: String?
    private let height: CGFloat
    private let enabled: Bool
    private let action: () -> Void

    @State private var hovering = false

    init(
        _ title: String,
        kind: Kind = .secondary,
        symbol: String? = nil,
        height: CGFloat = Metrics.buttonHeight,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.symbol = symbol
        self.height = height
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .regular))
                }
                Text(title)
                    .font(Theme.sans(11.5, weight: kind == .primary ? .medium : .regular))
                    .lineLimit(1)
            }
        }
        .buttonStyle(SmallButtonStyle(kind: kind, hovering: hovering, height: height))
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    let kind: SmallButton.Kind
    let hovering: Bool
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, Metrics.buttonPaddingH)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.buttonRadius))
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return Theme.page
        case .secondary:
            return Theme.text
        case .quiet:
            return hovering ? Theme.text : Theme.secondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            if pressed { return Theme.text.opacity(0.76) }
            return hovering ? Theme.primaryHover : Theme.text
        case .secondary:
            if pressed { return Theme.raised.opacity(0.8) }
            return hovering ? Theme.raised : Theme.card
        case .quiet:
            if pressed { return Color.white.opacity(0.10) }
            return hovering ? Color.white.opacity(0.06) : Color.clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary:
            return Color.clear
        case .secondary:
            return Theme.hairlineStrong
        case .quiet:
            return Color.clear
        }
    }
}

// MARK: - Quiet text button

/// Inline action inside a reading row ("コピー", "開く"). Stays quiet until hover.
struct QuietButton: View {
    private let title: String
    private let symbol: String?
    private let color: Color
    private let hoverColor: Color?
    private let action: () -> Void

    @State private var hovering = false

    init(
        _ title: String,
        symbol: String? = nil,
        color: Color = Theme.secondary,
        hoverColor: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.hoverColor = hoverColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .regular))
                }
                Text(title)
                    .font(Theme.sans(10.5))
            }
            .foregroundStyle(hovering ? (hoverColor ?? Theme.text) : color)
            .padding(.horizontal, 3)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Icon button

struct IconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void

    @State private var hovering = false

    init(symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.inputRadius)
                        .fill(hovering ? Color.white.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label)
    }
}

// MARK: - Copyable monospaced reading

/// A selectable monospaced value with its copy action kept at the trailing edge.
struct CopyableMonoRow: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = Theme.text
    var copyTitle: String = "コピー"
    let onCopy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(Theme.mono(size))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            QuietButton(copyTitle) { onCopy(text) }
        }
    }
}

// MARK: - Command receipt

/// The product signature: the exact command is shown before it runs, selectable
/// and copyable, on a recessed surface.
struct CommandReceipt: View {
    var title: String = "実行するコマンド"
    let command: String
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                QuietButton("コピー") { onCopy(command) }
            }
            Text(command)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                .fill(Theme.deep)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Toast

struct ToastBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.sans(11))
            .foregroundStyle(Theme.text)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 470)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                    .fill(Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}
