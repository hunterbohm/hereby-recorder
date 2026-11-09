import SwiftUI
import LMLCore

/// Ready and before a call: the next call large on top, then one keyboard list (like a macOS menu) of what comes
/// later today, recent calls, and Record in person. ↑ and ↓ move the blue selection, Return opens it; with nothing
/// selected Return joins the next call, and with text typed it asks about any meeting. Opened from a call, the call
/// takes the next call's place on top, and Escape or Return goes back to it.
struct HomeView: View {
    enum Mode: Equatable {
        case idle(IdleContent)
        case before(BeforeContent)
    }

    let mode: Mode
    @Bindable var store: PanelStore
    @State private var selection: Int?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBanner(store: store).padding(.bottom, store.health.isOK ? 0 : 12)
                if store.snapshot.phase == .armed { ArmedLine().padding(.bottom, 12) }
                if let live = store.live {
                    BackToCall(content: live.content, paused: live.paused, store: store)
                    if let target = store.liveHermes, store.hermes(target).isOn {
                        HermesCard(target: target, store: store).padding(.top, 12)
                    }
                } else if connecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to the mini…").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let meeting = heroMeeting {
                    NextCallHero(meeting: meeting, owed: owed, owedLabel: owedLabel, store: store)
                } else {
                    Text("No calls coming up").font(Fonts.titleSmall).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider().padding(.horizontal, 12)
            askField(rows)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            if let entry = store.anyAsk {
                AskBubble(entry: entry) { Task { await store.submitAnyAsk(entry.question) } }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            HomeList(sections: sections(rows), selection: $selection, store: store)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            ActionFooter(store: store)
                .padding(.horizontal, 16)
                .padding(.top, store.action == .idle ? 0 : 8)
            Divider().padding(.top, 6)
            HomeFooter(store: store)
        }
        // The selection is a position in the list, so any change to the list clears it rather than let it land on
        // another row that Return would then open.
        .onChange(of: rows.map(\.withoutHermes)) { selection = nil }
    }

    // MARK: Content

    private var connecting: Bool {
        if case .idle(let content) = mode { return content.connecting }
        return false
    }

    private var heroMeeting: PanelMeeting? {
        guard store.live == nil else { return nil }
        switch mode {
        case .idle(let content): return content.next
        case .before(let content): return content.meeting
        }
    }

    private var owed: [String] {
        if case .before(let content) = mode { return content.owed }
        return []
    }

    private var owedLabel: String {
        if case .before(let content) = mode { return content.owedLabel }
        return ""
    }

    private var rows: [HomeRow] {
        var out: [HomeRow] = []
        let today: [PanelAgendaItem]
        switch mode {
        case .idle(let content): today = content.today
        case .before(let content): today = content.today
        }
        let hero = heroMeeting
        for item in today where !(hero.map { $0.start == item.start && $0.title == item.title } ?? false) {
            out.append(.event(item))
        }
        switch mode {
        case .idle(let content): out += content.recent.map(HomeRow.recent)
        case .before(let content): if let last = content.lastCall { out.append(.recent(last)) }
        }
        // The recorder takes one recording at a time.
        if store.live == nil { out.append(.recordInPerson) }
        return out
    }

    private func sections(_ rows: [HomeRow]) -> [HomeSection] {
        var later: [Int] = [], recent: [Int] = [], actions: [Int] = []
        for (index, row) in rows.enumerated() {
            switch row {
            case .event: later.append(index)
            case .recent: recent.append(index)
            case .recordInPerson: actions.append(index)
            }
        }
        let recentTitle: String
        if case .before = mode { recentTitle = "Last call" } else { recentTitle = "Recent" }
        return [HomeSection(title: "Later today", rows: later.map { ($0, rows[$0]) }),
                HomeSection(title: recentTitle, rows: recent.map { ($0, rows[$0]) }),
                HomeSection(title: nil, rows: actions.map { ($0, rows[$0]) })]
            .filter { !$0.rows.isEmpty }
    }

    // MARK: Keyboard

    private func askField(_ rows: [HomeRow]) -> some View {
        TextField("", text: $store.anyDraft)
            .textFieldStyle(.plain)
            .font(Fonts.body)
            .focused($fieldFocused)
            .background(alignment: .leading) {
                if store.anyDraft.isEmpty {
                    Text("Ask about any meeting").foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .onSubmit { submit(rows) }
            .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
            .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
            .onKeyPress(.escape) {
                if selection != nil { selection = nil; return .handled }
                guard store.live != nil, store.action == .idle else { return .ignored }
                store.navigate(.auto)
                return .handled
            }
            .disabled(store.isAskingAny)
            .accessibilityLabel("Ask about any meeting")
            .accessibilityHint("Arrow keys move through the list below")
            .onAppear { fieldFocused = true }
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        if let index = selection {
            let next = index + step
            selection = next < 0 ? nil : min(next, count - 1)
        } else if step > 0 {
            selection = 0
        }
    }

    private func submit(_ rows: [HomeRow]) {
        if !store.anyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await store.submitAnyAsk() }
        } else if let index = selection, rows.indices.contains(index) {
            rows[index].activate(store)
        } else if store.live != nil {
            store.navigate(.auto)
        } else if let url = heroMeeting?.meetingURL.flatMap(PanelLinks.url) {
            store.open(url)
        }
    }
}

/// The call that is recording, on top of the list opened from it, and the way back to it.
struct BackToCall: View {
    let content: LiveContent
    let paused: Bool
    let store: PanelStore

    var body: some View {
        Button { store.navigate(.auto) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if paused {
                    Image(systemName: "pause.fill").font(.system(size: 10))
                } else {
                    Circle().fill(Palette.record).frame(width: 8, height: 8)
                }
                Text(content.title).font(Fonts.titleSmall).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Elapsed(startedAt: content.startedAt, stoppedAt: content.stoppedAt, paused: paused, store: store, font: Fonts.sub)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(store.action == .idle ? .cancelAction : nil)
        .accessibilityLabel("Back to the call, \(content.title)")
    }
}

// MARK: Hero

/// The next call, large: when, a countdown, the title, the brief, and Join.
struct NextCallHero: View {
    let meeting: PanelMeeting
    let owed: [String]
    let owedLabel: String
    let store: PanelStore

    var body: some View {
        let url = meeting.meetingURL.flatMap(PanelLinks.url)
        let platform = url.flatMap(PanelLinks.platform)
        let countdown = PanelText.countdown(to: meeting.start, end: meeting.end, now: store.now, in: store.timeZone,
                                            locale: store.locale)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(["Next call", platform].compactMap { $0 }.joined(separator: " · "))
                Spacer(minLength: 8)
                Text(PanelText.upcoming(meeting.start, now: store.now, in: store.timeZone, locale: store.locale))
                    .monospacedDigit()
            }
            .font(Fonts.sub)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(countdown.value).font(.system(size: 40, weight: .light)).monospacedDigit()
                Text(countdown.unit).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            Text(meeting.title)
                .font(Fonts.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            // Before a call the owed tasks are listed one by one, so the brief's own "You owe …" line would repeat them.
            let brief = Array(meeting.brief.filter { owed.isEmpty || !$0.hasPrefix(owedLabel) }.prefix(2))
            if !brief.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(brief.enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(2)
                    }
                }
                .font(Fonts.sub)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            if !owed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(owedLabel).font(Fonts.sub).foregroundStyle(.secondary)
                    ForEach(Array(owed.enumerated()), id: \.offset) { _, task in
                        Label { Text(task).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "square").foregroundStyle(.secondary)
                        }
                        .font(Fonts.sub)
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
            if let url {
                let hermes = store.hermesTarget(for: meeting)
                HStack(spacing: 8) {
                    Button { store.open(url) } label: {
                        HStack {
                            Text("Join \(platform ?? "call")")
                            Spacer(minLength: 8)
                            ShortcutHint(keys: "↩")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Join \(platform ?? "call")")
                    if let hermes, store.hermes(hermes).phase == .off {
                        SendHermesButton(target: hermes, store: store)
                    }
                }
                .padding(.top, 12)
                if let hermes {
                    let state = store.hermes(hermes)
                    if state.phase != .off { HermesCard(target: hermes, store: store).padding(.top, 8) }
                }
            } else {
                Text("No call link. Use Record in person below when it starts.")
                    .font(Fonts.sub)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
    }
}

// MARK: List

enum HomeRow: Equatable {
    case event(PanelAgendaItem)
    case recent(AfterContent)
    case recordInPerson

    @MainActor func activate(_ store: PanelStore) {
        switch self {
        case .event(let item):
            if let url = item.meetingURL.flatMap(PanelLinks.url) { store.open(url) }
        case .recent(let row):
            store.navigate(.call(row.sid, fromList: true))
        case .recordInPerson:
            Task { await store.perform(.startInPerson) }
        }
    }
}

extension HomeRow {
    /// The row as the keyboard selection sees it: Hermes changing on a row is not a change to the list.
    var withoutHermes: HomeRow {
        guard case .event(var item) = self else { return self }
        item.hermes = nil
        return .event(item)
    }
}

struct HomeSection {
    let title: String?
    let rows: [(Int, HomeRow)]
}

struct HomeList: View {
    let sections: [HomeSection]
    @Binding var selection: Int?
    let store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Spacer().frame(height: 4)
                }
                ForEach(section.rows, id: \.0) { index, row in
                    HomeRowView(row: row, selected: selection == index, store: store)
                        .onHover { inside in if inside { selection = index } }
                }
            }
        }
        .disabled(store.isBusy)
    }
}

private struct HomeRowView: View {
    let row: HomeRow
    let selected: Bool
    let store: PanelStore

    var body: some View {
        HStack(spacing: 8) {
            Button { row.activate(store) } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .frame(width: 16)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                    HStack(spacing: 6) {
                        Text(title).lineLimit(1).truncationMode(.tail)
                        if let detail {
                            Text(detail)
                                .font(Fonts.sub)
                                .foregroundStyle(selected ? Color.white.opacity(0.8) : (failed ? Palette.record : Color.secondary))
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(Fonts.stamp)
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([title, detail, trailing].compactMap { $0 }.joined(separator: ", "))
            if let hermes {
                HermesRowSwitch(target: hermes, selected: selected, store: store)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Meet calls the mini sent a key for, unless Hermes already took notes in them.
    private var hermes: HermesTarget? {
        guard case .event(let item) = row, let target = store.hermesTarget(for: item), store.hermes(target).phase != .done else { return nil }
        return target
    }

    private var symbol: String {
        switch row {
        case .event(let item): item.meetingURL == nil ? "calendar" : "video"
        case .recent: "doc.text"
        case .recordInPerson: "mic"
        }
    }

    private var title: String {
        switch row {
        case .event(let item): item.title
        case .recent(let row): row.title
        case .recordInPerson: "Record in person"
        }
    }

    private var detail: String? {
        switch row {
        case .event: nil
        case .recent(let row): PanelText.recentDetail(row)
        case .recordInPerson: nil
        }
    }

    private var failed: Bool {
        if case .recent(let row) = row { return row.state == .failed }
        return false
    }

    private var trailing: String? {
        switch row {
        case .event(let item):
            item.start <= store.now ? "Now" : PanelText.clock(item.start, in: store.timeZone, locale: store.locale)
        case .recent(let row):
            (row.startedAt ?? row.endedAt).map { PanelText.past($0, now: store.now, in: store.timeZone, locale: store.locale) }
        case .recordInPerson:
            nil
        }
    }
}

/// Status on the left, the overlay's shortcuts as keycaps on the right.
struct HomeFooter: View {
    let store: PanelStore

    var body: some View {
        HStack(spacing: 12) {
            Text(status)
            Spacer(minLength: 8)
            if let key = store.overlayToggleHint {
                HStack(spacing: 4) { ShortcutHint(keys: key); Text("Overlay") }
            }
            if let key = store.overlaySayHint {
                HStack(spacing: 4) { ShortcutHint(keys: key); Text("What to say") }
            }
        }
        .font(Fonts.tag)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var status: String {
        if let live = store.live { return live.paused ? "Paused" : "Recording" }
        if store.snapshot.phase == .armed { return "Call detected" }
        return store.health.isOK ? "Ready" : "Needs attention"
    }
}
