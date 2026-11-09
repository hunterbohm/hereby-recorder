import Foundation

public struct ImportRoot: Sendable {
    public let url: URL
    public init(_ url: URL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveMeetingListener/imports")
    }
    public var sessions: URL { url.appendingPathComponent("sessions") }
    public var ledger: URL { url.appendingPathComponent("ledger.json") }
    public func session(_ sid: String) -> URL { sessions.appendingPathComponent(sid) }
}

public struct LedgerEntry: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case written, pushed, done, forgotten, empty }
    public var sid: String
    public var state: State
    public var title: String?
    public var imported_at: Date
}

public struct Outcome: Encodable, Sendable, Equatable {
    public enum Kind: String, Encodable, Sendable { case imported, pushed, done, pending, skipped, failed }
    public var id: String
    public var outcome: Kind
    public var reason: String?
    public var sid: String?
    public var rows: Int?
    public var duration: Double?
    public var first_ts0: Date?
    /// Ledger state after this run; nil when the recording is not in the ledger.
    public var state: LedgerEntry.State?

    enum CodingKeys: String, CodingKey { case id, outcome, reason, sid, rows, duration, first_ts0 }

    public init(id: String, outcome: Kind, reason: String? = nil, sid: String? = nil, rows: Int? = nil,
                duration: Double? = nil, first_ts0: Date? = nil, state: LedgerEntry.State? = nil) {
        self.id = id; self.outcome = outcome; self.reason = reason; self.sid = sid; self.rows = rows
        self.duration = duration; self.first_ts0 = first_ts0; self.state = state
    }

    /// Inbox files move to Imported/ once the ledger accounts for them, including silent and forgotten ones.
    public var isImported: Bool { state != nil }
}

public actor Importer {
    public static let defaultTranscriptWait: TimeInterval = 30 * 60

    private let root: ImportRoot
    private let transcriber: any AudioTranscriber
    private let pusher: Pusher?
    private let now: Date
    private let transcriptWait: TimeInterval
    private let timeZone: TimeZone
    private var ledger: [String: LedgerEntry]

    public init(root: ImportRoot, transcriber: any AudioTranscriber, pusher: Pusher? = nil, now: Date = Date(),
                transcriptWait: TimeInterval = Importer.defaultTranscriptWait, timeZone: TimeZone = .current) throws {
        self.root = root; self.transcriber = transcriber; self.pusher = pusher; self.now = now
        self.transcriptWait = transcriptWait; self.timeZone = timeZone
        ledger = FileManager.default.fileExists(atPath: root.ledger.path)
            ? try JSON.decoder().decode([String: LedgerEntry].self, from: Data(contentsOf: root.ledger)) : [:]
    }

    public func entry(_ id: String) -> LedgerEntry? { ledger[id] }

    public func run(_ recordings: [Recording]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for recording in recordings { outcomes.append(await run(recording)) }
        return outcomes
    }

    public func run(_ recording: Recording) async -> Outcome {
        let base = Outcome(id: recording.id, outcome: .skipped, state: ledger[recording.id]?.state)
        switch base.state {
        case .done?, .forgotten?, .empty?:
            return skipped(base)
        case .written?, .pushed?:
            if hasSessionFiles(ledger[recording.id]!.sid) {
                return pusher == nil ? skipped(base) : await push(recording.id, outcome: base)
            }
            fallthrough
        case nil:
            let imported: Outcome
            do {
                guard let result = try await importSession(recording) else { return pending(base, recording) }
                imported = result
            } catch {
                var failed = base
                failed.outcome = .failed; failed.reason = "transcription failed: \(Self.describe(error))"
                return failed
            }
            return imported.state == .written && pusher != nil ? await push(recording.id, outcome: imported) : imported
        }
    }

    /// Pushes ledger sessions not presented this run, such as inbox files already moved or deleted notes.
    public func pushBacklog(excluding ids: Set<String>) async -> [Outcome] {
        guard pusher != nil else { return [] }
        var outcomes: [Outcome] = []
        for (id, entry) in ledger.sorted(by: { $0.key < $1.key })
        where !ids.contains(id) && (entry.state == .written || entry.state == .pushed) {
            outcomes.append(await push(id, outcome: Outcome(id: id, outcome: .skipped, state: entry.state)))
        }
        return outcomes
    }

    private func importSession(_ recording: Recording) async throws -> Outcome? {
        if recording.transcript == nil, recording.audio == nil { return nil }
        if recording.source == .phone, recording.transcript == nil,
           now < recording.startedAt.addingTimeInterval(recording.duration + transcriptWait) { return nil }
        let utterances: [Utterance]
        if let transcript = recording.transcript { utterances = transcript }
        else { utterances = try await transcriber.transcribe(recording.audio!) }
        let session = SessionBuilder.build(recording, utterances: utterances,
            asr: recording.transcript != nil ? SessionBuilder.appleASR : SessionBuilder.speechASR, timeZone: timeZone)
        let sid = session.meta.sid
        var outcome = Outcome(id: recording.id, outcome: .imported, sid: sid, rows: session.rows.count,
            duration: recording.duration, first_ts0: session.rows.first?.ts0)
        if session.rows.isEmpty {
            try record(recording, sid: sid, state: .empty)
            outcome.outcome = .skipped; outcome.reason = "no speech"; outcome.state = .empty
            return outcome
        }
        try write(session)
        try record(recording, sid: sid, state: .written)
        outcome.state = .written
        return outcome
    }

    private func push(_ id: String, outcome: Outcome) async -> Outcome {
        guard let pusher, var entry = ledger[id] else { return outcome }
        var outcome = outcome
        outcome.sid = entry.sid
        let directory = root.session(entry.sid)
        do {
            if entry.state == .written {
                if try await pusher.send(sid: entry.sid, directory: directory) == .forgotten {
                    entry.state = .forgotten; try save(id, entry)
                    outcome.outcome = .skipped; outcome.reason = "forgotten on the mini"; outcome.state = .forgotten
                    return outcome
                }
                entry.state = .pushed; try save(id, entry)
                outcome.outcome = .pushed; outcome.state = .pushed
            }
            let bytes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("transcript.jsonl").path)[.size] as? Int ?? 0
            switch try await pusher.signalDone(sid: entry.sid, transcriptBytes: bytes) {
            case .forgotten:
                entry.state = .forgotten; try save(id, entry)
                outcome.outcome = .skipped; outcome.reason = "forgotten on the mini"; outcome.state = .forgotten
            case .done:
                entry.state = .done; try save(id, entry)
                outcome.outcome = .done; outcome.reason = nil; outcome.state = .done
            case .stale:
                entry.state = .written; try save(id, entry)
                outcome.outcome = .failed; outcome.reason = "mini transcript size differs; resending next run"; outcome.state = .written
            }
        } catch {
            outcome.outcome = .failed; outcome.reason = "push failed: \(Self.describe(error))"
        }
        return outcome
    }

    private func hasSessionFiles(_ sid: String) -> Bool {
        ["transcript.jsonl", "meta.json"].allSatisfy { FileManager.default.fileExists(atPath: root.session(sid).appendingPathComponent($0).path) }
    }

    private func skipped(_ outcome: Outcome) -> Outcome {
        var outcome = outcome
        outcome.sid = ledger[outcome.id]?.sid
        outcome.reason = switch outcome.state {
        case .written?: "already imported"
        case .pushed?: "already pushed"
        case .done?: "already done"
        case .forgotten?: "forgotten on the mini"
        case .empty?: "no speech"
        case nil: nil
        }
        return outcome
    }

    private func pending(_ outcome: Outcome, _ recording: Recording) -> Outcome {
        var outcome = outcome
        outcome.outcome = .pending
        outcome.reason = recording.transcript == nil && recording.audio == nil ? "audio not downloaded" : "waiting for Apple transcript"
        return outcome
    }

    private func write(_ session: Session) throws {
        let directory = root.session(session.meta.sid)
        try PrivateFiles.directory(directory)
        let encoder = JSON.encoder()
        var transcript = Data()
        for row in session.rows { transcript += try encoder.encode(row) + Data("\n".utf8) }
        try PrivateFiles.write(transcript, to: directory.appendingPathComponent("transcript.jsonl"))
        try PrivateFiles.write(encoder.encode(session.meta), to: directory.appendingPathComponent("meta.json"))
    }

    private func record(_ recording: Recording, sid: String, state: LedgerEntry.State) throws {
        try save(recording.id, LedgerEntry(sid: sid, state: state, title: recording.title, imported_at: now))
    }

    private func save(_ id: String, _ entry: LedgerEntry) throws {
        ledger[id] = entry
        try PrivateFiles.directory(root.url)
        try PrivateFiles.write(JSON.encoder().encode(ledger), to: root.ledger)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let error as PushError: return error.description
        case let error as ImportError: return error.description
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case assetsNotInstalled
    case trackCount(expected: Int, found: Int)
    case unsupportedAudioFormat
    case unreadableAudio
    public var description: String {
        switch self {
        case .assetsNotInstalled: return "speech assets not installed"
        case .trackCount(let expected, let found): return "expected \(expected) audio tracks, found \(found)"
        case .unsupportedAudioFormat: return "unsupported analyzer audio format"
        case .unreadableAudio: return "audio could not be read"
        }
    }
}
