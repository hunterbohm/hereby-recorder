import Foundation
import SQLite3

public struct NotesScan: Sendable {
    public struct Unreadable: Sendable, Equatable {
        public var id: String
        public var createdAt: Date?
        public var reason: String
    }
    public var recordings: [Recording]
    public var unreadable: [Unreadable]
}

/// Reads iPhone call recordings from the Apple Notes store. Never opens the live database: it copies
/// NoteStore.sqlite with its -wal and -shm into a private scratch directory and reads the copy.
public struct NotesReader: Sendable {
    public var container: URL
    public var scratch: URL
    public var trackCount: @Sendable (URL) async throws -> Int

    public init(container: URL, scratch: URL = FileManager.default.temporaryDirectory, trackCount: @escaping @Sendable (URL) async throws -> Int) {
        self.container = container; self.scratch = scratch; self.trackCount = trackCount
    }

    public static var defaultContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
    }

    struct Media { var identifier: String; var generation: String?; var filename: String }
    struct Attachment { var pk: Int64; var identifier: String; var title: String?; var data: Data?; var createdAt: Date?; var media: Media? }
    struct FragmentRow { var duration: Double; var media: Media? }

    public func scan() async throws -> NotesScan {
        let (attachments, fragments) = try readStore()
        var recordings: [Recording] = []
        var unreadable: [NotesScan.Unreadable] = []
        for attachment in attachments {
            guard let data = attachment.data else { continue }
            let id = "notes:" + attachment.identifier
            let doc: AudioRecordingDoc
            do {
                doc = try AudioRecordingDecoder.decode(data)
            } catch {
                do { doc = try AudioRecordingDecoder.decode(data, transcripts: false) }
                catch { unreadable.append(.init(id: id, createdAt: attachment.createdAt, reason: Self.reason(error))); continue }
            }
            guard let startedAt = doc.startTime else { continue }
            let parts = fragments[attachment.pk] ?? []
            recordings.append(Recording(
                id: id, source: .phone, title: attachment.title, startedAt: startedAt,
                duration: parts.reduce(0) { $0 + $1.duration },
                audio: await audio(fragments: parts, parent: attachment.media),
                transcript: Self.transcript(doc)))
        }
        return NotesScan(recordings: recordings.sorted { $0.startedAt < $1.startedAt }, unreadable: unreadable)
    }

    static func transcript(_ doc: AudioRecordingDoc) -> [Utterance]? {
        guard doc.fragments.count == 1, !doc.fragments[0].words.isEmpty else { return nil }
        return SessionBuilder.utterances(doc.fragments[0].words.map { word in
            let speaker: Speaker = word.speaker != nil && word.speaker == doc.localHandle ? .me : .them
            return (speaker, Word(start: word.start, end: word.start + word.duration, text: word.text))
        })
    }

    private func audio(fragments: [FragmentRow], parent: Media?) async -> AudioPlan? {
        if fragments.count == 1, let url = file(fragments[0].media), (try? await trackCount(url)) == 2 {
            return .tracks(url, [.me, .them])
        }
        return file(parent).map(AudioPlan.mixed)
    }

    private func file(_ media: Media?) -> URL? {
        guard let media else { return nil }
        let accounts = container.appendingPathComponent("Accounts")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: accounts.path)) ?? []).sorted()
        let relatives = [media.generation.map { "Media/\(media.identifier)/\($0)/\(media.filename)" }, "Media/\(media.identifier)/\(media.filename)"]
        for relative in relatives.compactMap({ $0 }) {
            for name in names {
                let url = accounts.appendingPathComponent(name).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func readStore() throws -> ([Attachment], [Int64: [FragmentRow]]) {
        let copy = scratch.appendingPathComponent("lml-import-notes-\(UUID().uuidString)")
        try PrivateFiles.directory(copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        for suffix in ["", "-wal", "-shm"] {
            let source = container.appendingPathComponent("NoteStore.sqlite\(suffix)")
            guard FileManager.default.fileExists(atPath: source.path) else {
                if suffix.isEmpty { throw NotesError.storeMissing }
                continue
            }
            try FileManager.default.copyItem(at: source, to: copy.appendingPathComponent("NoteStore.sqlite\(suffix)"))
        }
        let database = try SQLite(copy.appendingPathComponent("NoteStore.sqlite"))
        let attachments = try database.rows("""
            SELECT a.Z_PK, a.ZIDENTIFIER, COALESCE(a.ZTITLE, n.ZTITLE1), a.ZMERGEABLEDATA1, a.ZCREATIONDATE,
                   m.ZIDENTIFIER, m.ZGENERATION1, m.ZFILENAME
            FROM ZICCLOUDSYNCINGOBJECT a
            JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = a.ZNOTE
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = a.ZMEDIA
            WHERE a.ZTYPEUTI = 'com.apple.m4a-audio' AND a.ZIDENTIFIER IS NOT NULL
              AND IFNULL(a.ZMARKEDFORDELETION, 0) = 0 AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
              AND IFNULL(f.ZFOLDERTYPE, 0) != 1
            """) { row in
            Attachment(pk: row.int(0)!, identifier: row.text(1)!, title: row.text(2), data: row.blob(3),
                createdAt: row.double(4).map(Date.init(timeIntervalSinceReferenceDate:)), media: Self.media(row, 5))
        }
        var fragments: [Int64: [FragmentRow]] = [:]
        try database.rows("""
            SELECT r.ZPARENTATTACHMENT, r.ZDURATION, m.ZIDENTIFIER, m.ZGENERATION1, m.ZFILENAME
            FROM ZICCLOUDSYNCINGOBJECT r
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = r.ZMEDIA
            WHERE r.ZTYPEUTI = 'public.mpeg-4-audio' AND r.ZPARENTATTACHMENT IS NOT NULL
              AND IFNULL(r.ZMARKEDFORDELETION, 0) = 0
            """) { row in (row.int(0)!, FragmentRow(duration: row.double(1) ?? 0, media: Self.media(row, 2))) }
            .forEach { fragments[$0.0, default: []].append($0.1) }
        return (attachments, fragments)
    }

    private static func media(_ row: SQLite.Row, _ column: Int32) -> Media? {
        guard let identifier = row.text(column), let filename = row.text(column + 2) else { return nil }
        return Media(identifier: identifier, generation: row.text(column + 1), filename: filename)
    }

    static func reason(_ error: Error) -> String {
        switch error {
        case CRDTError.unsupported(let what): return "unsupported recording data (\(what))"
        case CRDTError.malformed(let what): return "malformed recording data (\(what))"
        default: return "unreadable recording data"
        }
    }
}

public enum NotesError: Error, Equatable {
    case storeMissing
    case sqlite(Int32)
}

final class SQLite {
    struct Row {
        let statement: OpaquePointer
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? { isNull(column) ? nil : sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func blob(_ column: Int32) -> Data? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK else { sqlite3_close(handle); throw NotesError.sqlite(status) }
    }

    deinit { sqlite3_close(handle) }

    func rows<T>(_ sql: String, _ read: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw NotesError.sqlite(prepared) }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw NotesError.sqlite(step) }
            result.append(try read(Row(statement: statement)))
        }
    }
}
