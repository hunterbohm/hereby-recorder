import Foundation
import Testing
import Synchronization
import Darwin
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private let sid = "20261013-190012-a3f1"
private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-sync-\(UUID().uuidString)")
    try PrivateFiles.directory(directory); return directory
}

actor StubRunner: ProcessRunner {
    var codes: [Int32]
    var commands: [ProcessCommand] = []
    var stdout = Data()
    init(_ codes: [Int32], stdout: Data = Data()) { self.codes = codes; self.stdout = stdout }
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        commands.append(command); return ProcessOutput(status: codes.isEmpty ? 0 : codes.removeFirst(), stdout: stdout)
    }
    func cancel() async {}
    func recorded() -> [ProcessCommand] { commands }
}

/// Emulates the mini side of contracts C2, C3, and C4 over the ssh boundary.
actor MiniStub: ProcessRunner {
    struct Call: Sendable { let name: String; let arguments: [String]; let input: Data; let status: Int32 }
    private(set) var files: [String: [String: Data]] = [:]
    private(set) var tombstones: Set<String> = []
    private(set) var done: [String: Int] = [:]
    private(set) var heartbeats: [Data] = []
    private(set) var calls: [Call] = []
    private(set) var bytesWritten = 0
    private var failing: [String: Int] = [:]
    private var held: CheckedContinuation<Void, Never>?
    private var holding = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var duringNextReceive: (@Sendable () throws -> Void)?
    var reply = Data(#"{"schedule":{"v":1,"at":"2026-10-24T02:31:06.534440-05:00","retention_days":14,"events":[{"key":"call","start":"2026-10-24T09:00:00-05:00","end":"2026-10-24T10:00:00-05:00","has_conference":true,"attendee_count":3,"window_start":"2026-10-24T08:58:00-05:00","vocabulary":["Priya","Meridian"]}]},"status":{"v":1,"at":"2026-10-24T08:00:00-05:00","next":{"title":"Meridian sync","start":"2026-10-24T09:00:00-05:00","end":"2026-10-24T10:00:00-05:00","meeting_url":"https://meet.example/abc","note":null,"brief":["Renewal"]},"recent":[{"sid":"20261023-163204-440d","title":"Weekly","ended_at":"2026-10-23T18:19:32-05:00","state":"filed","note":"Weekly.md","note_url":null,"review":{"sent":false,"tasks":2}}]}}"#.utf8)

    func failNext(_ name: String, _ count: Int = 1) { failing[name, default: 0] += count }
    func setReply(_ data: Data) { reply = data }
    func truncate(_ sid: String, _ file: String, to size: Int) {
        guard let current = files[sid]?[file] else { return }
        files[sid]?[file] = current.prefix(size)
    }
    func forgetElsewhere(_ sid: String) { tombstones.insert(sid); files[sid] = nil }
    func file(_ sid: String, _ name: String) -> Data? { files[sid]?[name] }
    func receives(_ file: String) -> [Call] { calls.filter { $0.name == "live-meeting-receive" && $0.arguments[1] == file } }
    func named(_ name: String) -> [Call] { calls.filter { $0.name == name } }
    func mutateDuringNextReceive(_ change: @escaping @Sendable () throws -> Void) { duringNextReceive = change }
    func holdReceives() { holding = true }
    func waitForHeldReceive() async { if held != nil { return }; await withCheckedContinuation { entered.append($0) } }
    func release() { holding = false; held?.resume(); held = nil }

    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        let host = try #require(command.arguments.lastIndex(of: "mini"))
        let words = command.arguments[(host + 1)...].flatMap { $0.split(separator: " ").map(String.init) }.filter { !$0.hasPrefix("LML_ROOT=") }
        let name = words[0], arguments = Array(words.dropFirst()), input = command.input ?? Data()
        if name == "live-meeting-receive" {
            if let change = duringNextReceive { duringNextReceive = nil; try change() }
            if holding {
                entered.forEach { $0.resume() }; entered.removeAll()
                await withCheckedContinuation { held = $0 }
            }
        }
        let output: ProcessOutput
        if let count = failing[name], count > 0 { failing[name] = count - 1; output = ProcessOutput(status: 255) }
        else {
            switch name {
            case "live-meeting-receive": output = receive(arguments, input)
            case "live-meeting-done": output = signal(arguments)
            case "live-meeting-sync-status": heartbeats.append(input); bytesWritten += input.count; output = ProcessOutput(status: 0, stdout: reply)
            case "live-meeting-forget": tombstones.insert(arguments[0]); files[arguments[0]] = nil; output = ProcessOutput(status: 0)
            default: output = ProcessOutput(status: 127)
            }
        }
        calls.append(Call(name: name, arguments: arguments, input: input, status: output.status))
        return output
    }
    func cancel() async { release() }

    private func size(_ value: Int) -> Data { Data(#"{"size": \#(value)}"#.utf8) }
    private func receive(_ arguments: [String], _ input: Data) -> ProcessOutput {
        guard arguments.count == 3, let offset = Int(arguments[2]), offset >= 0 else { return ProcessOutput(status: 2) }
        let (sid, file) = (arguments[0], arguments[1])
        if tombstones.contains(sid) { return ProcessOutput(status: 4) }
        switch file {
        case "transcript.jsonl", "marks.jsonl":
            let current = files[sid]?[file] ?? Data()
            if current.count < offset { return ProcessOutput(status: 3, stdout: size(current.count)) }
            let next = current.prefix(offset) + input
            files[sid, default: [:]][file] = next; bytesWritten += input.count
            return ProcessOutput(status: 0, stdout: size(next.count))
        case "meta.json", "live.json", "speakers.json":
            guard offset == 0 else { return ProcessOutput(status: 2) }
            files[sid, default: [:]][file] = input; bytesWritten += input.count
            return ProcessOutput(status: 0, stdout: size(input.count))
        default: return ProcessOutput(status: 2)
        }
    }
    private func signal(_ arguments: [String]) -> ProcessOutput {
        let sid = arguments[0]
        if tombstones.contains(sid) { return ProcessOutput(status: 4) }
        guard let bytes = Int(arguments[1]), let raw = files[sid]?["meta.json"],
              let meta = try? JSON.decoder().decode(SessionMeta.self, from: raw), meta.state != .active,
              (files[sid]?["transcript.jsonl"]?.count ?? 0) == bytes else { return ProcessOutput(status: 3) }
        done[sid] = bytes
        return ProcessOutput(status: 0)
    }
}

private struct Fixture {
    let root: URL
    let paths: SessionPaths
    let directory: URL
    init(test: Bool = false) throws {
        root = try temporary(); paths = SessionPaths(root: root, test: test); directory = paths.session(sid)
        try PrivateFiles.directory(directory)
    }
    func meta(_ state: SessionMeta.State, version: Int, kind: CaptureKind = .call) throws {
        var meta = SessionMeta(sid: sid, started_at: epoch, test: paths.test, kind: kind)
        meta.state = state; meta.heartbeat_at = at(Double(version)); meta.version = version
        if state != .active { meta.ended_at = at(Double(version)) }
        try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json"))
    }
    func write(_ text: String, _ file: String = "transcript.jsonl") throws {
        try PrivateFiles.write(Data(text.utf8), to: directory.appendingPathComponent(file))
    }
    func local(_ file: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(file)) }
    func sync() throws -> SyncState { try JSON.read(SyncState.self, from: directory.appendingPathComponent("sync.json")) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct SyncProtocolTests {
    @Test func sendsOnlyNewCompleteLinesFromAckedOffsetsOnTheInterval() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("a\n"); try f.write("{}", "live.json")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini, interval: 30)
        try await outbox.tick(at: at(0))
        try f.write("a\nb\nhalf"); try f.meta(.active, version: 2)
        try await outbox.tick(at: at(29))
        #expect(await mini.receives("transcript.jsonl").count == 1)
        try await outbox.tick(at: at(30))
        let sends = await mini.receives("transcript.jsonl")
        #expect(sends.map { $0.arguments[2] } == ["0", "2"])
        #expect(sends.map { String(decoding: $0.input, as: UTF8.self) } == ["a\n", "b\n"])
        #expect(await mini.file(sid, "transcript.jsonl") == Data("a\nb\n".utf8))
        #expect(try f.sync().offsets[.transcript] == 4)
        #expect(await mini.receives("live.json").count == 1)
        #expect(await mini.receives("meta.json").count == 2)
        #expect(await mini.named("live-meeting-done").isEmpty)
    }
    @Test func closePushesImmediatelyThenSignalsDoneWithTranscriptBytes() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini, interval: 30)
        try await outbox.tick(at: at(0))
        try f.write("a\nlast\n"); try f.meta(.closed, version: 2)
        try await outbox.tick(at: at(1))
        let done = await mini.named("live-meeting-done")
        #expect(done.map(\.arguments) == [[sid, "7"]])
        #expect(await mini.done[sid] == 7)
        let state = try f.sync()
        #expect(state.stage == .doneSignaled); #expect(state.close_acked); #expect(state.done_signaled)
        let raw = try String(contentsOf: f.directory.appendingPathComponent("sync.json"), encoding: .utf8)
        #expect(raw.contains(#""done_signaled":true"#))
        let calls = await mini.calls.count
        try await outbox.tick(at: at(100))
        #expect(await mini.calls.count == calls)
    }
    @Test func speakersReachTheMiniBeforeTheClosingMeta() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini, interval: 30)
        try await outbox.tick(at: at(0))
        try f.write(#"{"turns":[],"v":1}"#, "speakers.json"); try f.meta(.closed, version: 2)
        try await outbox.tick(at: at(1))
        let order = await mini.named("live-meeting-receive").map { $0.arguments[1] }
        #expect(order.lastIndex(of: "speakers.json")! < order.lastIndex(of: "meta.json")!)
        #expect(await mini.file(sid, "speakers.json") == Data(#"{"turns":[],"v":1}"#.utf8))
        #expect(await mini.done[sid] == 2)
    }
    @Test func shorterRemoteFileAnswersThreeAndTheMacResendsFromItsSize() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("one\ntwo\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini, interval: 30)
        try await outbox.tick(at: at(0))
        await mini.truncate(sid, "transcript.jsonl", to: 4)
        try f.write("one\ntwo\nthree\n"); try f.meta(.active, version: 2)
        try await outbox.tick(at: at(30))
        let sends = await mini.receives("transcript.jsonl")
        #expect(sends.map(\.status) == [0, 3, 0])
        #expect(sends.map { $0.arguments[2] } == ["0", "8", "4"])
        #expect(await mini.file(sid, "transcript.jsonl") == (try f.local("transcript.jsonl")))
        #expect(try f.sync().offsets[.transcript] == 14)
    }
    @Test func sameCallTwiceConverges() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 3); try f.write("a\nb\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        try await outbox.tick(at: at(0))
        try PrivateFiles.write(SyncState(), to: f.directory.appendingPathComponent("sync.json"))
        try await outbox.tick(at: at(1))
        #expect(await mini.file(sid, "transcript.jsonl") == Data("a\nb\n".utf8))
        #expect(await mini.named("live-meeting-done").map(\.status) == [0, 0])
    }
    @Test func forgottenOnTheMiniStopsSyncAndDeletesTheEndedSession() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.forgetElsewhere(sid)
        let report = try await outbox.tick(at: at(0))
        #expect(report.forgottenActive.isEmpty)
        #expect(report.forgottenEnded == [sid])
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        #expect(try await outbox.tombstones()[sid] != nil)
        let receives = await mini.named("live-meeting-receive").count
        try await outbox.tick(at: at(5)); try await outbox.tick(at: at(60))
        #expect(await mini.named("live-meeting-receive").count == receives)
        #expect(await mini.named("live-meeting-forget").count == 1)
    }
    @Test func forgottenOnTheMiniWhileRecordingIsReportedToTheRuntime() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 2); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.forgetElsewhere(sid)
        let report = try await outbox.tick(at: at(0))
        #expect(report.forgottenActive == [sid])
        #expect(report.forgottenEnded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.directory.path))
        try await outbox.tick(at: at(40))
        #expect(await mini.named("live-meeting-receive").count == 1)
    }
    @Test func doneRetriesWithBackoffUntilExitZero() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.failNext("live-meeting-done", 2)
        try await outbox.tick(at: at(0))
        #expect(try f.sync().stage == .closeAcked); #expect(try f.sync().retry_at == at(5))
        try await outbox.tick(at: at(4))
        #expect(await mini.named("live-meeting-done").count == 1)
        try await outbox.tick(at: at(5))
        #expect(try f.sync().retry_at == at(15))
        try await outbox.tick(at: at(15))
        #expect(await mini.named("live-meeting-done").map(\.status) == [255, 255, 0])
        #expect(await mini.named("live-meeting-receive").count == 2)
        #expect(try f.sync().stage == .doneSignaled)
    }
    @Test func doneMismatchReverifiesFilesThenSignals() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\nb\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.failNext("live-meeting-done")
        try await outbox.tick(at: at(0))
        await mini.truncate(sid, "transcript.jsonl", to: 2)
        try await outbox.tick(at: at(5))
        #expect(await mini.named("live-meeting-done").map(\.status) == [255, 3])
        #expect(try f.sync().stage == .verifying)
        try await outbox.tick(at: at(15))
        #expect(await mini.receives("transcript.jsonl").map(\.status) == [0, 3, 0])
        #expect(await mini.file(sid, "transcript.jsonl") == Data("a\nb\n".utf8))
        #expect(await mini.done[sid] == 4)
        #expect(try f.sync().stage == .doneSignaled)
    }
    @Test func failedSendKeepsProgressAndRetriesWithBackoff() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("a\n"); try f.write("{}", "live.json")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.failNext("live-meeting-receive", 1)
        try await outbox.tick(at: at(0))
        #expect(try f.sync().offsets[.transcript] == nil); #expect(try f.sync().retry_at == at(5))
        try await outbox.tick(at: at(5))
        #expect(try f.sync().offsets[.transcript] == 2); #expect(try f.sync().failures == 0)
        #expect(await mini.file(sid, "meta.json") == (try f.local("meta.json")))
    }
    @Test func marksSyncAsAnAppendFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("a\n")
        let writer = Mark(at: Date(timeIntervalSince1970: 1_792_000_000), note: nil)
        try PrivateFiles.write(try writer.line(in: TimeZone(identifier: "America/Chicago")!), to: f.directory.appendingPathComponent("marks.jsonl"))
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        try await outbox.tick(at: at(0))
        let marks = try #require(await mini.file(sid, "marks.jsonl"))
        #expect(String(decoding: marks, as: UTF8.self) == #"{"at":"2026-10-14T12:46:40.000-05:00","note":null}"# + "\n")
        try f.meta(.closed, version: 2)
        try await outbox.tick(at: at(1))
        #expect(await mini.receives("marks.jsonl").count == 1)
        #expect(try f.sync().offsets[.marks] == marks.count)
    }
    @Test func metaIsSentLastSoTheMiniNeverSeesAClosedSessionWithAShortTranscript() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n"); try f.write("{}", "live.json")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        try await outbox.tick(at: at(0))
        #expect(await mini.calls.map { $0.name == "live-meeting-done" ? "done" : $0.arguments[1] } == ["transcript.jsonl", "live.json", "meta.json", "done"])
    }
    @Test func ackRecordsTheMetaThatWasSentWhileTheSourceChanges() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.active, version: 1); try f.write("fixture\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        let directory = f.directory
        await mini.mutateDuringNextReceive {
            try PrivateFiles.write(Data("fixture\nlater\n".utf8), to: directory.appendingPathComponent("transcript.jsonl"))
            var meta = try JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json")); meta.version += 1; meta.state = .closed
            try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json"))
        }
        try await outbox.tick(at: at(0))
        let state = try f.sync()
        #expect(state.offsets[.transcript] == 8); #expect(state.meta_version == 1); #expect(state.meta_state == .active)
        #expect(state.stage == .streaming)
        #expect(await mini.named("live-meeting-done").isEmpty)
        try await outbox.tick(at: at(1))
        #expect(await mini.done[sid] == 14)
    }
    @Test func crashRecoveryUsesHeartbeatAndDeliversTheCrash() async throws {
        let f = try Fixture(test: true); defer { f.cleanup() }
        try f.meta(.active, version: 5); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        try await outbox.recover()
        let meta = try JSON.read(SessionMeta.self, from: f.directory.appendingPathComponent("meta.json"))
        #expect(meta.state == .crashed); #expect(meta.ended_at == at(5))
        try await outbox.tick(at: at(10))
        #expect(try f.sync().stage == .doneSignaled)
        #expect(await mini.done[sid] == 2)
    }
    @Test func localForgetBlocksSyncAndRetriesTheRemoteForget() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.failNext("live-meeting-forget")
        try await outbox.forget(sid, at: at(0))
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        try await outbox.tick(at: at(0))
        #expect(try await outbox.tombstones()[sid]?.acked == false)
        try await outbox.tick(at: at(5))
        #expect(try await outbox.tombstones()[sid]?.acked == true)
        #expect(await mini.named("live-meeting-forget").count == 2)
        #expect(await mini.named("live-meeting-receive").isEmpty)
    }
    @Test func forgetDuringTransferCannotRestoreOrAckTheSession() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.holdReceives()
        let transfer = Task { try await outbox.tick(at: at(0)) }
        await mini.waitForHeldReceive()
        try await outbox.forget(sid, at: at(0))
        _ = try await transfer.value
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        try await outbox.tick(at: at(1))
        #expect(try await outbox.tombstones()[sid]?.acked == true)
        #expect(await mini.done[sid] == nil)
    }
    @Test func testRootCommandsCarryTheRemoteTestRoot() async throws {
        let f = try Fixture(test: true); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let runner = StubRunner([0], stdout: Data(#"{"size":2}"#.utf8)); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: runner)
        try await outbox.tick(at: at(0))
        let first = try #require(await runner.recorded().first)
        #expect(first.arguments.last == "LML_ROOT=\"$HOME/.local/state/live-meeting-test\" live-meeting-receive \(sid) transcript.jsonl 0")
        #expect(first.input == Data("a\n".utf8)); #expect(first.timeout != nil)
        #expect(first.arguments.contains("ServerAliveInterval=5")); #expect(first.arguments.contains("ControlMaster=auto"))
        #expect(!(await runner.recorded()).contains { $0.executable.hasSuffix("rsync") || $0.arguments.contains { $0.contains("mkdir") } })
    }
    @Test func failedCaptureIsDeliveredOnceTheRuntimeResumesIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.failed, version: 3); try f.write("a\nhalf")
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await outbox.cancelSession(sid)
        try await outbox.tick(at: at(0))
        #expect(await mini.calls.isEmpty)
        await outbox.resume(sid)
        try await outbox.tick(at: at(1))
        #expect(await mini.done[sid] == 2); #expect(await mini.file(sid, "transcript.jsonl") == Data("a\n".utf8))
    }
    @Test func unknownFileAndMissingSizeAreFailuresNotAcks() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.meta(.closed, version: 2); try f.write("a\n")
        let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: StubRunner([2]))
        try await outbox.tick(at: at(0))
        #expect(try f.sync().offsets[.transcript] == nil); #expect(try f.sync().retry_at == at(5))
        let silent = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: StubRunner([0]))
        try await silent.tick(at: at(5))
        #expect(try f.sync().offsets[.transcript] == nil); #expect(try f.sync().failures == 2)
    }
    @Test func legacySyncFilesMapOntoStages() throws {
        let decode = { (raw: String) in try JSON.decoder().decode(SyncState.self, from: Data(raw.utf8)) }
        let open = try decode(#"{"transcript_bytes_acked":12,"meta_acked_version":4,"close_acked":false}"#)
        #expect(open.stage == .streaming); #expect(open.offsets[.transcript] == 12); #expect(open.meta_version == 4)
        #expect(open.failures == 0); #expect(open.retry_at == nil)
        #expect(try decode(#"{"close_acked":true,"failures":0,"meta_acked_version":1132,"transcript_bytes_acked":1390883}"#).stage == .doneSignaled)
        #expect(try decode(#"{"close_acked":true,"done_signaled":false}"#).stage == .closeAcked)
        var state = SyncState(); state.stage = .verifying; state.offsets[.marks] = 3
        let round = try decode(String(decoding: try JSON.encoder().encode(state), as: UTF8.self))
        #expect(round.stage == .verifying); #expect(round.offsets[.marks] == 3)
    }
}

struct HeartbeatTests {
    @Test func heartbeatCarriesCaptureHealthAndFeedsScheduleAndPanel() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        let snapshot = RecorderSnapshot(phase: .ended, sid: sid, micOK: false, audioOK: true)
        let report = try await outbox.tick(at: at(0), heartbeat: Heartbeat(at: at(0), appVersion: "v2.0", snapshot: snapshot))
        let sent = try #require(await mini.heartbeats.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["state"] as? String == "idle"); #expect(body["sid"] is NSNull); #expect(body.keys.contains("sid"))
        #expect(body["mic_ok"] as? Bool == false); #expect(body["audio_ok"] as? Bool == true); #expect(body["app_version"] as? String == "v2.0")
        #expect(report.receipt?.at == at(0))
        let feed = try #require(report.receipt?.feed)
        #expect(feed.next?.title == "Meridian sync"); #expect(feed.recent.first?.state == .filed); #expect(feed.recent.first?.review?.tasks == 2)
        let scheduleURL = f.root.appendingPathComponent("schedule.json")
        let schedule = try JSON.read(Schedule.self, from: scheduleURL)
        #expect(schedule.events.first?.vocabulary == ["Priya", "Meridian"]); #expect(schedule.retention_days == 14)
        var first = stat(); stat(scheduleURL.path, &first)
        let quiet = try await outbox.tick(at: at(59), heartbeat: Heartbeat(at: at(59), appVersion: "v2.0", snapshot: snapshot))
        #expect(quiet.receipt == nil); #expect(await mini.heartbeats.count == 1)
        _ = try await outbox.tick(at: at(60), heartbeat: Heartbeat(at: at(60), appVersion: "v2.0", snapshot: snapshot))
        var second = stat(); stat(scheduleURL.path, &second)
        #expect(await mini.heartbeats.count == 2); #expect(first.st_ino == second.st_ino)
    }
    @Test func failedHeartbeatRetriesSoonerThanAMinute() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.failNext("live-meeting-sync-status")
        let beat = Heartbeat(at: at(0), app_version: "dev", state: .recording, sid: sid, mic_ok: true, audio_ok: true)
        #expect(try await outbox.tick(at: at(0), heartbeat: beat).receipt == nil)
        #expect(try await outbox.tick(at: at(15), heartbeat: beat).receipt?.at == at(15))
        let body = try #require(try JSONSerialization.jsonObject(with: await mini.heartbeats[0]) as? [String: Any])
        #expect(body["sid"] as? String == sid); #expect(body["state"] as? String == "recording")
    }
    @Test func unreadableStatusStillCountsAsReachingTheMini() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let mini = MiniStub(); let outbox = Outbox(paths: f.paths, mini: Mini(host: "mini"), runner: mini)
        await mini.setReply(Data(#"{"schedule":null,"status":{"v":"bad"}}"#.utf8))
        let beat = Heartbeat(at: at(0), app_version: "dev", state: .idle, sid: nil, mic_ok: true, audio_ok: true)
        #expect(try await outbox.tick(at: at(0), heartbeat: beat).receipt == FeedReceipt(at: at(0), feed: nil))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("schedule.json").path))
    }
    @Test func realMiniScheduleFormatDecodes() throws {
        let raw = #"{"v": 1, "at": "2026-10-24T02:31:06.534440-05:00", "retention_days": 14, "events": [{"key": "k", "start": "2026-10-24T09:00:00-05:00", "end": "2026-10-24T10:00:00-05:00", "has_conference": true, "attendee_count": 2, "window_start": "2026-10-24T08:58:00-05:00"}]}"#
        let schedule = try JSON.decoder().decode(Schedule.self, from: Data(raw.utf8))
        #expect(schedule.events.count == 1); #expect(schedule.events[0].vocabulary == nil)
        #expect(schedule.vocabulary(at: schedule.events[0].start) == [])
    }
    @Test func scheduleStillReadsTheOlderGeneratedAtKey() throws {
        let raw = #"{"generated_at":"2027-01-15T08:00:00Z","events":[]}"#
        #expect(try JSON.decoder().decode(Schedule.self, from: Data(raw.utf8)).generated_at == epoch)
        let encoded = try JSON.encoder().encode(Schedule(generated_at: epoch))
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""at":"2027-01-15T08:00:00.000Z""#))
    }
    @Test func vocabularyComesFromMeetingsInProgressDedupedAndCapped() {
        let terms = (0..<150).map { "Term\($0)" }
        let schedule = Schedule(generated_at: at(0), events: [
            CalendarEvent(key: "now", start: at(0), end: at(600), vocabulary: ["Priya", " priya ", "Meridian", ""] + terms),
            CalendarEvent(key: "later", start: at(5000), end: at(6000), vocabulary: ["Later"])])
        let vocabulary = schedule.vocabulary(at: at(10))
        #expect(vocabulary.prefix(2) == ["Priya", "Meridian"]); #expect(vocabulary.count == Schedule.vocabularyLimit)
        #expect(!vocabulary.contains("Later")); #expect(schedule.vocabulary(at: at(7000)).isEmpty)
    }
}

struct ProcessRunnerTests {
    @Test func stdinReachesTheChildAndStdoutComesBack() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let output = try await LocalProcessRunner().run(ProcessCommand("/bin/cat", [], input: payload, timeout: 10))
        #expect(output.status == 0); #expect(output.stdout == payload)
    }
    @Test func streamHandsOverEachPieceBeforeTheCommandEnds() async throws {
        let started = Date()
        let firstAt = Mutex<TimeInterval?>(nil), pieces = Mutex<[Data]>([])
        let output = try await LocalProcessRunner().stream(ProcessCommand("/bin/sh", ["-c", "printf one; sleep 0.6; printf two"], timeout: 10)) { piece in
            firstAt.withLock { if $0 == nil { $0 = Date().timeIntervalSince(started) } }
            pieces.withLock { $0.append(piece) }
        }
        #expect(output.stdout == Data("onetwo".utf8))
        #expect(pieces.withLock { $0.reduce(Data(), +) } == output.stdout)
        #expect(try #require(firstAt.withLock { $0 }) < 0.5, "the first piece arrives while the command still runs")
    }
    @Test func exitStatusIsReported() async throws {
        let output = try await LocalProcessRunner().run(ProcessCommand("/bin/sh", ["-c", "printf '{\"size\": 4}'; exit 3"], timeout: 10))
        #expect(output.status == 3); #expect(output.stdout == Data(#"{"size": 4}"#.utf8))
    }
    @Test func deadlineKillsAHungCommand() async throws {
        let started = Date()
        let output = try await LocalProcessRunner().run(ProcessCommand("/bin/sleep", ["30"], timeout: 0.5))
        #expect(output.status == 128 + SIGKILL); #expect(Date().timeIntervalSince(started) < 5)
    }
    @Test func backgroundGrandchildHoldingStdoutDoesNotBlockTheResult() async throws {
        let started = Date()
        let output = try await LocalProcessRunner().run(ProcessCommand("/bin/sh", ["-c", "(/bin/sleep 5 &); printf done"], timeout: 10))
        #expect(output.stdout == Data("done".utf8)); #expect(Date().timeIntervalSince(started) < 3)
    }
}

struct OutboxReplay {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LML_REPLAY_SESSION"] != nil))
    func bytesPerCall() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LML_REPLAY_SESSION"]!)
        let simulation = try ReplaySimulation(directory: source)
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let mini = MiniStub()
        let outbox = Outbox(paths: SessionPaths(root: root, test: true), mini: Mini(host: "mini"), runner: mini, interval: 30)
        let result = try await simulation.run(into: root, tickEvery: 1, tick: { now in
            let beat = Heartbeat(at: now, app_version: "replay", state: .recording, sid: simulation.sid, mic_ok: true, audio_ok: true)
            try await outbox.tick(at: now, heartbeat: beat)
        }, settled: { url in (try? JSON.read(SyncState.self, from: url).done_signaled) == true })
        let calls = await mini.calls
        let transcriptBytes = calls.filter { $0.name == "live-meeting-receive" && $0.arguments[1] == "transcript.jsonl" }.reduce(0) { $0 + $1.input.count }
        let liveBytes = calls.filter { $0.name == "live-meeting-receive" && $0.arguments[1] == "live.json" }.reduce(0) { $0 + $1.input.count }
        let schedule = (try? Data(contentsOf: root.appendingPathComponent("schedule.json")).count) ?? 0
        print("REPLAY new mini_bytes=\(await mini.bytesWritten) mini_transcript=\(transcriptBytes) mini_live=\(liveBytes) mac_bytes=\(result.syncBytes + schedule) mac_sync=\(result.syncBytes) remote_calls=\(calls.count) receives=\(calls.filter { $0.name == "live-meeting-receive" }.count) ticks=\(result.ticks) transcript=\(result.transcriptBytes) done=\(await mini.done[simulation.sid] ?? -1)")
        #expect(await mini.done[simulation.sid] == result.transcriptBytes)
        #expect(await mini.file(simulation.sid, "transcript.jsonl")?.count == result.transcriptBytes)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LML_SSH_SMOKE"] == "1", "Talks to the real mini"))
struct RealMiniTests {
    @Test func stdinAndStdoutCrossTheMultiplexedConnectionWithoutWaitingForTheMaster() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("lml-ssh-\(UUID().uuidString.prefix(8))")
        try PrivateFiles.directory(root)
        let paths = SessionPaths(root: root)
        defer {
            let exit = Outbox.sshArguments(paths: paths, mini: Mini(host: "mini")) + ["-O", "exit", "mini"]
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = exit
            process.standardError = FileHandle.nullDevice; try? process.run(); process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let payload = Data((0..<300_000).map { UInt8(65 + $0 % 26) })
        var seconds: [Double] = []
        for _ in 0..<3 {
            let started = Date()
            let output = try await LocalProcessRunner().run(Outbox.remoteCommand(paths: paths, mini: Mini(host: "mini"), "cat", [], input: payload, timeout: 30))
            seconds.append(Date().timeIntervalSince(started))
            #expect(output.status == 0); #expect(output.stdout == payload)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ssh-mini").path))
        let absent = try await LocalProcessRunner().run(Outbox.remoteCommand(paths: paths, mini: Mini(host: "mini"), "live-meeting-receive", [sid, "transcript.jsonl", "0"], input: Data(), timeout: 30))
        print("SSH_SMOKE seconds=\(seconds.map { String(format: "%.2f", $0) }) receive_status=\(absent.status)")
        #expect(seconds.allSatisfy { $0 < 10 })
    }
}
