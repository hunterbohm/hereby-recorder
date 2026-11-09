import Foundation
import LMLCore

public enum PanelRules {
    public static let width: CGFloat = 380
    public static let conversationHeight: CGFloat = 280
    public static let beforeLead: TimeInterval = 15 * 60
    public static let beforeTailWithoutEnd: TimeInterval = 15 * 60
    public static let afterWindow: TimeInterval = 30 * 60
    public static let feedStaleAfter: TimeInterval = 10 * 60
    public static let feedGrace: TimeInterval = 2 * 60
    public static let actionTimeout: Duration = .seconds(30)
    public static let recentRows = 4
    public static let briefLines = 3
    public static let markFlash: TimeInterval = 1.5
    public static let filedFlash: TimeInterval = 10
    /// How long the panel keeps showing what the user asked of Hermes while no newer feed arrives.
    public static let hermesHold: TimeInterval = 3 * 60
}

public struct Health: Equatable, Sendable {
    public var micOK: Bool
    public var audioOK: Bool
    public var miniReachable: Bool
    public var lastContact: Date?

    public init(micOK: Bool, audioOK: Bool, miniReachable: Bool, lastContact: Date?) {
        self.micOK = micOK; self.audioOK = audioOK; self.miniReachable = miniReachable; self.lastContact = lastContact
    }

    public var captureOK: Bool { micOK && audioOK }
    public var isOK: Bool { captureOK && miniReachable }

    /// `graceStart` is launch or the last wake from sleep: a missing or old feed is not a problem until the
    /// heartbeat has had `feedGrace` to refresh it. Without a mini nothing syncs, so no feed is ever missing.
    public static func resolve(_ snapshot: RecorderSnapshot, now: Date, graceStart: Date, hasMini: Bool = true) -> Health {
        let fresh = snapshot.feed.map { now.timeIntervalSince($0.at) <= PanelRules.feedStaleAfter } ?? false
        let reachable = !hasMini || fresh || now.timeIntervalSince(graceStart) <= PanelRules.feedGrace
        return Health(micOK: snapshot.micOK, audioOK: snapshot.audioOK, miniReachable: reachable, lastContact: snapshot.feed?.at)
    }
}

public enum Flash: Equatable, Sendable {
    case marked, markMissed, filed
}

public struct FlashState: Equatable, Sendable {
    public var kind: Flash
    public var until: Date

    public init(kind: Flash, until: Date) { self.kind = kind; self.until = until }

    public func active(at now: Date) -> Flash? { now < until ? kind : nil }
}

public enum StatusIcon: Equatable, Sendable {
    case idle, armed, recording, paused, filed, marked, markMissed
    case problem(Health)

    public static func resolve(_ snapshot: RecorderSnapshot, health: Health, flash: Flash?) -> StatusIcon {
        if flash == .marked { return .marked }
        if flash == .markMissed { return .markMissed }
        if !health.captureOK { return .problem(health) }
        if snapshot.phase == .recording { return .recording }
        if snapshot.phase == .paused { return .paused }
        if !health.miniReachable { return .problem(health) }
        if flash == .filed { return .filed }
        return snapshot.phase == .armed ? .armed : .idle
    }

}

public struct AskEntry: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case waiting
        /// The fast answer so far, while more of it is arriving.
        case streaming(String)
        case answered(String)
        case failed

        public var isPending: Bool {
            switch self {
            case .waiting, .streaming: true
            case .answered, .failed: false
            }
        }
    }

    public let id: UUID
    public var question: String
    public var kind: QuickAsk
    public var at: Date
    public var status: Status

    public init(id: UUID = UUID(), question: String, kind: QuickAsk = .ask, at: Date, status: Status = .waiting) {
        self.id = id; self.question = question; self.kind = kind; self.at = at; self.status = status
    }
}

/// What the panel keeps about the live session beyond the latest snapshot: questions asked during it, every warning
/// the mini has reported for it, and the last recording snapshot once a pause has ended the capture.
public struct SessionMemory: Equatable, Sendable {
    public var sid: String
    public var asks: [AskEntry] = []
    public var warnings: [Int: PanelWarning] = [:]
    public var pausedFrom: RecorderSnapshot?
    public var pausedAt: Date?

    public init(sid: String) { self.sid = sid }
}

public enum ConversationItem: Equatable, Sendable, Identifiable {
    case line(TranscriptLine)
    case mark(Date)
    case warning(PanelWarning)
    case ask(AskEntry)

    public var id: String {
        switch self {
        case .line(let line): "l\(line.at.timeIntervalSince1970)\(line.speaker)"
        case .mark(let at): "m\(at.timeIntervalSince1970)"
        case .warning(let warning): "w\(warning.n)"
        case .ask(let entry): "a\(entry.id)"
        }
    }

    var at: Date {
        switch self {
        case .line(let line): line.at
        case .mark(let at): at
        case .warning(let warning): warning.at
        case .ask(let entry): entry.at
        }
    }

    var rank: Int {
        switch self {
        case .line: 0
        case .mark: 1
        case .warning: 2
        case .ask: 3
        }
    }

    /// Everything said, marked, warned, and asked, in time order; at the same instant a line comes before what refers to it.
    public static func merge(lines: [TranscriptLine], marks: [Date], warnings: [PanelWarning], asks: [AskEntry]) -> [ConversationItem] {
        let items = lines.map(ConversationItem.line) + marks.map(ConversationItem.mark)
            + warnings.map(ConversationItem.warning) + asks.map(ConversationItem.ask)
        return items.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// What the user can do to Hermes for one calendar event.
public enum HermesChange: Equatable, Sendable {
    /// Send Hermes to the call, or turn its row switch on.
    case join
    /// Cancel it, or remove it from the call.
    case leave
    case chat(Bool)
}

extension PanelHermes {
    /// What the panel shows the moment the user acts, before the mini answers. Joining keeps the chat setting the mini
    /// reported; leaving resets it.
    public func applying(_ change: HermesChange) -> PanelHermes {
        switch change {
        case .join: PanelHermes(phase: .scheduled, chat: chat)
        case .leave: .off
        case .chat(let on): PanelHermes(phase: phase, chat: on, error: error)
        }
    }
}

/// One calendar event the user can send Hermes to: the key the mini knows it by, and what the feed says about it.
public struct HermesTarget: Equatable, Sendable {
    public var key: String
    public var title: String
    public var start: Date
    public var feed: PanelHermes

    public init(key: String, title: String, start: Date, feed: PanelHermes) {
        self.key = key; self.title = title; self.start = start; self.feed = feed
    }

    init?(_ meeting: PanelMeeting) {
        guard let key = meeting.key, !key.isEmpty else { return nil }
        self.init(key: key, title: meeting.title, start: meeting.start, feed: meeting.hermesState)
    }

    init?(_ item: PanelAgendaItem) {
        guard let key = item.key, !key.isEmpty else { return nil }
        self.init(key: key, title: item.title, start: item.start, feed: item.hermesState)
    }

    /// The event a capture matched, found by the start and title the recorder took from the feed.
    static func matching(_ feed: PanelFeed?, start: Date, title: String?) -> HermesTarget? {
        guard let feed else { return nil }
        let fits: (String, Date) -> Bool = { name, at in at == start && (title == nil || title == name) }
        if let next = feed.next, fits(next.title, next.start), let target = HermesTarget(next) { return target }
        return (feed.today ?? []).first { fits($0.title, $0.start) && $0.key != nil }.flatMap(HermesTarget.init)
    }
}

public struct LiveContent: Equatable, Sendable {
    public var sid: String?
    public var kind: CaptureKind
    public var title: String
    public var platform: String?
    public var startedAt: Date?
    public var themName: String?
    /// Set while paused: the capture stopped here, so the timer stops too.
    public var stoppedAt: Date?
    public var marks: Int
    public var items: [ConversationItem]
    /// The calendar event this call matched, when the mini sent its key.
    public var hermes: HermesTarget?

    init(_ snapshot: RecorderSnapshot, memory: SessionMemory?, stoppedAt: Date? = nil) {
        sid = snapshot.sid
        kind = snapshot.kind
        title = snapshot.title ?? (snapshot.sid == nil ? "Recording paused" : snapshot.kind == .inPerson ? "In-person meeting" : "Untitled call")
        if let start = snapshot.eventStart, let next = snapshot.feed?.next, next.start == start {
            platform = next.meetingURL.flatMap(PanelLinks.url).flatMap(PanelLinks.platform)
        }
        startedAt = snapshot.startedAt
        themName = snapshot.themName
        hermes = snapshot.eventStart.flatMap { HermesTarget.matching(snapshot.feed, start: $0, title: snapshot.title) }
        self.stoppedAt = stoppedAt
        marks = max(snapshot.marks, snapshot.markTimes.count)
        let own = memory.flatMap { $0.sid == snapshot.sid ? $0 : nil }
        var warnings = own?.warnings ?? [:]
        if let live = snapshot.feed?.live, live.sid == snapshot.sid {
            for warning in live.warnings where warnings[warning.n] == nil { warnings[warning.n] = warning }
        }
        items = ConversationItem.merge(lines: snapshot.lines, marks: snapshot.markTimes,
                                       warnings: warnings.values.sorted { $0.n < $1.n }, asks: own?.asks ?? [])
    }
}

public struct AfterContent: Equatable, Sendable {
    public var sid: String
    public var title: String
    public var state: FilingState
    public var startedAt: Date?
    public var endedAt: Date?
    public var duration: TimeInterval?
    public var marks: Int?
    public var note: String?
    public var noteURL: URL?
    public var review: PanelReview?
    public var snippet: String?
    public var summary: [String] = []
    public var moments: [PanelMoment]?
    public var pinned = false
    /// The recorder holds this ended call until then in case it comes back, and files it after.
    public var heldUntil: Date?

    init(_ row: PanelRecent, local: RecorderSnapshot) {
        sid = row.sid
        title = row.title
        state = row.state
        endedAt = row.endedAt
        note = row.note
        noteURL = row.noteURL.flatMap(PanelLinks.url)
        review = row.review
        snippet = row.snippet
        summary = Array((row.summary ?? []).prefix(3))
        moments = row.markedMoments
        marks = row.marks
        duration = row.durationS.map(TimeInterval.init)
        if local.sid == row.sid {
            marks = marks ?? local.marks
            startedAt = local.startedAt
            heldUntil = local.heldUntil
            if duration == nil, let start = local.startedAt, let end = row.endedAt { duration = end.timeIntervalSince(start) }
        }
        if startedAt == nil, let end = endedAt, let duration { startedAt = end.addingTimeInterval(-duration) }
    }

    init?(endedLocally snapshot: RecorderSnapshot) {
        guard snapshot.phase == .ended, let sid = snapshot.sid else { return nil }
        self.sid = sid
        title = snapshot.title ?? (snapshot.kind == .inPerson ? "In-person meeting" : "Untitled call")
        state = .waiting
        startedAt = snapshot.startedAt
        marks = snapshot.marks
        heldUntil = snapshot.heldUntil
    }

    static func known(_ snapshot: RecorderSnapshot, forgotten: Set<String>) -> [AfterContent] {
        var rows = (snapshot.feed?.recent ?? []).map { AfterContent($0, local: snapshot) }
        if let local = AfterContent(endedLocally: snapshot), !rows.contains(where: { $0.sid == local.sid }) {
            rows.insert(local, at: 0)
        }
        return rows.filter { !forgotten.contains($0.sid) }
    }
}

public struct BeforeContent: Equatable, Sendable {
    public var meeting: PanelMeeting
    public var platform: String?
    public var joinURL: URL?
    public var briefURL: URL?
    public var lastCall: AfterContent?
    /// The rest of today, as on the idle screen, so the list below the next call keeps what comes after it.
    public var today: [PanelAgendaItem] = []

    init(_ meeting: PanelMeeting, lastCall: AfterContent?, today: [PanelAgendaItem] = []) {
        self.meeting = meeting
        self.today = today
        joinURL = meeting.meetingURL.flatMap(PanelLinks.url)
        platform = joinURL.flatMap(PanelLinks.platform)
        briefURL = meeting.note.flatMap(PanelLinks.url)
        self.lastCall = lastCall
    }

    static func isSoon(_ meeting: PanelMeeting, now: Date) -> Bool {
        let opens = meeting.start.addingTimeInterval(-PanelRules.beforeLead)
        let closes = meeting.end ?? meeting.start.addingTimeInterval(PanelRules.beforeTailWithoutEnd)
        return now >= opens && now < closes
    }

    public var brief: [String] { Array(meeting.brief.prefix(PanelRules.briefLines)) }
    public var owed: [String] { meeting.owed ?? [] }
    public var owedLabel: String { "You owe \(meeting.with ?? "them")" }
}

public struct IdleContent: Equatable, Sendable {
    public var next: PanelMeeting?
    /// The rest of today from every calendar, minus what ended since the mini last wrote it.
    public var today: [PanelAgendaItem] = []
    public var recent: [AfterContent]
    public var connecting: Bool
}

public struct AccessContent: Equatable, Sendable {
    public var micOK: Bool
    public var audioOK: Bool
    /// The next meeting with a call link that hasn't started, when the mini's alert would text about it.
    public var next: PanelMeeting?
}

public enum PanelFocus: Equatable, Sendable {
    case auto
    case list
    case call(String, fromList: Bool)

    var back: PanelFocus {
        if case .call(_, true) = self { return .list }
        return .auto
    }
}

public enum PanelScreen: Equatable, Sendable {
    case idle(IdleContent)
    case before(BeforeContent)
    case recording(LiveContent)
    case paused(LiveContent)
    case after(AfterContent)
    case access(AccessContent)

    public static func resolve(_ snapshot: RecorderSnapshot, now: Date, focus: PanelFocus = .auto,
                               forgotten: Set<String> = [], memory: SessionMemory? = nil, hasMini: Bool = true) -> PanelScreen {
        let live: PanelScreen?
        switch snapshot.phase {
        case .recording:
            live = .recording(LiveContent(snapshot, memory: memory))
        case .paused:
            if snapshot.sid == nil, let memory, let frame = memory.pausedFrom, !forgotten.contains(memory.sid) {
                live = .paused(LiveContent(frame, memory: memory, stoppedAt: memory.pausedAt))
            } else {
                live = .paused(LiveContent(snapshot, memory: memory))
            }
        case .idle, .armed, .ended:
            live = nil
        }
        // During a call the panel shows the call, unless the user opened the list or a past call from it.
        if let live, focus == .auto { return live }
        let known = AfterContent.known(snapshot, forgotten: forgotten)
        let idle = IdleContent(next: snapshot.feed?.next, today: (snapshot.feed?.today ?? []).filter { $0.end > now },
                               recent: Array(known.prefix(PanelRules.recentRows)), connecting: hasMini && snapshot.feed == nil)
        switch focus {
        case .call(let sid, _):
            if var row = known.first(where: { $0.sid == sid }) {
                row.pinned = true
                return .after(row)
            }
        case .list:
            return .idle(idle)
        case .auto:
            break
        }
        if let live { return live }
        let justEnded = known.first.flatMap { row -> AfterContent? in
            if let ended = row.endedAt { return now.timeIntervalSince(ended) < PanelRules.afterWindow ? row : nil }
            return row.sid == snapshot.sid && snapshot.phase == .ended ? row : nil
        }
        if let next = snapshot.feed?.next, BeforeContent.isSoon(next, now: now) {
            return .before(BeforeContent(next, lastCall: justEnded, today: idle.today))
        }
        if let justEnded { return .after(justEnded) }
        if !snapshot.micOK || !snapshot.audioOK {
            let next = snapshot.feed?.next.flatMap { $0.meetingURL != nil && $0.start > now ? $0 : nil }
            return .access(AccessContent(micOK: snapshot.micOK, audioOK: snapshot.audioOK, next: next))
        }
        return .idle(idle)
    }

    var subject: String {
        switch self {
        case .idle: "idle"
        case .before(let content): "before:\(content.meeting.title)@\(content.meeting.start.timeIntervalSince1970)"
        case .recording(let content): "recording:\(content.sid ?? "")"
        case .paused(let content): "paused:\(content.sid ?? "")"
        case .after(let content): "after:\(content.sid)"
        case .access: "access"
        }
    }
}

public enum PanelLinks {
    public static func url(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    /// Hermes joins Google Meet calls only.
    public static func isMeet(_ string: String?) -> Bool {
        string.flatMap(url).flatMap(platform) == "Google Meet"
    }

    public static func platform(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let known: [(suffix: String, name: String)] = [
            ("zoom.us", "Zoom"), ("meet.google.com", "Google Meet"), ("teams.microsoft.com", "Teams"),
            ("teams.live.com", "Teams"), ("webex.com", "Webex"), ("whereby.com", "Whereby"), ("around.co", "Around")
        ]
        return known.first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?.name
    }
}
