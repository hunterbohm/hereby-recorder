import AppKit
import SwiftUI

enum Palette {
    static let record = dynamic(light: 0xE5484D, dark: 0xE5484D)
    static let ok = dynamic(light: 0x2B9A57, dark: 0x3FBF72)
    static let warn = dynamic(light: 0xC47A06, dark: 0xE8A23A)
    static let accent = dynamic(light: 0x0A7CFF, dark: 0x0A7CFF)
    static let line = dynamic(light: 0xDCDCE2, dark: 0x3B3B41)
    static let primaryFill = dynamic(light: 0x1D1D1F, dark: 0xECECF1)
    static let primaryText = dynamic(light: 0xFFFFFF, dark: 0x161618)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x161618)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Fonts {
    static let body = Font.system(size: 13)
    static let sub = Font.system(size: 12)
    static let tag = Font.system(size: 11.5)
    static let label = Font.system(size: 12, weight: .medium)
    static let title = Font.system(size: 15, weight: .semibold)
    static let titleSmall = Font.system(size: 13.5, weight: .semibold)
    static let timer = Font.system(size: 15, weight: .semibold).monospacedDigit()
    static let stamp = Font.system(size: 11).monospacedDigit()
}

struct PanelLayout<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
            if Footer.self != EmptyView.self {
                Divider()
                footer
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Fonts.label)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Pill: View {
    enum Tone { case neutral, record, accent, ok, warn }

    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    var spinning = false

    var body: some View {
        HStack(spacing: 6) {
            if spinning {
                ProgressView().controlSize(.mini)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(color)
        .fixedSize()
    }

    private var tint: Color {
        switch tone {
        case .neutral: .primary
        case .record: Palette.record
        case .accent: Palette.accent
        case .ok: Palette.ok
        case .warn: Palette.warn
        }
    }

    /// Status reads as text: only recording and warnings carry color.
    private var color: Color { tone == .record || tone == .warn ? tint : .primary }
}

struct HealthLine: View {
    let micOK: Bool
    let audioOK: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Mic \(state(micOK))")
            Text("Call audio \(state(audioOK))")
        }
        .font(Fonts.tag)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func state(_ on: Bool) -> Text {
        Text(on ? "on" : "off").fontWeight(.medium).foregroundStyle(on ? Color.secondary : Palette.record)
    }
}

struct PanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .secondary
    var small = false
    var flashed = false

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, style: self)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PanelButtonStyle
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: style.small ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style.small ? 10 : 12)
            .frame(height: style.small ? 28 : 32)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(style.kind == .primary || style.flashed ? Color.clear : Palette.line))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .fixedSize()
    }

    private var foreground: Color {
        if style.flashed { return .white }
        return style.kind == .primary ? Palette.primaryText : .primary
    }

    private var background: Color {
        if style.flashed { return Palette.ok }
        return style.kind == .primary ? Palette.primaryFill : Color.primary.opacity(0.04)
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LinkButtonBody(configuration: configuration) }
}

private struct LinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Fonts.sub)
            .underline()
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
            .fixedSize()
    }
}

struct ShortcutHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.foreground.opacity(0.35)))
            .opacity(0.85)
            .accessibilityHidden(true)
    }
}

struct AskBar<Leading: View>: View {
    let placeholder: String
    @Binding var text: String
    let waiting: Bool
    let submit: () -> Void
    @ViewBuilder var leading: Leading
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            leading
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .focused($focused)
                .onSubmit(submit)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder).font(Fonts.body).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.accent : Palette.line,
                                                                         lineWidth: focused ? 2 : 1))
                .accessibilityLabel(placeholder)
            Button("Ask", action: submit)
                .buttonStyle(PanelButtonStyle())
                .disabled(waiting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint(waiting ? "Waiting for the last answer" : "")
        }
    }
}

extension AskBar where Leading == EmptyView {
    init(placeholder: String, text: Binding<String>, waiting: Bool, submit: @escaping () -> Void) {
        self.init(placeholder: placeholder, text: text, waiting: waiting, submit: submit) { EmptyView() }
    }
}

struct AskBubble: View {
    let entry: AskEntry
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("You asked: \(entry.question)")
                .font(Fonts.sub)
                .foregroundStyle(.secondary)
            switch entry.status {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            case .streaming(let partial):
                Text(partial + " ▍").textSelection(.enabled)
            case .answered(let answer):
                Text(answer).textSelection(.enabled)
            case .failed:
                HStack(spacing: 8) {
                    Text("Couldn't get an answer.").foregroundStyle(Palette.record)
                    Button("Try again", action: retry).buttonStyle(LinkButtonStyle())
                }
            }
        }
        .font(Fonts.body)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
    }
}
