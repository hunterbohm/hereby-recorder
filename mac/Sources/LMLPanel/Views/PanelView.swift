import SwiftUI
import LMLCore

public struct PanelView: View {
    let store: PanelStore

    public init(store: PanelStore) { self.store = store }

    public var body: some View {
        Group {
            switch store.screen {
            case .idle(let content): HomeView(mode: .idle(content), store: store)
            case .before(let content): HomeView(mode: .before(content), store: store)
            case .recording(let content): LiveView(content: content, paused: false, store: store)
            case .paused(let content): LiveView(content: content, paused: true, store: store)
            case .after(let content): AfterView(content: content, store: store)
            case .access(let content): AccessView(content: content, store: store)
            }
        }
        .font(Fonts.body)
        .frame(width: PanelRules.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Problems the screen on show doesn't already explain: the mini out of reach, and capture trouble anywhere but the
/// Needs access screen.
struct ProblemBanner: View {
    let store: PanelStore
    var includeCapture = true

    var body: some View {
        let problems = PanelCopy.problems(visible, in: store.timeZone, locale: store.locale)
        if !problems.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(problems, id: \.headline) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.headline.prefix(1).uppercased() + problem.headline.dropFirst())
                                .fontWeight(.semibold)
                            Text(problem.detail)
                                .font(Fonts.sub)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = problem.settingsURL {
                                Button("Open Privacy Settings") { store.open(url) }
                                    .buttonStyle(LinkButtonStyle())
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Palette.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.warn.opacity(0.45)))
        }
    }

    private var visible: Health {
        var health = store.health
        if !includeCapture { health.micOK = true; health.audioOK = true }
        return health
    }
}

struct ArmedLine: View {
    var body: some View {
        Label("Call detected. Recording starts in a few seconds.", systemImage: "ear")
            .font(Fonts.sub)
            .foregroundStyle(.secondary)
    }
}

struct ActionFooter: View {
    let store: PanelStore

    var body: some View {
        switch store.action {
        case .idle:
            EmptyView()
        case .confirming(let action):
            if let copy = PanelCopy.confirmation(action, hasMini: store.hasMini) { ConfirmCard(copy: copy, store: store) }
        case .running(let action):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(PanelCopy.running(action)).font(Fonts.sub).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let action):
            Label(PanelCopy.failure(action), systemImage: "xmark.octagon")
                .font(Fonts.sub)
                .foregroundStyle(Palette.record)
        }
    }
}

struct ConfirmCard: View {
    let copy: PanelCopy.Confirmation
    let store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.title).fontWeight(.semibold)
            Text(copy.detail)
                .font(Fonts.sub)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.cancel() }
                    .buttonStyle(PanelButtonStyle(small: true))
                    .keyboardShortcut(.cancelAction)
                Button(copy.button, role: .destructive) { Task { await store.confirm() } }
                    .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.title)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.record, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .fixedSize()
    }
}

struct RecentRow: View {
    let content: AfterContent
    let fromList: Bool
    let store: PanelStore

    var body: some View {
        Button { store.navigate(.call(content.sid, fromList: fromList)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(content.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    FilingTag(content: content)
                }
                Text(detail)
                    .font(Fonts.sub)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
        .accessibilityLabel("\(content.title), \(PanelText.filingTag(content)), \(detail)")
        .accessibilityHint("Shows details")
    }

    private var detail: String {
        let when = (content.startedAt ?? content.endedAt).map {
            PanelText.past($0, now: store.now, in: store.timeZone, locale: store.locale)
        }
        return [when, content.snippet].compactMap { $0 }.joined(separator: " · ")
    }
}

struct FilingTag: View {
    let content: AfterContent

    var body: some View {
        HStack(spacing: 4) {
            switch content.state {
            case .filed: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            case .filing: ProgressView().controlSize(.mini)
            case .waiting: Image(systemName: "clock").font(.system(size: 10))
            case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 10, weight: .semibold))
            case .skipped: EmptyView()
            }
            Text(PanelText.filingTag(content)).lineLimit(1)
        }
        .font(Fonts.tag)
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch content.state {
        case .filed: .secondary
        case .failed: Palette.record
        case .waiting, .filing, .skipped: .secondary
        }
    }
}

struct FilingPill: View {
    let state: FilingState

    var body: some View {
        switch state {
        case .filed: Pill(text: "Filed", symbol: "checkmark", tone: .ok)
        case .filing: Pill(text: "Filing", spinning: true)
        case .waiting: Pill(text: "Waiting to file", symbol: "clock")
        case .skipped: Pill(text: "Skipped", symbol: "minus.circle")
        case .failed: Pill(text: "Filing failed", symbol: "exclamationmark.circle", tone: .record)
        }
    }
}

struct InfoRow: View {
    let symbol: String
    let text: String
    var detail: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Fonts.sub).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Bullets: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(.secondary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
