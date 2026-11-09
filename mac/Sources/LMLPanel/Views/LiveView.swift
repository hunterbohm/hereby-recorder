import SwiftUI
import LMLCore

struct LiveView: View {
    let content: LiveContent
    let paused: Bool
    @Bindable var store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            ProblemBanner(store: store)
                .padding(.horizontal, 16)
                .padding(.top, store.health.isOK ? 0 : 12)
            if let target = store.liveHermes, store.hermes(target).isOn {
                HermesCard(target: target, store: store)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
            }
            ConversationView(items: content.items, startedAt: content.startedAt, themName: content.themName, paused: paused,
                             zone: store.timeZone, locale: store.locale) { id in Task { await store.retryAsk(id) } }
                .equatable()
            status
            if content.sid != nil && !paused {
                LiveQuickButtons(store: store)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()
            AskBar(placeholder: "Ask about this call", text: $store.askDraft, waiting: store.isAsking) {
                Task { await store.submitAsk() }
            } leading: {
                MarkButton(store: store, paused: paused)
            }
            .disabled(content.sid == nil)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if paused {
                    Image(systemName: "pause.fill").font(.system(size: 11)).accessibilityHidden(true)
                } else {
                    Circle().fill(Palette.record).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Text(content.title)
                    .font(Fonts.titleSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel((paused ? "Paused, " : "Recording, ") + content.title)
                Spacer(minLength: 8)
                Elapsed(startedAt: content.startedAt, stoppedAt: content.stoppedAt, paused: paused, store: store)
            }
            HStack(spacing: 8) {
                Text(PanelText.liveDetail(content))
                    .font(Fonts.sub)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if content.sid != nil {
                    Button { store.toggleOverlay() } label: {
                        Image(systemName: store.overlayVisible ? "sidebar.right" : "sidebar.squares.right")
                    }
                    .buttonStyle(PanelButtonStyle(small: true))
                    .help(store.overlayVisible ? "Hide the overlay" : "Show the overlay")
                    .accessibilityLabel(store.overlayVisible ? "Hide the overlay" : "Show the overlay")
                }
                if paused {
                    Button("Resume") { Task { await store.perform(.resume) } }
                        .buttonStyle(PanelButtonStyle(kind: .primary, small: true))
                }
                Button { store.navigate(.list) } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(PanelButtonStyle(small: true))
                    .help("Earlier meetings, and ask about any of them")
                    .accessibilityLabel("All recent meetings")
                Button("Stop") { Task { await store.perform(.stop) } }
                    .buttonStyle(PanelButtonStyle(small: true))
                Menu {
                    if !paused { Button("Pause") { Task { await store.perform(.pause) } } }
                    if let sid = content.sid {
                        Button("Not a meeting, delete it") { Task { await store.perform(.notAMeeting(sid: sid)) } }
                    }
                    Divider()
                    Picker("Overlay style", selection: $store.overlayStyle) {
                        ForEach(OverlayStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .disabled(store.isBusy)
        }
    }

    @ViewBuilder private var status: some View {
        let missed = store.activeFlash == .markMissed
        if store.action != .idle || missed {
            VStack(alignment: .leading, spacing: 8) {
                if missed {
                    Label(paused ? "Paused, so nothing was marked" : "Moment not marked", systemImage: "flag.slash")
                        .font(Fonts.sub)
                        .foregroundStyle(Palette.record)
                }
                ActionFooter(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

struct Elapsed: View {
    let startedAt: Date?
    let stoppedAt: Date?
    let paused: Bool
    let store: PanelStore
    var font = Fonts.timer

    var body: some View {
        if let startedAt, !paused || stoppedAt != nil {
            let seconds = (stoppedAt ?? store.now).timeIntervalSince(startedAt)
            Text(PanelText.elapsed(seconds))
                .font(font)
                .foregroundStyle(paused ? .secondary : .primary)
                .fixedSize()
                .accessibilityLabel((paused ? "Paused at " : "Recording for ") + PanelText.duration(seconds))
        }
    }
}

private struct MarkButton: View {
    let store: PanelStore
    let paused: Bool

    var body: some View {
        let marked = store.activeFlash == .marked
        Button { Task { await store.markMoment() } } label: {
            HStack(spacing: 6) {
                Image(systemName: marked ? "checkmark" : "flag")
                Text(marked ? "Marked" : "Mark")
                if store.shortcutAvailable { ShortcutHint(keys: "⌥M") }
            }
        }
        .buttonStyle(PanelButtonStyle(kind: .primary, flashed: marked))
        .disabled(paused || store.isBusy)
        .accessibilityLabel("Mark moment")
        .accessibilityHint(store.shortcutAvailable ? "Shortcut Option M, works from any app" : "")
    }
}

struct ConversationView: View, Equatable {
    let items: [ConversationItem]
    let startedAt: Date?
    let themName: String?
    let paused: Bool
    let zone: TimeZone
    let locale: Locale
    let retry: (UUID) -> Void
    @State private var atBottom = true

    nonisolated static func == (a: ConversationView, b: ConversationView) -> Bool {
        a.items == b.items && a.startedAt == b.startedAt && a.themName == b.themName && a.paused == b.paused && a.zone == b.zone && a.locale == b.locale
    }

    var body: some View {
        VStack(spacing: 0) {
            if paused {
                Text("Paused · nothing is being captured")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.warn.opacity(0.14))
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if items.isEmpty {
                            Text(paused ? "Nothing is being recorded until you resume." : "Listening…").foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .id(Self.end)
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, bottom in
                    atBottom = bottom
                }
                .onChange(of: items) {
                    if atBottom { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
        .frame(height: PanelRules.conversationHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private static let end = "conversation"

    @ViewBuilder private func row(_ item: ConversationItem) -> some View {
        switch item {
        case .line(let line):
            let me = line.speaker == "me"
            Text("\(Text(stamp(line.at)).font(Fonts.stamp).foregroundStyle(.secondary))  \(Text(PanelText.speaker(line.speaker, them: themName)).fontWeight(.semibold).foregroundStyle(me ? .secondary : .primary))  \(line.text)")
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(paused ? 0.5 : 1)
                .textSelection(.enabled)
        case .mark(let at):
            HStack(spacing: 6) {
                Image(systemName: "flag").font(.system(size: 11, weight: .semibold))
                Text("Marked \(stamp(at))").font(.system(size: 12, weight: .semibold)).fixedSize()
                Rectangle().fill(Palette.record.opacity(0.4)).frame(height: 1)
            }
            .foregroundStyle(Palette.record)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Marked at \(stamp(at))")
        case .warning(let warning):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(Palette.warn).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text("Texted to your phone").fontWeight(.semibold)) · \(warning.n) of 3")
                    Text(warning.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12.5))
                .lineSpacing(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) { Rectangle().fill(Palette.warn).frame(width: 2).padding(.vertical, 8) }
            .accessibilityElement(children: .combine)
        case .ask(let entry):
            AskBubble(entry: entry) { retry(entry.id) }
        }
    }

    private func stamp(_ at: Date) -> String { PanelText.stamp(at, since: startedAt, in: zone, locale: locale) }
}

/// The overlay's one-tap questions, here too so they work with the overlay hidden.
private struct LiveQuickButtons: View {
    let store: PanelStore

    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(OverlayRules.buttons, id: \.self) { kind in
                Button(PanelCopy.quickLabel(kind)) { Task { await store.quickAsk(kind) } }
                    .buttonStyle(PanelButtonStyle(small: true))
            }
        }
        .disabled(store.isAsking)
    }
}
