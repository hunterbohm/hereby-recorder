import Foundation
import Testing
@testable import ImportCore

private let recorderRow = #"{"at": "2026-10-23T21:33:25.855Z", "ch": "me", "parts": [{"t0": "2026-10-23T21:33:21.107Z", "t1": "2026-10-23T21:33:21.827Z", "text": "xxxx.", "words": [[0, 0.7199999570846565]], "xo": 0.9999988410206502}], "seq": 5, "text": "xxxx.", "ts0": "2026-10-23T21:33:21.107Z", "ts1": "2026-10-23T21:33:21.887Z", "v": 1, "xo": 0.9999987773405752}"#
private let recorderMetaKeys: Set<String> = ["apps", "asr", "cal_keys", "ended_at", "heartbeat_at", "me", "segments", "sid", "started_at", "state", "test", "v", "version", "warnings"]

private func words(_ items: [(Double, Double, String)]) -> [Word] { items.map { Word(start: $0.0, end: $0.1, text: $0.2) } }
private func phone(_ id: String = "notes:A", duration: Double = 60) -> Recording {
    Recording(id: id, source: .phone, title: "Call with Someone", startedAt: epoch, duration: duration)
}
private func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

struct SessionBuilderTests {
    @Test func rowsKeepTheRecorderRowShape() throws {
        let row = try JSON.decoder().decode(TranscriptRow.self, from: Data(recorderRow.utf8))
        let encoded = try object(JSON.encoder().encode(row))
        let original = try object(Data(recorderRow.utf8))
        #expect(Set(encoded.keys) == Set(original.keys))
        let parts = try #require(encoded["parts"] as? [[String: Any]])
        let originalParts = try #require(original["parts"] as? [[String: Any]])
        #expect(Set(parts[0].keys) == Set(originalParts[0].keys))
        #expect(encoded["ts0"] as? String == "2026-10-23T21:33:21.107Z")
    }

    @Test func metaIsTheRecorderMetaPlusKindAndSource() throws {
        let session = SessionBuilder.build(phone(), utterances: [Utterance(speaker: .me, words: words([(1, 2, " Hi.")]))], asr: SessionBuilder.appleASR)
        let meta = try object(JSON.encoder().encode(session.meta))
        #expect(Set(meta.keys) == recorderMetaKeys.union(["kind", "source"]))
        #expect(meta["state"] as? String == "closed")
        #expect(meta["kind"] as? String == "call")
        #expect(meta["source"] as? String == "phone")
        #expect(meta["apps"] as? [String] == ["com.apple.mobilephone"])
        #expect(meta["segments"] as? Int == 1)
        #expect(session.meta.ended_at == epoch.addingTimeInterval(60))
        #expect(session.meta.heartbeat_at == session.meta.ended_at)
    }

    @Test func sidIsStableAndShapedLikeTheRecorders() {
        let utc = TimeZone(identifier: "UTC")!
        let first = SessionBuilder.sid(for: phone("notes:A"), timeZone: utc)
        #expect(first == SessionBuilder.sid(for: phone("notes:A"), timeZone: utc))
        #expect(first != SessionBuilder.sid(for: phone("notes:B"), timeZone: utc))
        #expect(first.hasPrefix("20260921-141320-"))
        #expect(SessionBuilder.validID(first))
    }

    @Test func rowsAreChronologicalWithOverlapAgainstTheOtherSpeaker() throws {
        let session = SessionBuilder.build(phone(), utterances: [
            Utterance(speaker: .them, words: words([(0.5, 1.0, " Yes"), (1.0, 2.0, " indeed.")])),
            Utterance(speaker: .me, words: words([(0.0, 0.3, " So"), (0.6, 0.9, " right.")]))
        ], asr: SessionBuilder.appleASR)
        #expect(session.rows.map(\.ch) == [.me, .them])
        #expect(session.rows.map(\.seq) == [1, 2])
        let me = session.rows[0]
        #expect(me.text == "So right.")
        #expect(me.ts0 == epoch && me.ts1 == epoch.addingTimeInterval(0.9))
        #expect(me.at == me.ts1)
        #expect(abs(me.xo - 0.4 / 0.9) < 1e-9)
        #expect(me.parts.map(\.text) == ["So", "right."])
        #expect(me.parts.map(\.xo) == [0, 1])
        #expect(me.parts[1].words == [[0, 0.30000000000000004]])
        #expect(abs(session.rows[1].xo - 0.3 / 1.5) < 1e-9)
    }

    @Test func mixedCallChannelHasNoOverlapAndSaysSo() {
        let session = SessionBuilder.build(phone(), utterances: [
            Utterance(speaker: .call, words: words([(0, 1, " One"), (1, 2, " two.")])),
            Utterance(speaker: .call, words: words([(1.5, 3, " Three.")]))
        ], asr: SessionBuilder.speechASR)
        #expect(session.rows.allSatisfy { $0.ch == .call && $0.xo == 0 && $0.parts.count == 1 })
        #expect(session.meta.me == "mixed (one channel)")
        #expect(session.meta.asr == SessionBuilder.speechASR)
        #expect(session.meta.warnings.isEmpty)
        var guessed = phone(); guessed.startEstimated = true
        #expect(SessionBuilder.build(guessed, utterances: [], asr: SessionBuilder.speechASR).meta.warnings == ["start_estimated"])
    }

    @Test func sessionEndsNoEarlierThanItsLastRow() {
        let session = SessionBuilder.build(phone(duration: 0), utterances: [Utterance(speaker: .me, words: words([(5, 7, " Late.")]))], asr: SessionBuilder.appleASR)
        #expect(session.meta.ended_at == epoch.addingTimeInterval(7))
    }

    @Test func blankWordsAndEmptyUtterancesProduceNoRows() {
        let session = SessionBuilder.build(phone(), utterances: [Utterance(speaker: .me, words: words([(0, 1, "  ")]))], asr: SessionBuilder.speechASR)
        #expect(session.rows.isEmpty)
        #expect(session.meta.segments == 0)
    }

    @Test func appleWordsSplitIntoUtterancesAtSpeakerChangesPausesAndLongSentences() {
        let me = Speaker.me, them = Speaker.them
        var stream: [(speaker: Speaker, word: Word)] = [
            (me, Word(start: 0, end: 0.5, text: " A")), (me, Word(start: 0.6, end: 1, text: " b.")),
            (them, Word(start: 0.2, end: 0.8, text: " C")),
            (them, Word(start: 2.4, end: 2.6, text: " d"))
        ]
        stream += (0..<22).map { (me, Word(start: 10 + Double($0), end: 10.5 + Double($0), text: $0 == 20 ? " end." : " w")) }
        let utterances = SessionBuilder.utterances(stream)
        #expect(utterances.map(\.speaker) == [.me, .them, .them, .me, .me])
        #expect(utterances.map(\.words.count) == [2, 1, 1, 21, 1])
    }
}
