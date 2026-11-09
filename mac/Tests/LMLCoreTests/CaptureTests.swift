import Foundation
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-capture-\(UUID().uuidString)")
    try PrivateFiles.directory(directory); return directory
}

struct SessionFileTests {
    @Test func metaWithoutKindOrSourceReadsAsAListenerCall() throws {
        let raw = #"{"v":1,"sid":"20261013-190012-a3f1","state":"closed","started_at":"2026-10-13T19:00:02-05:00","heartbeat_at":"2026-10-13T19:22:41-05:00"}"#
        let meta = try JSON.decoder().decode(SessionMeta.self, from: Data(raw.utf8))
        #expect(meta.kind == .call); #expect(meta.source == .listener)
        let room = SessionMeta(sid: "20261013-190012-a3f1", started_at: epoch, kind: .inPerson)
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSON.encoder().encode(room)) as? [String: Any])
        #expect(encoded["kind"] as? String == "in_person"); #expect(encoded["source"] as? String == "listener"); #expect(encoded["me"] as? String == "room")
    }
    @Test func configDefaultsAndRejectsNonPositiveIntervals() throws {
        let config = try JSON.decoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.sync_interval_s == 30); #expect(config.in_person_silence_s == 600)
        #expect(throws: DecodingError.self) { try JSON.decoder().decode(Config.self, from: Data(#"{"sync_interval_s":0}"#.utf8)) }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(try Config.load(missing).sync_interval_s == 30)
    }
    @Test func markRowsCarryALocalOffsetAndExplicitNullNote() throws {
        let line = try Mark(at: Date(timeIntervalSince1970: 1_792_000_000), note: nil).line(in: TimeZone(identifier: "America/Chicago")!)
        #expect(String(decoding: line, as: UTF8.self) == #"{"at":"2026-10-14T12:46:40.000-05:00","note":null}"# + "\n")
        let decoded = try JSON.decoder().decode(Mark.self, from: line.dropLast())
        #expect(decoded == Mark(at: Date(timeIntervalSince1970: 1_792_000_000), note: nil))
    }
}

struct MarkAndInPersonTests {
    @Test func marksAppendOnlyWhileTheSessionIsRecording() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("20261013-190012-a3f1")
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: directory, test: true)
        await #expect(throws: (any Error).self) { _ = try await writer.mark(note: "early", at: at(1)) }
        try await writer.activate(at: at(2))
        #expect(try await writer.mark(note: nil, at: at(3)) == 1)
        #expect(try await writer.mark(note: "pricing \"tier\"", at: at(4)) == 2)
        try await writer.close(at: at(5))
        await #expect(throws: (any Error).self) { _ = try await writer.mark(note: "late", at: at(6)) }
        let rows = try String(contentsOf: directory.appendingPathComponent("marks.jsonl"), encoding: .utf8).split(separator: "\n")
        let marks = try rows.map { try JSON.decoder().decode(Mark.self, from: Data($0.utf8)) }
        #expect(marks == [Mark(at: at(3), note: nil), Mark(at: at(4), note: "pricing \"tier\"")])
        #expect(rows[0].contains(#""note":null"#))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("marks.jsonl").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await writer.markCount() == 2)
        #expect(await writer.marks() == [at(3), at(4)])
    }
    @Test func inPersonRowsUseTheRoomChannelAndLiveHasOnlyRoom() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("20261013-190012-a3f1")
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: directory, test: true, kind: .inPerson)
        await writer.setAnchor(epoch, channel: .room)
        try await writer.activate(at: epoch)
        let row = try #require(try await writer.receive(Recognition(ch: .room, start: 1, end: 2, words: [Word(start: 1, end: 2, text: "Hello")], final: true, at: at(3))))
        #expect(row.ch == .room); #expect(row.xo == 0)
        let live = await writer.snapshot(at: at(3))
        #expect(Array(live.partials.keys) == ["room"]); #expect(Array(live.speech.keys) == ["room"])
        let line = try String(contentsOf: directory.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        #expect(line.contains(#""ch":"room""#))
        let meta = try JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json"))
        #expect(meta.kind == .inPerson); #expect(meta.me == "room")
        await writer.setContext(apps: [], calKeys: [], micOpen: false, silent: false)
        #expect(await writer.metadata().me == "room")
        #expect(await writer.transcriptLines() == [TranscriptLine(speaker: "room", text: "Hello", at: at(1))])
    }
    @Test func savedMeStateRecordsWhetherTheMicEverCapturedNotTheStateAtClose() async throws {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil, test: true)
        await writer.setContext(apps: [], calKeys: [], micOpen: false, silent: false)
        #expect(await writer.metadata().me == "off (no other input client)")
        await writer.setContext(apps: [], calKeys: [], micOpen: true, silent: false)
        #expect(await writer.metadata().me == "on")
        await writer.setContext(apps: [], calKeys: [], micOpen: false, silent: false)
        #expect(await writer.metadata().me == "on")
    }
    @Test func panelLinesAreTheSessionsLastFourHundredInSpeakingOrder() async throws {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil, test: true)
        await writer.setAnchor(epoch, channel: .me); await writer.setAnchor(epoch, channel: .them)
        for index in 0..<405 {
            let start = Double(index * 10)
            try await writer.receive(Recognition(ch: .them, start: start, end: start + 4, words: [], final: true, at: at(start + 5), text: "them \(index)"))
        }
        try await writer.receive(Recognition(ch: .me, start: 4035, end: 4060, words: [], final: true, at: at(4061), text: "me late"))
        let lines = await writer.transcriptLines()
        #expect(lines.count == 400)
        #expect(lines.first?.text == "them 6")
        #expect(lines.suffix(3).map(\.text) == ["them 403", "me late", "them 404"])
        #expect(lines.map(\.at) == lines.map(\.at).sorted())
        await writer.discard()
        #expect(await writer.transcriptLines().isEmpty)
    }
    @Test func silenceCountsFromTheLastFinalOrFromActivation() async throws {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil, test: true, kind: .inPerson)
        await writer.setAnchor(epoch, channel: .room)
        #expect(await writer.silence(at: at(600)) == 600)
        try await writer.receive(Recognition(ch: .room, start: 90, end: 100, words: [Word(start: 90, end: 100, text: "talk")], final: true, at: at(101)))
        #expect(await writer.silence(at: at(700)) == 600)
        try await writer.receive(Recognition(ch: .room, start: 200, end: 210, words: [Word(start: 200, end: 210, text: "draft")], final: false, at: at(211)))
        #expect(await writer.silence(at: at(700)) == 600)
    }
    @Test func callSessionsKeepMeAndThemOnly() async throws {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil, test: true)
        #expect(Set(await writer.snapshot(at: epoch).partials.keys) == ["me", "them"])
        #expect(Channel.channels(for: .call) == [.me, .them]); #expect(Channel.room.other == nil); #expect(Channel.me.other == .them)
    }
}
