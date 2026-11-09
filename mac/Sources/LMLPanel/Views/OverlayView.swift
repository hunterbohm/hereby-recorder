import SwiftUI
import LMLCore

/// The three overlay shapes; the user switches between them from the overlay's header.
public enum OverlayStyle: String, CaseIterable, Sendable {
    case strip, card, pill

    public var label: String {
        switch self {
        case .strip: "Side strip"
        case .card: "Floating card"
        case .pill: "Top pill"
        }
    }

    var symbol: String {
        switch self {
        case .strip: "sidebar.right"
        case .card: "rectangle.inset.topright.filled"
        case .pill: "capsule"
        }
    }

    var radius: CGFloat { self == .pill ? 20 : 14 }
}

public enum OverlayRules {
    public static let stripWidth: CGFloat = 320
    /// The strip's gap from the screen's edges.
    public static let stripMargin: CGFloat = 8
    public static let cardWidth: CGFloat = 340
    public static let pillOpenWidth: CGFloat = 460
    public static let cardLines = 2
    static let buttons: [QuickAsk] = [.say, .recap, .asked, .check, .screen]
}

/// The live call over every other window: transcript, nudges, and fast answers, in the user's chosen style.
public struct OverlayView: View {
    let store: PanelStore

    public init(store: PanelStore) { self.store = store }

    public var body: some View {
        Group {
            if let live = store.live {
                switch store.overlayStyle {
                case .strip: StripOverlay(content: live.content, paused: live.paused, store: store)
                case .card: CardOverlay(content: live.content, paused: live.paused, store: store)
                case .pill: PillOverlay(content: live.content, paused: live.paused, store: store)
                }
            }
        }
        .font(Fonts.body)
        .environment(\.colorScheme, .dark)
        .background(OverlayMaterial().clipShape(RoundedRectangle(cornerRadius: store.overlayStyle.radius)))
        .overlay(RoundedRectangle(cornerRadius: store.overlayStyle.radius).strokeBorder(.white.opacity(0.12)))
    }
}

private struct StripOverlay: View {
    let content: LiveContent
    let paused: Bool
    let store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlayHeader(content: content, paused: paused, store: store)
            NudgeBanner(content: content)
            OverlayTranscript(content: content, paused: paused, store: store, limit: nil)
                .frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            LatestAnswer(content: content, store: store)
            QuickButtons(store: store, paused: paused)
            OverlayAskField(store: store, paused: paused)
        }
        .padding(12)
        .frame(width: OverlayRules.stripWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct CardOverlay: View {
    let content: LiveContent
    let paused: Bool
    let store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OverlayHeader(content: content, paused: paused, store: store)
            NudgeBanner(content: content)
            LatestAnswer(content: content, store: store)
            QuickButtons(store: store, paused: paused)
            OverlayTranscript(content: content, paused: paused, store: store, limit: OverlayRules.cardLines)
            OverlayAskField(store: store, paused: paused)
        }
        .padding(12)
        .frame(width: OverlayRules.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PillOverlay: View {
    let content: LiveContent
    let paused: Bool
    @Bindable var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RecordingDot(paused: paused)
                Elapsed(startedAt: content.startedAt, stoppedAt: content.stoppedAt, paused: paused, store: store, font: Fonts.stamp)
                if let line = content.lines.last {
                    Text(PanelText.speaker(line.speaker, them: content.themName))
                        .font(Fonts.sub.weight(.semibold))
                        .fixedSize()
                    Text(line.text)
                        .font(Fonts.sub)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: store.pillOpen ? .infinity : 240, alignment: .leading)
                } else {
                    Text(paused ? "Paused" : "Listening…").font(Fonts.sub).foregroundStyle(.secondary)
                }
                if content.latestWarning != nil, !store.pillOpen {
                    Circle().fill(Palette.warn).frame(width: 7, height: 7).accessibilityLabel("Nudge")
                }
                Button { withAnimation(.snappy(duration: 0.25)) { store.pillOpen.toggle() } } label: {
                    Image(systemName: store.pillOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.pillOpen ? "Close" : "Open")
            }
            if store.pillOpen {
                OverlayHeader(content: content, paused: paused, store: store)
                NudgeBanner(content: content)
                LatestAnswer(content: content, store: store)
                QuickButtons(store: store, paused: paused)
                OverlayAskField(store: store, paused: paused)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: store.pillOpen ? OverlayRules.pillOpenWidth : nil)
        .fixedSize(horizontal: !store.pillOpen, vertical: true)
    }
}

private struct RecordingDot: View {
    let paused: Bool

    var body: some View {
        if paused {
            Image(systemName: "pause.fill").font(.system(size: 10)).accessibilityHidden(true)
        } else {
            Circle().fill(Palette.record).frame(width: 8, height: 8).accessibilityHidden(true)
        }
    }
}

private struct OverlayHeader: View {
    let content: LiveContent
    let paused: Bool
    let store: PanelStore

    var body: some View {
        HStack(spacing: 8) {
            if store.overlayStyle != .pill { RecordingDot(paused: paused) }
            Text(content.title)
                .font(Fonts.titleSmall)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel((paused ? "Paused, " : "Recording, ") + content.title)
            Spacer(minLength: 6)
            if store.overlayStyle != .pill {
                Elapsed(startedAt: content.startedAt, stoppedAt: content.stoppedAt, paused: paused, store: store,
                        font: Fonts.stamp.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Button { Task { await store.markMoment() } } label: {
                Image(systemName: store.activeFlash == .marked ? "checkmark" : "flag")
            }
            .buttonStyle(OverlayIconStyle())
            .disabled(paused)
            .help(store.shortcutAvailable ? "Mark this moment (⌥M)" : "Mark this moment")
            .accessibilityLabel("Mark moment")
            Menu {
                ForEach(OverlayStyle.allCases, id: \.self) { style in
                    Button { store.overlayStyle = style } label: {
                        Label(style.label, systemImage: style == store.overlayStyle ? "checkmark" : style.symbol)
                    }
                }
            } label: {
                Image(systemName: store.overlayStyle.symbol)
            }
            .menuStyle(.button)
            .buttonStyle(OverlayIconStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Overlay style")
            .accessibilityLabel("Overlay style")
            Button { store.toggleOverlay() } label: { Image(systemName: "eye.slash") }
                .buttonStyle(OverlayIconStyle())
                .help(store.overlayToggleHint.map { "Hide until the next call (\($0) shows it again)" } ?? "Hide until the next call")
                .accessibilityLabel("Hide overlay")
        }
    }
}

private struct OverlayIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.0001), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

private struct NudgeBanner: View {
    let content: LiveContent

    var body: some View {
        if let warning = content.latestWarning {
            HStack(spacing: 0) {
                Rectangle().fill(Palette.warn).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.text).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text("Nudge \(warning.n) of 3 · also texted to your phone").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                Spacer(minLength: 0)
            }
            .background(.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct LatestAnswer: View {
    let content: LiveContent
    let store: PanelStore

    var body: some View {
        if let entry = content.latestAsk {
            AskBubble(entry: entry) { Task { await store.retryAsk(entry.id) } }
        }
    }
}

private struct QuickButtons: View {
    let store: PanelStore
    let paused: Bool

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(OverlayRules.buttons, id: \.self) { kind in
                Button { Task { await store.quickAsk(kind) } } label: {
                    HStack(spacing: 4) {
                        Text(PanelCopy.quickLabel(kind))
                        if kind == .say, let hint = store.overlaySayHint {
                            Text(hint).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.13)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(paused || store.isAsking)
    }
}

private struct OverlayAskField: View {
    @Bindable var store: PanelStore
    let paused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Ask about this call", text: $store.askDraft)
                .textFieldStyle(.plain)
                .font(Fonts.sub)
                .onSubmit { Task { await store.submitAsk() } }
            if store.isAsking { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15)))
        .disabled(paused)
    }
}

private struct OverlayTranscript: View {
    let content: LiveContent
    let paused: Bool
    let store: PanelStore
    /// The newest lines to show without scrolling; nil shows the whole call in a scroll view.
    let limit: Int?

    var body: some View {
        if let limit {
            lines(Array(content.transcript.suffix(limit)))
        } else {
            ScrollView {
                lines(content.transcript)
                    .padding(.bottom, 4)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
        }
    }

    private func lines(_ items: [ConversationItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text(paused ? "Nothing is recorded until you resume." : "Listening…").font(Fonts.sub).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                switch item {
                case .line(let line):
                    Text("\(Text(PanelText.speaker(line.speaker, them: content.themName)).fontWeight(.semibold).foregroundStyle(line.speaker == "me" ? .secondary : .primary))  \(line.text)")
                        .font(Fonts.sub)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .mark(let at):
                    Label("Marked \(PanelText.stamp(at, since: content.startedAt, in: store.timeZone, locale: store.locale))", systemImage: "flag")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.record)
                case .warning, .ask:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(paused ? 0.55 : 1)
    }
}

/// Lays its children out in rows, wrapping to the next row when one would overflow.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

struct OverlayMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension LiveContent {
    var lines: [TranscriptLine] { items.compactMap { if case .line(let line) = $0 { line } else { nil } } }
    /// Lines and marks only; the overlay shows nudges and answers in their own places.
    var transcript: [ConversationItem] {
        items.filter { if case .line = $0 { true } else if case .mark = $0 { true } else { false } }
    }
    var latestWarning: PanelWarning? { items.compactMap { if case .warning(let w) = $0 { w } else { nil } }.max { $0.n < $1.n } }
    var latestAsk: AskEntry? { items.compactMap { if case .ask(let entry) = $0 { entry } else { nil } }.last }
}
