import Foundation

public enum RecorderPhase: String, Codable, Sendable {
    case idle, armed, recording, paused, ended
}

public enum CaptureKind: String, Codable, Sendable {
    case call
    case inPerson = "in_person"
}

public struct TranscriptLine: Codable, Sendable, Equatable {
    public var speaker: String
    public var text: String
    public var at: Date
    public init(speaker: String, text: String, at: Date) {
        self.speaker = speaker; self.text = text; self.at = at
    }
}

/// Whether Hermes's notetaker bot is set to join a calendar event, and how far along it is, as the mini reports it.
/// Decoding never fails: a missing, malformed or unknown value reads as off, so a mini that predates the field (or
/// adds a state this Mac doesn't know) leaves the rest of the feed intact.
public struct PanelHermes: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case off, scheduled, joining
        case waitingRoom = "waiting_room"
        case inCall = "in_call"
        case done, failed
    }

    public var phase: Phase
    /// Hermes answers questions addressed to it in the meeting chat.
    public var chat: Bool
    /// One line from the mini when `phase` is `failed`.
    public var error: String?

    public static let off = PanelHermes(phase: .off)

    public init(phase: Phase, chat: Bool = false, error: String? = nil) {
        self.phase = phase; self.chat = chat; self.error = error
    }

    enum CodingKeys: String, CodingKey { case phase = "state", chat, error }

    public init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = .off; return }
        let raw = (try? c.decodeIfPresent(String.self, forKey: .phase)) ?? nil
        phase = raw.flatMap(Phase.init(rawValue:)) ?? .off
        chat = ((try? c.decodeIfPresent(Bool.self, forKey: .chat)) ?? nil) ?? false
        let reason = ((try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        error = reason?.isEmpty == false ? reason : nil
    }

    /// Hermes is set to join this call, or is in it, or tried and failed: the states that show Cancel or Remove.
    public var isOn: Bool {
        switch phase {
        case .scheduled, .joining, .waitingRoom, .inCall, .failed: true
        case .off, .done: false
        }
    }
}

public struct PanelMeeting: Codable, Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var meetingURL: String?
    public var note: String?
    public var noteURL: String?
    public var brief: [String]
    /// The user's open tasks owed to the attendees, one title each.
    public var owed: [String]?
    /// The other person's first name when the meeting has exactly one attendee besides the user.
    public var with: String?
    /// The calendar event's key, which the panel sends back to the mini to pick this call for Hermes. Nil from a mini
    /// that doesn't send it, which hides the Hermes controls.
    public var key: String?
    /// Nil from a mini that predates it; read `hermesState`.
    public var hermes: PanelHermes?
    enum CodingKeys: String, CodingKey {
        case title, start, end, note, brief, owed, with, key, hermes
        case meetingURL = "meeting_url"
        case noteURL = "note_url"
    }
    public init(title: String, start: Date, end: Date? = nil, meetingURL: String? = nil,
                note: String? = nil, noteURL: String? = nil, brief: [String] = [], owed: [String]? = nil, with: String? = nil,
                key: String? = nil, hermes: PanelHermes? = nil) {
        self.title = title; self.start = start; self.end = end; self.meetingURL = meetingURL
        self.note = note; self.noteURL = noteURL; self.brief = brief; self.owed = owed; self.with = with
        self.key = key; self.hermes = hermes
    }
    public var hermesState: PanelHermes { hermes ?? .off }
}

public enum FilingState: String, Codable, Sendable {
    case waiting, filing, filed, skipped, failed
}

public struct PanelReview: Codable, Sendable, Equatable {
    public var sent: Bool
    public var tasks: Int
    /// The user answered the review on their phone, so its tasks were applied or declined.
    public var answered: Bool
    public init(sent: Bool, tasks: Int, answered: Bool = false) { self.sent = sent; self.tasks = tasks; self.answered = answered }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decode(Bool.self, forKey: .sent); tasks = try c.decode(Int.self, forKey: .tasks)
        answered = try c.decodeIfPresent(Bool.self, forKey: .answered) ?? false
    }
}

/// A marked moment in a filed meeting: when, and the transcript line at that time.
public struct PanelMoment: Codable, Sendable, Equatable {
    public var at: Date
    public var text: String
    public init(at: Date, text: String) { self.at = at; self.text = text }
}

/// A mid-call warning Hermes texted during the live session; n counts from 1 (at most 3).
public struct PanelWarning: Codable, Sendable, Equatable {
    public var at: Date
    public var text: String
    public var n: Int
    public init(at: Date, text: String, n: Int) { self.at = at; self.text = text; self.n = n }
}

public struct PanelLive: Codable, Sendable, Equatable {
    public var sid: String
    public var warnings: [PanelWarning]
    public init(sid: String, warnings: [PanelWarning] = []) { self.sid = sid; self.warnings = warnings }
}

public struct PanelRecent: Codable, Sendable, Equatable {
    public var sid: String
    public var title: String
    public var endedAt: Date?
    public var durationS: Int?
    public var marks: Int?
    public var state: FilingState
    public var note: String?
    public var noteURL: String?
    public var review: PanelReview?
    /// One line about the meeting, for the recent list.
    public var snippet: String?
    /// Up to three bullets from the filed note's Summary.
    public var summary: [String]?
    public var markedMoments: [PanelMoment]?
    enum CodingKeys: String, CodingKey {
        case sid, title, state, note, review, marks, snippet, summary
        case markedMoments = "marked_moments"
        case endedAt = "ended_at"
        case durationS = "duration_s"
        case noteURL = "note_url"
    }
    public init(sid: String, title: String, endedAt: Date? = nil, durationS: Int? = nil,
                marks: Int? = nil, state: FilingState, note: String? = nil,
                noteURL: String? = nil, review: PanelReview? = nil, snippet: String? = nil,
                summary: [String]? = nil, markedMoments: [PanelMoment]? = nil) {
        self.sid = sid; self.title = title; self.endedAt = endedAt; self.durationS = durationS
        self.marks = marks; self.state = state; self.note = note; self.noteURL = noteURL
        self.review = review; self.snippet = snippet; self.summary = summary
        self.markedMoments = markedMoments
    }
}

/// One event from the rest of today, from every calendar account the mini reads.
public struct PanelAgendaItem: Codable, Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var meetingURL: String?
    /// A call or an event with other people, so the recorder would pick it up.
    public var meeting: Bool
    /// The calendar event's key (see `PanelMeeting.key`).
    public var key: String?
    /// Nil from a mini that predates it; read `hermesState`.
    public var hermes: PanelHermes?
    enum CodingKeys: String, CodingKey {
        case title, start, end, meeting, key, hermes
        case meetingURL = "meeting_url"
    }
    public init(title: String, start: Date, end: Date, meetingURL: String? = nil, meeting: Bool = true,
                key: String? = nil, hermes: PanelHermes? = nil) {
        self.title = title; self.start = start; self.end = end; self.meetingURL = meetingURL; self.meeting = meeting
        self.key = key; self.hermes = hermes
    }
    public var hermesState: PanelHermes { hermes ?? .off }
}

/// The mini's `status.json` (PLAN.md contract C4).
public struct PanelFeed: Codable, Sendable, Equatable {
    public var v: Int
    public var at: Date
    public var next: PanelMeeting?
    /// The rest of today; nil from a mini that predates it.
    public var today: [PanelAgendaItem]?
    public var recent: [PanelRecent]
    /// The session being recorded now, as the mini sees it.
    public var live: PanelLive?
    public init(v: Int = 1, at: Date, next: PanelMeeting? = nil, today: [PanelAgendaItem]? = nil, recent: [PanelRecent] = [],
                live: PanelLive? = nil) {
        self.v = v; self.at = at; self.next = next; self.today = today; self.recent = recent; self.live = live
    }
}

public struct RecorderSnapshot: Sendable, Equatable {
    public var phase: RecorderPhase
    public var sid: String?
    public var kind: CaptureKind
    public var title: String?
    public var eventStart: Date?
    public var startedAt: Date?
    /// The current session's transcript lines, oldest first, at most the last 400.
    public var lines: [TranscriptLine]
    public var marks: Int
    public var markTimes: [Date]
    public var micOK: Bool
    public var audioOK: Bool
    public var feed: PanelFeed?
    /// The other person's first name on a 1:1 call matched to a calendar event; the panel shows it for "them".
    public var themName: String?
    /// When the last sync-status call to the mini succeeded; nil until the first one does.
    public var feedReceivedAt: Date?
    /// The last session this run forgot, from any route (the panel, the command line, the mini), so the panel never
    /// keeps showing it as paused.
    public var forgottenSid: String?
    /// Set while the ended call `sid` is held in case it comes back: when it files if it does not.
    public var heldUntil: Date?
    public init(phase: RecorderPhase = .idle, sid: String? = nil, kind: CaptureKind = .call,
                title: String? = nil, eventStart: Date? = nil, startedAt: Date? = nil,
                lines: [TranscriptLine] = [], marks: Int = 0, markTimes: [Date] = [], micOK: Bool = true,
                audioOK: Bool = true, feed: PanelFeed? = nil, themName: String? = nil, feedReceivedAt: Date? = nil,
                forgottenSid: String? = nil) {
        self.phase = phase; self.sid = sid; self.kind = kind; self.title = title
        self.eventStart = eventStart; self.startedAt = startedAt; self.lines = lines
        self.marks = marks; self.markTimes = markTimes; self.micOK = micOK; self.audioOK = audioOK; self.feed = feed
        self.themName = themName; self.feedReceivedAt = feedReceivedAt; self.forgottenSid = forgottenSid
    }
}

/// A fast question about the live call. Each kind but `ask` is a one-tap button whose question the mini supplies.
public enum QuickAsk: String, Codable, Sendable, CaseIterable {
    case ask, say, recap, asked, check, screen
}

/// What `live-meeting-quick` reads on stdin: the question, and the latest lines the Mac heard, which the mini may not
/// have synced yet.
/// `sid` lets the mini tell a call it has not synced yet from the one before it.
/// `screen` is a base64 JPEG of the screen at the moment of asking (`ScreenGrab`), when there is one.
public struct LiveAskRequest: Codable, Sendable, Equatable {
    public var kind: QuickAsk
    public var question: String
    public var sid: String?
    public var lines: [TranscriptLine]
    public var screen: String?
    public init(kind: QuickAsk, question: String, sid: String? = nil, lines: [TranscriptLine] = [], screen: String? = nil) {
        self.kind = kind; self.question = question; self.sid = sid; self.lines = lines; self.screen = screen
    }
}

/// What the menu bar panel can ask the recorder to do (PLAN.md contract C7).
public protocol RecorderActions: Sendable {
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func forget(sid: String) async throws
    func markMoment(note: String?) async throws
    func startInPerson() async throws
    func ask(_ question: String) async throws -> String
    /// A fast answer about the live call; `onText` gets the answer so far each time more of it arrives.
    func askLive(_ request: LiveAskRequest, onText: @escaping @Sendable (String) -> Void) async throws -> String
    /// Ask about any past meeting, not only the current call.
    func askAnyMeeting(_ question: String) async throws -> String
    /// Hermes joins the calendar event `key` (`meeting-bot optin`), leaves or doesn't come (`optout`), or turns chat
    /// replies on or off for it (`chat`).
    func hermesOptIn(key: String) async throws
    func hermesOptOut(key: String) async throws
    func hermesChat(key: String, on: Bool) async throws
}

/// Live recorder state for the panel. `observe` delivers the current snapshot, then every change.
public protocol RecorderModel: AnyObject, Sendable {
    var snapshot: RecorderSnapshot { get }
    func observe(_ handler: @escaping @Sendable (RecorderSnapshot) -> Void)
}
