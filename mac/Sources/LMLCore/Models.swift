import Foundation
import Darwin

public enum Channel: String, Codable, CaseIterable, Sendable {
    case me, them, room
    public var other: Channel? {
        switch self {
        case .me: .them
        case .them: .me
        case .room: nil
        }
    }
    public static func channels(for kind: CaptureKind) -> [Channel] { kind == .call ? [.me, .them] : [.room] }
}

public enum JSON {
    // Building an ISO8601DateFormatter costs far more than using one, and the recorder decodes dates every
    // second. ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) { return date }
            guard let date = whole.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid capture date")
            }
            return date
        }
        return decoder
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(contentsOf: url))
    }
}

public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(JSON.encoder().encode(value), to: url)
    }
}

public struct Config: Codable, Sendable {
    public enum Backend: String, Codable, Sendable { case tap, sck }
    public var system_audio: Backend = .tap
    public var sync_interval_s: Double = 30
    public var in_person_silence_s: Double = 600
    public init(system_audio: Backend = .tap, sync_interval_s: Double = 30, in_person_silence_s: Double = 600) {
        self.system_audio = system_audio; self.sync_interval_s = sync_interval_s; self.in_person_silence_s = in_person_silence_s
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system_audio = try c.decodeIfPresent(Backend.self, forKey: .system_audio) ?? .tap
        sync_interval_s = try c.decodeIfPresent(Double.self, forKey: .sync_interval_s) ?? 30
        in_person_silence_s = try c.decodeIfPresent(Double.self, forKey: .in_person_silence_s) ?? 600
        guard sync_interval_s > 0, in_person_silence_s > 0 else { throw DecodingError.dataCorruptedError(forKey: .sync_interval_s, in: c, debugDescription: "Non-positive interval") }
    }
    public static func load(_ url: URL) throws -> Config {
        FileManager.default.fileExists(atPath: url.path) ? try JSON.read(Config.self, from: url) : Config()
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable {
    public var key: String
    public var start: Date
    public var end: Date
    public var has_conference: Bool
    public var attendee_count: Int
    /// Invitees other than the user who have not declined: how many voices the other side of the call should have.
    public var others: Int?
    public var vocabulary: [String]?
    public init(key: String, start: Date, end: Date, has_conference: Bool = true, attendee_count: Int = 2, others: Int? = nil, vocabulary: [String]? = nil) {
        self.key = key; self.start = start; self.end = end; self.has_conference = has_conference; self.attendee_count = attendee_count
        self.others = others; self.vocabulary = vocabulary
    }
    public var isMeeting: Bool { has_conference || attendee_count >= 2 }
}

public struct Schedule: Codable, Sendable {
    public var generated_at: Date
    public var events: [CalendarEvent]
    public var retention_days: Int?
    enum CodingKeys: String, CodingKey {
        case generated_at = "at"
        case events, retention_days
    }
    private enum LegacyKeys: String, CodingKey { case generated_at }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated_at = try c.decodeIfPresent(Date.self, forKey: .generated_at)
            ?? decoder.container(keyedBy: LegacyKeys.self).decode(Date.self, forKey: .generated_at)
        events = try c.decode([CalendarEvent].self, forKey: .events)
        retention_days = try c.decodeIfPresent(Int.self, forKey: .retention_days)
    }
    public init(generated_at: Date, events: [CalendarEvent] = [], retention_days: Int? = nil) {
        self.generated_at = generated_at; self.events = events; self.retention_days = retention_days
    }
    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(generated_at) <= 900 }
    /// The other side's expected voice count for a capture that matched `keys`, when its meetings agree on one.
    public func others(keys: [String]) -> Int? {
        let counts = Set(events.filter { keys.contains($0.key) }.compactMap(\.others).filter { $0 > 0 })
        return counts.count == 1 ? counts.first : nil
    }
    public func current(at now: Date) -> [CalendarEvent] {
        guard isFresh(at: now) else { return [] }
        return events.filter { $0.isMeeting && now >= $0.start.addingTimeInterval(-120) && now <= $0.end }
    }
    public static let vocabularyLimit = 100
    /// Contextual strings for the meetings in progress at `now`, first occurrence wins.
    public func vocabulary(at now: Date) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for term in current(at: now).flatMap({ $0.vocabulary ?? [] }) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            terms.append(trimmed)
        }
        return Array(terms.prefix(Self.vocabularyLimit))
    }
    public var windowStarts: [Date] {
        events.filter(\.isMeeting).map { event in
            let earliest = event.start.addingTimeInterval(-120)
            return events.filter { $0.key != event.key && $0.end <= event.start && $0.end > earliest }
                .map(\.end).max() ?? earliest
        }.sorted()
    }
}

public struct ProcessRow: Codable, Sendable, Equatable {
    public var bundle: String
    public var input: Bool
    public var output: Bool
    public var pid: Int32
    public var inputDevices: [UInt32]?
    public init(bundle: String, input: Bool = false, output: Bool = false, pid: Int32 = 0, inputDevices: [UInt32]? = nil) {
        self.bundle = bundle; self.input = input; self.output = output; self.pid = pid; self.inputDevices = inputDevices
    }
}

public struct ProcessSnapshot: Codable, Sendable {
    public var procs: [ProcessRow]
    public var ts: Date
    public init(procs: [ProcessRow], ts: Date) { self.procs = procs; self.ts = ts }
}

public struct SessionPaths: Sendable {
    public let root: URL
    public let test: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, test: Bool = false) {
        self.test = test
        root = home.appendingPathComponent("Library/Application Support/LiveMeetingListener\(test ? "-test" : "")")
    }
    public init(root: URL, test: Bool = false) { self.root = root; self.test = test }
    public var sessions: URL { root.appendingPathComponent("sessions") }
    /// Call audio waiting for its speakers to be labeled. Empty whenever no labeling is running.
    public var audio: URL { root.appendingPathComponent("audio") }
    public func session(_ sid: String) -> URL { sessions.appendingPathComponent(sid) }
    public static func validID(_ sid: String) -> Bool {
        sid.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil
    }
    public static func id(at date: Date, suffix: UInt16 = .random(in: .min ... .max)) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + String(format: "-%04x", suffix)
    }
}

public struct Word: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct Recognition: Sendable {
    public var ch: Channel
    public var start: Double
    public var end: Double
    public var words: [Word]
    public var text: String
    public var anchor: Date?
    public var final: Bool
    public var at: Date
    public init(ch: Channel, start: Double, end: Double, words: [Word], final: Bool, at: Date = Date(), text: String? = nil, anchor: Date? = nil) {
        self.ch = ch; self.start = start; self.end = end; self.words = words; self.final = final; self.at = at
        self.text = text ?? words.map(\.text).joined(); self.anchor = anchor
    }
}

public struct TranscriptPart: Codable, Sendable, Equatable {
    public var t0: Date
    public var t1: Date
    public var text: String
    public var xo: Double
    public var words: [[Double]]?
    public init(t0: Date, t1: Date, text: String, xo: Double, words: [[Double]]? = nil) {
        self.t0 = t0; self.t1 = t1; self.text = text; self.xo = xo; self.words = words
    }
    enum CodingKeys: String, CodingKey { case t0, t1, text, xo, words }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t0, forKey: .t0); try c.encode(t1, forKey: .t1)
        try c.encode(text, forKey: .text); try c.encode(xo, forKey: .xo)
        try c.encode(words, forKey: .words)
    }
}
public struct TranscriptRow: Codable, Sendable, Equatable {
    public var v = 1
    public var seq: Int?
    public var ch: Channel
    public var ts0: Date
    public var ts1: Date
    public var at: Date
    public var text: String
    public var xo: Double
    public var parts: [TranscriptPart]
}
public struct LiveSnapshot: Codable, Sendable {
    public var v = 1
    public var sid: String
    public var at: Date
    public var seq_hi: Int
    public var finals: [TranscriptRow]
    public var partials: [String: TranscriptRow?]
    public var speech: [String: [[Date]]]
}
public enum SessionSource: String, Codable, Sendable { case listener, phone, file }

public struct SessionMeta: Codable, Sendable {
    public enum State: String, Codable, Sendable { case active, closed, crashed, failed }
    public var v = 1
    public var sid: String
    public var kind: CaptureKind = .call
    public var source: SessionSource = .listener
    public var state: State = .active
    public var started_at: Date
    public var ended_at: Date?
    public var heartbeat_at: Date
    public var apps: [String] = []
    public var cal_keys: [String] = []
    public var asr = "speechanalyzer/en_US"
    public var segments = 0
    public var test: Bool
    public var me = "off (no other input client)"
    public var warnings: [String] = []
    public var version = 0
    public init(sid: String, started_at: Date, test: Bool = false, kind: CaptureKind = .call) {
        self.sid = sid; self.started_at = started_at; heartbeat_at = started_at; self.test = test; self.kind = kind
        if kind == .inPerson { me = "room" }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        sid = try c.decode(String.self, forKey: .sid)
        kind = try c.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .call
        source = try c.decodeIfPresent(SessionSource.self, forKey: .source) ?? .listener
        state = try c.decode(State.self, forKey: .state)
        started_at = try c.decode(Date.self, forKey: .started_at)
        ended_at = try c.decodeIfPresent(Date.self, forKey: .ended_at)
        heartbeat_at = try c.decode(Date.self, forKey: .heartbeat_at)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        cal_keys = try c.decodeIfPresent([String].self, forKey: .cal_keys) ?? []
        asr = try c.decodeIfPresent(String.self, forKey: .asr) ?? "speechanalyzer/en_US"
        segments = try c.decodeIfPresent(Int.self, forKey: .segments) ?? 0
        test = try c.decodeIfPresent(Bool.self, forKey: .test) ?? false
        me = try c.decodeIfPresent(String.self, forKey: .me) ?? "off (no other input client)"
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }
}

/// One row of `marks.jsonl` (PLAN.md contract C1).
public struct Mark: Codable, Sendable, Equatable {
    public var at: Date
    public var note: String?
    public init(at: Date, note: String?) { self.at = at; self.note = note }
    public func line(in timeZone: TimeZone = .current) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        struct Row: Encodable {
            let at: String, note: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(at, forKey: .at); try c.encode(note, forKey: .note)
            }
            enum CodingKeys: String, CodingKey { case at, note }
        }
        return try JSON.encoder().encode(Row(at: formatter.string(from: at), note: note)) + Data("\n".utf8)
    }
}

/// Who spoke when on the other side of a call, stored as `speakers.json`. Speakers are numbered from 1 in order of
/// first speech. `expected` is the calendar's count of other attendees given to the labeler, when one was known.
public struct SpeakerTurns: Codable, Sendable, Equatable {
    public struct Turn: Codable, Sendable, Equatable {
        public var t0: Date
        public var t1: Date
        public var speaker: Int
        public init(t0: Date, t1: Date, speaker: Int) { self.t0 = t0; self.t1 = t1; self.speaker = speaker }
    }
    public var v = 1
    public var expected: Int?
    public var turns: [Turn]
    public init(expected: Int?, turns: [Turn]) { self.expected = expected; self.turns = turns }
    /// `segments` hold the labeler's speaker ids and seconds from `start`, the time of the audio's first sample.
    public init(start: Date, expected: Int?, segments: [(speaker: String, from: Double, to: Double)]) {
        var numbers: [String: Int] = [:]
        turns = segments.filter { $0.to > $0.from }.sorted { $0.from < $1.from }.map { segment in
            let number = numbers[segment.speaker] ?? numbers.count + 1
            numbers[segment.speaker] = number
            return Turn(t0: start.addingTimeInterval(segment.from), t1: start.addingTimeInterval(segment.to), speaker: number)
        }
        self.expected = expected
    }

    /// Voices this alike are one person split in two. On test calls a split scored 0.77 to 0.95 and two different
    /// people at most 0.79, so this catches most splits without merging two people.
    static let sameVoice: Float = 0.85

    /// Each speaker id mapped to the first id, in sorted order, of the group of voices that sound alike.
    public static func merged(_ voices: [String: [Float]]) -> [String: String] {
        let ids = voices.keys.sorted()
        var root = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func find(_ id: String) -> String { root[id] == id ? id : find(root[id]!) }
        for (index, a) in ids.enumerated() {
            for b in ids[(index + 1)...] where cosine(voices[a]!, voices[b]!) >= sameVoice {
                let (x, y) = (find(a), find(b))
                root[max(x, y)] = min(x, y)
            }
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, find($0)) })
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norms = (a.reduce(Float(0)) { $0 + $1 * $1 } * b.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        return norms > 0 ? dot / norms : 0
    }
}
