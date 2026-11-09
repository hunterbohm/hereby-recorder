import Foundation
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private func said(_ channel: Channel, _ text: String, from start: Double, arrives: Double, final: Bool = true) -> Recognition {
    let tokens = text.split(separator: " ")
    let words = tokens.enumerated().map { Word(start: start + Double($0.offset) * 0.4, end: start + Double($0.offset) * 0.4 + 0.35, text: " " + $0.element) }
    return Recognition(ch: channel, start: start, end: words.last!.end, words: words, final: final, at: at(arrives))
}
private func writer(directory: URL? = nil) async throws -> SessionWriter {
    let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: directory, test: true)
    await writer.setAnchor(epoch, channel: .me); await writer.setAnchor(epoch, channel: .them)
    if directory != nil { try await writer.activate(at: epoch) }
    return writer
}
private func texts(_ writer: SessionWriter) async -> [String] { await writer.transcriptLines().map { "\($0.speaker): \($0.text)" } }

struct EchoGateTests {
    @Test func speakerSoundCaughtByTheMicIsNotAnotherLine() async throws {
        let writer = try await writer()
        try await writer.receive(said(.them, "I do not think there is such a thing", from: 10, arrives: 12))
        let echo = try await writer.receive(said(.me, "I do not think there is such a thing", from: 10.05, arrives: 12.3))
        #expect(echo == nil)
        #expect(await texts(writer) == ["them: I do not think there is such a thing"])
        #expect(await writer.metadata().segments == 1)
    }
    @Test func samSpeakingOverTheCallKeepsHisWords() async throws {
        let writer = try await writer()
        try await writer.receive(said(.them, "the renewal moves to Friday", from: 10, arrives: 12))
        try await writer.receive(said(.me, "wait can we push that to Monday", from: 10.1, arrives: 12.3))
        #expect(await texts(writer) == ["them: the renewal moves to Friday", "me: wait can we push that to Monday"])
    }
    @Test func hisOwnYeahAfterTheirYeahIsKept() async throws {
        let writer = try await writer()
        try await writer.receive(said(.them, "yeah", from: 10, arrives: 12))
        try await writer.receive(said(.me, "yeah", from: 14, arrives: 15))
        #expect(await texts(writer) == ["them: yeah", "me: yeah"])
    }
    @Test func aMicRowThatIsPartlyEchoAndPartlySamsStaysWhole() async throws {
        let writer = try await writer()
        try await writer.receive(said(.them, "so the renewal moves to Friday", from: 10, arrives: 12))
        try await writer.receive(said(.me, "so the renewal moves to Friday okay but I need the draft first", from: 10, arrives: 14))
        #expect(await texts(writer).count == 2)
    }
    @Test func echoIsCaughtWhileTheCallRowIsStillATentativeResult() async throws {
        let writer = try await writer()
        try await writer.receive(said(.them, "we can start the migration next week", from: 10, arrives: 11, final: false))
        let echo = try await writer.receive(said(.me, "we can start the migration next week", from: 10, arrives: 11.5))
        #expect(echo == nil)
        #expect(await texts(writer).isEmpty)
    }
    @Test func aCallRowThatFinalizesLateRemovesTheEarlierEchoFromThePanelOnly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-echo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try await writer(directory: root)
        try await writer.receive(said(.me, "the budget is forty two thousand", from: 10, arrives: 11))
        #expect(await texts(writer) == ["me: the budget is forty two thousand"])
        try await writer.receive(said(.them, "the budget is forty two thousand", from: 10, arrives: 14.5))
        #expect(await texts(writer) == ["them: the budget is forty two thousand"])
        let file = try String(contentsOf: root.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        #expect(file.split(separator: "\n").count == 2)
    }
    @Test func rowsWithoutWordTimingAreNeverTreatedAsEcho() async throws {
        let writer = try await writer()
        try await writer.receive(Recognition(ch: .them, start: 1, end: 3, words: [], final: true, at: at(4), text: "same text"))
        try await writer.receive(Recognition(ch: .me, start: 1, end: 3, words: [], final: true, at: at(4.3), text: "same text"))
        #expect(await texts(writer).count == 2)
    }
}

/// `LML_REPLAY_SESSION=<session dir> scripts/test.sh --filter EchoReplay` replays a recorded session's finals in arrival order.
struct EchoReplay {
    @Test func replayedSessionDropsTheEchoes() async throws {
        guard let path = ProcessInfo.processInfo.environment["LML_REPLAY_SESSION"] else { return }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("transcript.jsonl"))
        let recorded = try bytes.split(separator: 10).map { try JSON.decoder().decode(TranscriptRow.self, from: Data($0)) }.sorted { $0.at < $1.at }
        let writer = SessionWriter(sid: "replay", startedAt: recorded[0].ts0, directory: nil, test: true)
        var kept = 0
        for row in recorded {
            let words = row.parts.flatMap { part in
                zip(part.text.split(separator: " "), part.words ?? []).map { text, timing in
                    Word(start: part.t0.timeIntervalSince(row.ts0) + timing[0], end: part.t0.timeIntervalSince(row.ts0) + timing[1], text: " " + text)
                }
            }
            let result = Recognition(ch: row.ch, start: 0, end: row.ts1.timeIntervalSince(row.ts0), words: words, final: true, at: row.at, anchor: row.ts0)
            if try await writer.receive(result) != nil && row.ch == .me { kept += 1 }
        }
        let me = recorded.filter { $0.ch == .me }.count
        print("ECHOREPLAY me_rows=\(me) kept=\(kept) dropped=\(me - kept) them_rows=\(recorded.count - me)")
    }
}
