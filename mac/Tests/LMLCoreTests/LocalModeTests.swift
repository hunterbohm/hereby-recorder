import Foundation
import Testing
import Synchronization
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private let first = "20261013-190012-a3f1"
private let second = "20261013-193012-b4c2"
private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let script = repository.appendingPathComponent("handoff/hereby-handoff.sh")
private let handoff = DoneCommand.handoff(script: script)

private final class Printed: Sendable {
    private let lines = Mutex<[Handoff]>([])
    var all: [Handoff] { lines.withLock { $0 } }
    func add(_ handoff: Handoff) { lines.withLock { $0.append(handoff) } }
}

private struct Local {
    let printed = Printed()
    let root: URL
    let paths: SessionPaths
    init() throws {
        let temporary = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        root = URL(fileURLWithPath: temporary).appendingPathComponent("lml-local-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        paths = SessionPaths(root: root)
    }
    func session(_ sid: String, _ state: SessionMeta.State, endedAt: Date? = nil, transcript: String = "{\"seq\": 1}\n") throws {
        let directory = paths.session(sid)
        try PrivateFiles.directory(directory)
        var meta = SessionMeta(sid: sid, started_at: epoch)
        meta.state = state
        meta.ended_at = state == .active ? nil : endedAt ?? epoch
        try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json"))
        try PrivateFiles.write(Data(transcript.utf8), to: directory.appendingPathComponent("transcript.jsonl"))
    }
    func folder(_ sid: String) -> String { paths.session(sid).path }
    func outbox(mini: Mini? = nil, done: DoneCommand?, runner: any ProcessRunner = LocalProcessRunner()) -> Outbox {
        let printed = printed
        return Outbox(paths: paths, mini: mini, done: done, onHandoff: { printed.add($0) }, runner: runner)
    }
    func sync(_ sid: String) throws -> SyncState { try JSON.read(SyncState.self, from: paths.session(sid).appendingPathComponent("sync.json")) }
    func exists(_ sid: String) -> Bool { FileManager.default.fileExists(atPath: paths.session(sid).path) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct LocalModeTests {
    @Test func aFinishedSessionIsNotReadAgainOnLaterPasses() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([0, 0], stdout: Data("/p/transcript.jsonl\n".utf8))
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        // Reset the record to a fresh one of the same size and time, so it looks unchanged on disk: a pass that
        // read the session again would see a session never handed off and run the handoff a second time.
        let file = local.paths.session(first).appendingPathComponent("sync.json")
        var info = stat(); #expect(stat(file.path, &info) == 0)
        let blank = Data(("{}" + String(repeating: " ", count: Int(info.st_size) - 2)).utf8)
        let fd = open(file.path, O_WRONLY); #expect(fd >= 0)
        _ = blank.withUnsafeBytes { pwrite(fd, $0.baseAddress, blank.count, 0) }
        var times = [info.st_atimespec, info.st_mtimespec]
        _ = futimens(fd, &times); close(fd)
        #expect(Outbox.stamp(file) == [Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)])
        try await outbox.tick(at: at(2), force: true)
        #expect(await runner.recorded().count == 1)
        #expect(local.printed.all.count == 1)
    }

    @Test func forgottenSessionsWrittenByAnotherProcessAreSeen() async throws {
        let local = try Local(); defer { local.cleanup() }
        let outbox = local.outbox(done: handoff)
        let other = local.outbox(done: handoff)
        #expect(try await outbox.tombstones().isEmpty)
        try await other.recordForget(first, at: at(1))
        #expect(try await outbox.tombstones().keys.sorted() == [first])
        try await other.recordForget(second, at: at(2))
        #expect(try await outbox.tombstones().keys.sorted() == [first, second])
        try FileManager.default.removeItem(at: local.root.appendingPathComponent("forgotten.json"))
        #expect(try await outbox.tombstones().isEmpty)
    }

    @Test func aFinishedSessionRunsTheDoneCommandOnItsFolderWithNoMini() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([0], stdout: Data("/path/transcript.jsonl\n".utf8))
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        let commands = await runner.recorded()
        #expect(commands.count == 1)
        #expect(commands[0].executable == "/usr/bin/env")
        #expect(commands[0].arguments == [script.path, local.folder(first)])
        #expect(local.printed.all == [Handoff(sid: first, output: "/path/transcript.jsonl")])
        #expect(try local.sync(first).stage == .doneSignaled)
    }

    @Test func aHandoffIsSavedBeforeItIsPrintedAndPrintedExactlyOnce() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let file = local.paths.session(first).appendingPathComponent("sync.json")
        let savedWhenPrinted = Mutex<[SyncState]>([])
        let outbox = Outbox(paths: local.paths, mini: nil, done: handoff, onHandoff: { _ in
            if let state = try? JSON.read(SyncState.self, from: file) { savedWhenPrinted.withLock { $0.append(state) } }
        }, runner: StubRunner([0], stdout: Data("/p/transcript.jsonl\n".utf8)))
        try await outbox.tick(at: at(1))
        try await outbox.tick(at: at(2), force: true)
        try await outbox.tick(at: at(3), force: true)
        let seen = savedWhenPrinted.withLock { $0 }
        #expect(seen.count == 1 && seen[0].stage == .doneSignaled && seen[0].pending_handoff == "/p/transcript.jsonl")
        let after = try local.sync(first)
        #expect(after.stage == .doneSignaled && after.pending_handoff == nil)
    }

    @Test func aMarkerLeftByACrashBeforeTheLineWasSavedStillPrintsThePath() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let directory = local.paths.session(first)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("transcript.jsonl")).count
        try PrivateFiles.write(Data("{\"at\": \"2026-10-13T19:30:00Z\", \"state\": \"closed\", \"transcript_bytes\": \(bytes)}\n".utf8),
                               to: directory.appendingPathComponent("handoff.json"))
        let outbox = local.outbox(done: handoff)
        try await outbox.tick(at: at(1))
        #expect(local.printed.all == [Handoff(sid: first, output: directory.appendingPathComponent("transcript.jsonl").path)])
        #expect(try local.sync(first).stage == .doneSignaled)
    }

    @Test func aHandoffSavedBeforeACrashIsPrintedOnTheNextPassAndCleared() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        var crashed = SyncState()
        crashed.stage = .doneSignaled; crashed.pending_handoff = "/p/transcript.jsonl"
        try PrivateFiles.write(crashed, to: local.paths.session(first).appendingPathComponent("sync.json"))
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        #expect(local.printed.all == [Handoff(sid: first, output: "/p/transcript.jsonl")])
        let state = try local.sync(first)
        #expect(state.stage == .doneSignaled && state.pending_handoff == nil)
        try await outbox.tick(at: at(2), force: true)
        let ran = await runner.recorded()
        #expect(local.printed.all.count == 1 && ran.isEmpty)
    }

    @Test func aSessionStillRecordingIsLeftAlone() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .active)
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        let ran = await runner.recorded()
        #expect(ran.isEmpty && local.printed.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: local.paths.session(first).appendingPathComponent("sync.json").path))
    }

    @Test func aSecondTickDoesNotRunAHandedOffSession() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        try await outbox.tick(at: at(2), force: true)
        let ran = await runner.recorded()
        #expect(ran.count == 1 && local.printed.all.count == 1)
    }

    @Test func aFailedCommandKeepsTheSessionPendingAndRetriesAfterTheBackoff() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([1, 0])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        let state = try local.sync(first)
        #expect(local.printed.all.isEmpty && state.stage == .closeAcked && state.failures == 1)
        #expect(state.retry_at == at(1).addingTimeInterval(Outbox.backoff(failures: 1)))
        try await outbox.tick(at: at(2))
        let early = await runner.recorded()
        #expect(early.count == 1)
        try await outbox.tick(at: at(7))
        let late = await runner.recorded()
        #expect(late.count == 2 && local.printed.all.count == 1)
        let done = try local.sync(first)
        #expect(done.stage == .doneSignaled && done.failures == 0 && done.retry_at == nil)
    }

    @Test func twoSessionsFinishedBackToBackEachRunOnce() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed); try local.session(second, .closed)
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.tick(at: at(1))
        try await outbox.tick(at: at(2), force: true)
        let sessions = await runner.recorded().map { $0.arguments.last }
        #expect(sessions == [local.folder(first), local.folder(second)])
        #expect(local.printed.all.map(\.sid) == [first, second])
    }

    @Test func aCrashedSessionIsHandedOffAfterRecovery() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .active)
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.recover()
        let meta = try JSON.read(SessionMeta.self, from: local.paths.session(first).appendingPathComponent("meta.json"))
        #expect(meta.state == .crashed)
        try await outbox.tick(at: at(1))
        let state = try local.sync(first)
        #expect(local.printed.all.map(\.sid) == [first] && state.stage == .doneSignaled)
    }

    @Test func forgettingASessionDeletesItAndTheDoneCommandNeverRuns() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        try await outbox.forget(first, at: at(1))
        try await outbox.tick(at: at(2), force: true)
        let ran = await runner.recorded()
        let tombstones = try await outbox.tombstones()
        #expect(!local.exists(first) && ran.isEmpty)
        #expect(tombstones[first]?.acked == true)
    }

    @Test func sessionsPastRetentionArePurgedOnTheMac() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed, endedAt: at(-20 * 86400)); try local.session(second, .closed, endedAt: at(-86400))
        let runner = StubRunner([])
        let outbox = local.outbox(done: handoff, runner: runner)
        let expired = try Retention.expired(in: local.paths, days: Retention.days(14, schedule: nil), now: epoch)
        #expect(expired == [first])
        for sid in expired { try await outbox.forget(sid, at: epoch) }
        let ran = await runner.recorded()
        #expect(!local.exists(first) && local.exists(second) && ran.isEmpty)
    }

    @Test func withNoDoneCommandAFinishedSessionWaits() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let runner = StubRunner([])
        let outbox = local.outbox(done: nil, runner: runner)
        try await outbox.tick(at: at(1))
        let ran = await runner.recorded()
        #expect(ran.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: local.paths.session(first).appendingPathComponent("sync.json").path))
    }

    @Test func aMiniKeepsTheDoneSignalOnTheMini() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let mini = MiniStub()
        let outbox = local.outbox(mini: Mini(host: "mini"), done: handoff, runner: mini)
        try await outbox.tick(at: at(1))
        let signaled = await mini.done[first]
        let calls = await mini.named("live-meeting-done")
        #expect(signaled == 11 && local.printed.all.isEmpty && calls.count == 1)
    }

    @Test func theHandoffScriptPrintsThePathOnceThroughTheRealRunner() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .crashed)
        let outbox = local.outbox(done: handoff)
        try await outbox.tick(at: at(1))
        let transcript = local.folder(first) + "/transcript.jsonl"
        #expect(local.printed.all == [Handoff(sid: first, output: transcript)])
        let marker = try String(contentsOf: local.paths.session(first).appendingPathComponent("handoff.json"), encoding: .utf8)
        #expect(marker.contains("\"state\": \"crashed\""))
        let again = try await LocalProcessRunner().run(handoff.process(session: local.paths.session(first), timeout: 20))
        #expect(again.status == 0 && again.stdout.isEmpty)
    }

    @Test func aMissingScriptFailsAndIsRetried() async throws {
        let local = try Local(); defer { local.cleanup() }
        try local.session(first, .closed)
        let outbox = local.outbox(done: DoneCommand.handoff(script: local.root.appendingPathComponent("absent.sh")))
        try await outbox.tick(at: at(1))
        let state = try local.sync(first)
        #expect(local.printed.all.isEmpty && state.stage == .closeAcked && state.failures == 1 && state.retry_at != nil)
    }
}

struct DoneCommandTests {
    @Test func splitsLikeAShell() throws {
        #expect(try ShellWords.split(#"hermes cron run 'listener meeting'  "a \"b\" c" d\ e"#) == ["hermes", "cron", "run", "listener meeting", "a \"b\" c", "d e"])
        #expect(try ShellWords.split("''") == [""])
        #expect(try ShellWords.split("   ") == [])
        #expect(throws: SettingsError.self) { _ = try ShellWords.split("run 'open") }
        #expect(throws: SettingsError.self) { _ = try ShellWords.split("run \\") }
        #expect(throws: SettingsError.self) { _ = try DoneCommand("   ") }
    }

    @Test func aSessionWordBecomesTheFolderAndOtherCommandsGetNone() throws {
        let folder = URL(fileURLWithPath: "/tmp/with space/sid")
        let handoff = DoneCommand.handoff(script: URL(fileURLWithPath: "/opt/hereby handoff/hereby-handoff.sh"))
        #expect(handoff.process(session: folder, timeout: 5).arguments == ["/opt/hereby handoff/hereby-handoff.sh", "/tmp/with space/sid"])
        let hermes = try DoneCommand("hermes cron run listener-meeting-processing")
        #expect(hermes.process(session: folder, timeout: 5) == ProcessCommand("/usr/bin/env", ["hermes", "cron", "run", "listener-meeting-processing"], timeout: 5))
    }

    @Test func theSettingWinsAndTheDefaultIsTheHandoffScript() throws {
        let executable = repository.appendingPathComponent("mac/.build/debug/lml")
        let set = try Settings(toml: "done_command = \"hermes cron run listener-meeting-processing\"\n")
        #expect(try DoneCommand.resolve(set, executable: executable) == DoneCommand(words: ["hermes", "cron", "run", "listener-meeting-processing"]))
        #expect(try DoneCommand.resolve(Settings(), executable: executable) == handoff)
        #expect(Settings().doneCommand == nil)
        #expect(try DoneCommand.resolve(Settings(), executable: URL(fileURLWithPath: "/nowhere/lml")) == nil)
        #expect(throws: SettingsError.self) { _ = try DoneCommand.resolve(Settings(toml: "done_command = \"run 'x\"\n"), executable: executable) }
    }

    @Test func theScriptIsFoundInAnAppsResources() throws {
        let app = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-app-\(UUID().uuidString)/LML.app/Contents")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let bundled = app.appendingPathComponent("Resources/hereby-handoff.sh")
        try FileManager.default.copyItem(at: script, to: bundled)
        let executable = app.appendingPathComponent("MacOS/lml")
        #expect(DoneCommand.locateHandoff(executable: executable)?.path == bundled.resolvingSymlinksInPath().path)
    }
}
