import Foundation
import SQLite3
import Testing
@testable import ImportCore

private struct Row {
    var pk: Int
    var values: [String: Any]
}

private func makeStore(_ container: URL, rows: [Row]) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(container.appendingPathComponent("NoteStore.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let columns = ["ZIDENTIFIER", "ZTYPEUTI", "ZTITLE", "ZTITLE1", "ZNOTE", "ZMEDIA", "ZPARENTATTACHMENT", "ZDURATION",
                   "ZGENERATION1", "ZFILENAME", "ZMARKEDFORDELETION", "ZFOLDER", "ZFOLDERTYPE", "ZCREATIONDATE", "ZMERGEABLEDATA1"]
    #expect(sqlite3_exec(db, "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, \(columns.joined(separator: ", ")))", nil, nil, nil) == SQLITE_OK)
    for row in rows {
        let names = ["Z_PK"] + row.values.keys.sorted()
        var statement: OpaquePointer?
        let sql = "INSERT INTO ZICCLOUDSYNCINGOBJECT (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
        #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        sqlite3_bind_int64(statement, 1, Int64(row.pk))
        for (offset, name) in row.values.keys.sorted().enumerated() {
            let index = Int32(offset + 2)
            switch row.values[name] {
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Data: _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            default: break
            }
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
    }
}

private func mediaFile(_ container: URL, id: String, generation: String, name: String) throws {
    let directory = container.appendingPathComponent("Accounts/ACCOUNT/Media/\(id)/\(generation)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent(name))
}

private let words = [
    TestWord(speaker: "+15550000001", start: 0, duration: 0.5, text: "Hello."),
    TestWord(speaker: "+15550000002", start: 0.4, duration: 0.5, text: " Hi."),
    TestWord(speaker: "+15550000003", start: 1.0, duration: 0.5, text: " Hey."),
]

private func call(note: Int, pk: Int, id: String, data: Data, media: Int? = nil, deleted: Int = 0) -> Row {
    var values: [String: Any] = ["ZIDENTIFIER": id, "ZTYPEUTI": "com.apple.m4a-audio", "ZNOTE": note, "ZMERGEABLEDATA1": data,
                                 "ZMARKEDFORDELETION": deleted, "ZCREATIONDATE": 100.0]
    if let media { values["ZMEDIA"] = media }
    return Row(pk: pk, values: values)
}
private func fragment(pk: Int, parent: Int, duration: Double, media: Int) -> Row {
    Row(pk: pk, values: ["ZIDENTIFIER": "F\(pk)", "ZTYPEUTI": "public.mpeg-4-audio", "ZPARENTATTACHMENT": parent, "ZDURATION": duration, "ZMEDIA": media])
}
private func media(pk: Int, id: String, name: String) -> Row {
    Row(pk: pk, values: ["ZIDENTIFIER": id, "ZGENERATION1": "1_GEN", "ZFILENAME": name])
}
private func note(pk: Int, title: String, folder: Int = 1, deleted: Int = 0) -> Row {
    Row(pk: pk, values: ["ZIDENTIFIER": "N\(pk)", "ZTITLE1": title, "ZFOLDER": folder, "ZMARKEDFORDELETION": deleted])
}

struct NotesReaderTests {
    @Test func readsCallRecordingsFromACopyAndLeavesTheStoreUntouched() async throws {
        let container = try temporaryDirectory(), scratch = try temporaryDirectory()
        let noTranscript = DocBuilder.call(start: 1_790_000_600, words: [])
        let notCall = DocBuilder()
        notCall.root(start: nil, local: nil, remote: nil, fragments: [])
        try makeStore(container, rows: [
            Row(pk: 1, values: ["ZFOLDERTYPE": 0]), Row(pk: 2, values: ["ZFOLDERTYPE": 1]),
            note(pk: 10, title: "Call with Ann"), call(note: 10, pk: 11, id: "ANN", data: DocBuilder.call(words: words), media: 13),
            fragment(pk: 12, parent: 11, duration: 600, media: 14), media(pk: 13, id: "M13", name: "Call with Ann.m4a"),
            media(pk: 14, id: "M14", name: "moments-audio.MOV"),
            note(pk: 20, title: "Call with Bob"), call(note: 20, pk: 21, id: "BOB", data: noTranscript, media: 23),
            fragment(pk: 22, parent: 21, duration: 90, media: 24), media(pk: 23, id: "M23", name: "Call with Bob.m4a"),
            media(pk: 24, id: "M24", name: "not-downloaded.MOV"),
            note(pk: 30, title: "Trashed", folder: 2), call(note: 30, pk: 31, id: "TRASHED", data: DocBuilder.call(words: words)),
            note(pk: 40, title: "Deleted note", deleted: 1), call(note: 40, pk: 41, id: "DELETED", data: DocBuilder.call(words: words)),
            note(pk: 50, title: "Voice memo"), call(note: 50, pk: 51, id: "MEMO", data: notCall.data),
            note(pk: 60, title: "Broken"), call(note: 60, pk: 61, id: "BROKEN", data: Data([0x0a, 0xff])),
        ])
        try mediaFile(container, id: "M13", generation: "1_GEN", name: "Call with Ann.m4a")
        try mediaFile(container, id: "M14", generation: "1_GEN", name: "moments-audio.MOV")
        try mediaFile(container, id: "M23", generation: "1_GEN", name: "Call with Bob.m4a")
        let store = container.appendingPathComponent("NoteStore.sqlite")
        let before = try Data(contentsOf: store)

        let scan = try await NotesReader(container: container, scratch: scratch, trackCount: { _ in 2 }).scan()

        #expect(scan.recordings.map(\.id) == ["notes:ANN", "notes:BOB"])
        #expect(scan.unreadable.map(\.id) == ["notes:BROKEN"])
        let ann = scan.recordings[0], bob = scan.recordings[1]
        #expect(ann.source == .phone && ann.title == "Call with Ann" && ann.startedAt == epoch && ann.duration == 600)
        #expect(ann.audio == .tracks(container.appendingPathComponent("Accounts/ACCOUNT/Media/M14/1_GEN/moments-audio.MOV"), [.me, .them]))
        #expect(ann.transcript?.map(\.speaker) == [.me, .them])
        #expect(ann.transcript?.map(\.words.count) == [1, 2])
        #expect(bob.transcript == nil)
        #expect(bob.duration == 90)
        #expect(bob.audio == .mixed(container.appendingPathComponent("Accounts/ACCOUNT/Media/M23/1_GEN/Call with Bob.m4a")))
        #expect(try Data(contentsOf: store) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func singleTrackFragmentFallsBackToTheMixedFile() async throws {
        let container = try temporaryDirectory()
        try makeStore(container, rows: [
            Row(pk: 1, values: ["ZFOLDERTYPE": 0]), note(pk: 10, title: "Call"),
            call(note: 10, pk: 11, id: "ONE", data: DocBuilder.call(words: []), media: 13),
            fragment(pk: 12, parent: 11, duration: 5, media: 14),
            media(pk: 13, id: "M13", name: "mixed.m4a"), media(pk: 14, id: "M14", name: "fragment.MOV"),
        ])
        try mediaFile(container, id: "M13", generation: "1_GEN", name: "mixed.m4a")
        try mediaFile(container, id: "M14", generation: "1_GEN", name: "fragment.MOV")
        let scan = try await NotesReader(container: container, scratch: try temporaryDirectory(), trackCount: { _ in 1 }).scan()
        #expect(scan.recordings.first?.audio == .mixed(container.appendingPathComponent("Accounts/ACCOUNT/Media/M13/1_GEN/mixed.m4a")))
    }

    @Test func missingStoreIsAnError() async throws {
        await #expect(throws: NotesError.storeMissing) {
            try await NotesReader(container: try temporaryDirectory(), scratch: try temporaryDirectory(), trackCount: { _ in 2 }).scan()
        }
    }
}
