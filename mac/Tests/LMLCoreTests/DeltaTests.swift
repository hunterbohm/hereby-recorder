import Foundation
import Darwin
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private let sid = "20261013-190012-a3f1"
private func temporary() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString.prefix(8).description)
    try PrivateFiles.directory(root)
    return root
}

struct WordRangeTests {
    @Test func relativeOffsetsAndRoundTrip() throws {
        let parts = PartSplitter.split(words: [Word(start: 5, end: 5.25, text: "Hello "), Word(start: 5.5, end: 6, text: "there")],
            anchor: epoch, other: EnergyRing(), boundaries: [])
        #expect(parts.count == 1)
        #expect(parts[0].words == [[0, 0.25], [0.5, 1]])
        let data = try JSON.encoder().encode(parts[0])
        #expect(try JSON.decoder().decode(TranscriptPart.self, from: data) == parts[0])
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["words"] as? [[Double]] == [[0, 0.25], [0.5, 1]])
    }
    @Test func rangelessVolatileTextIsUnsplitAndExplicitNull() async throws {
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: nil)
        await writer.setAnchor(epoch, channel: .me)
        await writer.setSchedule(Schedule(generated_at: epoch, events: [CalendarEvent(key: "previous", start: at(-1000), end: at(2)), CalendarEvent(key: "next", start: at(2), end: at(100))]))
        var ring = EnergyRing()
        for index in Int64(epoch.timeIntervalSince1970 * 10)..<Int64(epoch.timeIntervalSince1970 * 10 + 20) { ring.record(index: index, speech: true) }
        await writer.setEnergy(ring, channel: .them)
        let row = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 4, words: [], final: false, at: at(4), text: "still being transcribed")))
        #expect(row.parts.count == 1)
        #expect(row.parts[0].t0 == epoch); #expect(row.parts[0].t1 == at(4))
        #expect(abs(row.parts[0].xo - 0.5) < 0.001)
        #expect(row.parts[0].words == nil)
        let data = try JSON.encoder().encode(row)
        #expect(String(decoding: data, as: UTF8.self).contains("\"words\":null"))
        #expect(try JSON.decoder().decode(TranscriptRow.self, from: data) == row)
        let live = await writer.snapshot(at: at(4))
        #expect(live.partials["me"]??.text == row.text)
    }
    @Test func rangelessPartialAfterFinalRemainsVisible() async throws {
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: nil)
        await writer.setAnchor(epoch, channel: .me)
        try await writer.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "confirmed")], final: true))
        let row = try await writer.receive(Recognition(ch: .me, start: 1, end: 4, words: [], final: false, text: "next"))
        #expect(row?.text == "next")
        #expect(row?.ts0 == at(1))
        #expect(await writer.snapshot(at: at(4)).finals.count == 1)
    }
}

struct RunTests {
    @Test func thirtySecondGapUsesNewAnchorAndBoundary() async throws {
        var segmenter = RunSegmenter()
        let source = UUID()
        #expect(segmenter.accept(at: epoch, duration: 1, source: source) == true)
        #expect(segmenter.accept(at: at(1), duration: 1, source: source) == false)
        #expect(segmenter.accept(at: at(32), duration: 1, source: source) == true)
        #expect(segmenter.anchor == at(32))
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: nil)
        await writer.beginRun(at: epoch, channel: .me)
        try await writer.receive(Recognition(ch: .me, start: 0, end: 2, words: [Word(start: 0, end: 2, text: "first")], final: true, anchor: epoch))
        await writer.endRun(channel: .me)
        await writer.beginRun(at: at(32), channel: .me)
        await writer.setSchedule(Schedule(generated_at: epoch, events: [CalendarEvent(key: "previous", start: at(-1000), end: at(33)), CalendarEvent(key: "next", start: at(33), end: at(100))]))
        let second = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 2, words: [Word(start: 0, end: 0.9, text: "old "), Word(start: 1, end: 2, text: "new")], final: true, at: at(35), anchor: segmenter.anchor)))
        #expect(second.ts0 == at(32)); #expect(second.ts1 == at(34))
        #expect(second.parts.map(\.t0) == [at(32), at(33)])
        #expect(second.seq == 2)
    }
    @Test func deviceChangeWithContinuousHostTimeStartsFreshRun() {
        var segmenter = RunSegmenter()
        let shure = UUID(), airpods = UUID()
        #expect(segmenter.accept(at: epoch, duration: 0.1, source: shure) == true)
        #expect(segmenter.accept(at: at(0.1), duration: 0.1, source: shure) == false)
        #expect(segmenter.accept(at: at(0.2), duration: 0.1, source: airpods) == true)
        #expect(segmenter.anchor == at(0.2))
    }
    @Test func gateReopenAndBackwardDiscontinuity() {
        var segmenter = RunSegmenter()
        let source = UUID()
        #expect(segmenter.accept(at: epoch, duration: 1, source: source) == true)
        #expect(segmenter.accept(at: at(1.5), duration: 1, source: source) == false)
        #expect(segmenter.accept(at: at(1.9), duration: 1, source: source) == true)
        segmenter.end()
        #expect(segmenter.accept(at: at(3), duration: 1, source: source) == true)
    }
    @Test func runAnchorIsStoredWithPartialAndOldResultsKeepTheirClock() async throws {
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: nil)
        await writer.beginRun(at: epoch, channel: .me)
        try await writer.receive(Recognition(ch: .me, start: 0, end: 1, words: [], final: false, text: "old partial", anchor: epoch))
        await writer.beginRun(at: at(30), channel: .me)
        #expect(await writer.snapshot(at: at(31)).partials["me"]! == nil)
        let old = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "old final")], final: true, anchor: epoch)))
        #expect(old.ts0 == epoch)
        let next = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 1, words: [], final: false, text: "new partial", anchor: at(30))))
        #expect(next.ts0 == at(30))
        #expect(await writer.snapshot(at: at(31)).partials["me"]??.ts0 == at(30))
    }
}

struct PauseTests {
    @Test func legacyPauseMigratesOnceWithoutLosingSuppression() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFiles.write(Data(#"{"paused":true}"#.utf8), to: root.appendingPathComponent("control.json"))
        var pause = PauseStore(root: root)
        try pause.migrateLegacy(at: epoch)
        #expect(pause.isPaused)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path))
        #expect(try JSON.read(PauseState.self, from: root.appendingPathComponent("pause.json")).until == "meeting_end")
    }
    @Test func pauseSurvivesRestartUntilSignalHasBeenGoneForHangover() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var original = PauseStore(root: root)
        try original.set(reason: .forget, at: epoch)
        var restarted = PauseStore(root: root)
        #expect(restarted.isPaused)
        #expect(!(try restarted.observe(meetingSignal: true, at: at(1000))))
        #expect(!(try restarted.observe(meetingSignal: false, at: at(1001))))
        #expect(!(try restarted.observe(meetingSignal: false, at: at(1120))))
        #expect(restarted.isPaused)
        #expect(try restarted.observe(meetingSignal: false, at: at(1121)))
        #expect(!restarted.isPaused)
    }
    @Test func storedReasonsDecodeAndUnknownOnesStillMeanPaused() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pause.json")
        for (stored, expected) in [("pause", PauseState.Reason.pause), ("forget", .forget), ("something-newer", .pause), ("", .pause)] {
            try PrivateFiles.write(Data(#"{"reason":"\#(stored)","set_at":"2026-01-01T00:00:00Z","until":"meeting_end"}"#.utf8), to: file)
            #expect(try JSON.read(PauseState.self, from: file).reason == expected)
            #expect(PauseStore(root: root).isPaused)
        }
        var store = PauseStore(root: root)
        try store.set(reason: .forget, at: epoch)
        #expect(try String(contentsOf: file, encoding: .utf8).contains(#""reason":"forget""#))
    }
    @Test func returningSignalResetsPauseReleaseAndResumeDeletesFile() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var pause = PauseStore(root: root)
        try pause.set(reason: .pause, at: epoch)
        try pause.observe(meetingSignal: false, at: at(1))
        try pause.observe(meetingSignal: true, at: at(119))
        try pause.observe(meetingSignal: false, at: at(121))
        #expect(!(try pause.observe(meetingSignal: false, at: at(240))))
        #expect(pause.isPaused)
        try pause.resume()
        #expect(!PauseStore(root: root).isPaused)
    }
    @Test func browserOnShureDoesNotOpenDefaultAirPods() {
        let selector = MicDeviceSelector(ownPID: 100, clients: MeetingClients())
        var browser = ProcessRow(bundle: "net.imput.helium.helper", input: true, pid: 4, inputDevices: [20])
        #expect(selector.eligible(ProcessSnapshot(procs: [browser], ts: epoch), defaultInput: 10) == 20)
        browser.inputDevices = [20, 10]
        #expect(selector.eligible(ProcessSnapshot(procs: [browser], ts: epoch), defaultInput: 10) == 10)
    }
}

struct ForgetTests {
    @Test @MainActor func activeForgetOrdersShutdownAndPreventsLateWrites() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root)
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: paths.session(sid), test: true)
        await writer.setAnchor(epoch, channel: .me)
        try await writer.activate(at: epoch)
        let outbox = Outbox(paths: paths, mini: Mini(host: "mini"), runner: StubRunner([]))
        var steps: [String] = []
        try await ActiveForget.perform(
            cancelOutbox: { steps.append("outbox"); await outbox.cancelSession(sid) },
            stopSources: { steps.append("sources") },
            cancelAnalyzers: { steps.append("analyzers") },
            closeWriter: { steps.append("writer"); await writer.discard() },
            deleteSession: { steps.append("delete"); try await outbox.deleteSession(sid) },
            writeTombstone: { steps.append("tombstone"); try await outbox.recordForget(sid, at: epoch) },
            reply: { steps.append("forgotten") })
        #expect(steps == ["outbox", "sources", "analyzers", "writer", "delete", "tombstone", "forgotten"])
        #expect(!FileManager.default.fileExists(atPath: paths.session(sid).path))
        #expect(try await outbox.tombstones()[sid] != nil)
        #expect(try await writer.receive(Recognition(ch: .me, start: 1, end: 2, words: [], final: true, text: "late")) == nil)
        try await writer.activate(at: at(2)); try await writer.publish(at: at(2), force: true)
        #expect(!FileManager.default.fileExists(atPath: paths.session(sid).path))
    }
    @Test @MainActor func noReplyKillsGroupWaitsForAllPIDsThenDeletes() async throws {
        var steps: [String] = []
        var checks = 0
        try await UnresponsiveForget.perform(
            launchKill: { steps.append("launchctl"); return false },
            readIdentity: { steps.append("pid"); return AgentIdentity(pid: 400, pgid: 400) },
            killGroup: { #expect($0 == 400); steps.append("killgroup") },
            survivingPIDs: { _ in checks += 1; return checks < 3 ? [400, 401] : [] },
            wait: { steps.append("wait") },
            deleteSession: { steps.append("delete") })
        #expect(steps == ["launchctl", "pid", "killgroup", "wait", "wait", "delete"])
    }
    @Test @MainActor func survivingChildFailsAndNeverDeletesEvenAfterLaunchKillSucceeds() async throws {
        var deleted = false, groupKilled = false
        do {
            try await UnresponsiveForget.perform(
                launchKill: { true }, readIdentity: { AgentIdentity(pid: 400, pgid: 400) },
                killGroup: { _ in groupKilled = true }, survivingPIDs: { _ in [401] }, wait: {},
                deleteSession: { deleted = true })
            Issue.record("forget succeeded with a surviving child")
        } catch let error as SurvivingProcesses { #expect(error.pids == [401]) }
        #expect(groupKilled); #expect(!deleted)
    }
    @Test func writerFailureKeepsFailedMetadataAndRejectsLaterResults() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = SessionWriter(sid: sid, startedAt: epoch, directory: root)
        await writer.setAnchor(epoch, channel: .me); try await writer.activate(at: epoch)
        try FileManager.default.removeItem(at: root.appendingPathComponent("transcript.jsonl"))
        await #expect(throws: (any Error).self) {
            try await writer.receive(Recognition(ch: .me, start: 0, end: 1, words: [], final: true, text: "cannot write"))
        }
        try await writer.fail(at: at(1))
        #expect(try JSON.read(SessionMeta.self, from: root.appendingPathComponent("meta.json")).state == .failed)
        #expect(try await writer.receive(Recognition(ch: .me, start: 1, end: 2, words: [], final: true, text: "late")) == nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LML_SOCKET_TESTS"] != "0", "Unix socket binding requires sandbox network access"))
struct SocketTests {
    @Test func privateSocketRoundTrip() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ControlServer(root: root)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("control.sock").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let client = Task { try await ControlClient.request(ControlCommand(action: .forget, sid: sid), root: root) }
        var connection: ControlConnection?
        for _ in 0..<100 where connection == nil {
            connection = try await server.acceptCommand()
            if connection == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let received = try #require(connection)
        #expect(received.command.action == .forget); #expect(received.command.sid == sid)
        try received.reply("forgotten")
        #expect(try await client.value == "forgotten")
    }
    @Test func stalledSocketTimesOut() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ControlServer(root: root)
        let client = Task { try await ControlClient.request(ControlCommand(action: .forget, sid: sid), root: root, timeout: 0.1) }
        var connection: ControlConnection?
        for _ in 0..<20 where connection == nil {
            connection = try await server.acceptCommand()
            if connection == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(connection != nil)
        await #expect(throws: POSIXError(.ETIMEDOUT)) { try await client.value }
        withExtendedLifetime(connection) {}
    }
}

struct RunnerTests {
    @Test func rsyncLikeChildSharesAgentGroupAndCancellationWaitsForExit() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child.pid")
        let runner = LocalProcessRunner()
        let running = Task {
            try await runner.run(ProcessCommand("/bin/sh", ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 60", "lml-test", marker.path]))
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(getpgid(pid) == getpgrp())
        running.cancel()
        await runner.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
