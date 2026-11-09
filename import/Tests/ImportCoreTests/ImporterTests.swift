import Foundation
import Testing
@testable import ImportCore

private actor FakeTranscriber: AudioTranscriber {
    var calls = 0
    var result: Result<[Utterance], Error>
    init(_ result: Result<[Utterance], Error>) { self.result = result }
    func transcribe(_ plan: AudioPlan) async throws -> [Utterance] { calls += 1; return try result.get() }
    func set(_ result: Result<[Utterance], Error>) { self.result = result }
}

private actor FakeRunner: CommandRunner {
    struct Call: Equatable { var remote: [String]; var stdin: Data }
    var calls: [Call] = []
    var script: [String: [Int32]] = [:]
    var shortAck = false
    func respond(_ command: String, _ statuses: [Int32]) { script[command] = statuses }
    func acknowledgeShort(_ value: Bool) { shortAck = value }
    func run(_ remote: [String], stdin: Data) async throws -> CommandResult {
        calls.append(Call(remote: remote, stdin: stdin))
        let command = remote[0] + (remote.count > 2 && remote[0] == "live-meeting-receive" ? " " + remote[2] : "")
        let status = script[command]?.isEmpty == false ? script[command]!.removeFirst() : 0
        return CommandResult(status: status, stdout: Data(#"{"size": \#(stdin.count - (shortAck ? 1 : 0))}"#.utf8))
    }
}

private struct Failure: Error {}

private let speech = [Utterance(speaker: .me, words: [Word(start: 1, end: 2, text: " Hello.")]),
                      Utterance(speaker: .them, words: [Word(start: 2.5, end: 3, text: " Hi.")])]
private let plan = AudioPlan.tracks(URL(fileURLWithPath: "/dev/null"), [.me, .them])

private func recording(_ id: String = "notes:A", transcript: [Utterance]? = nil, audio: AudioPlan? = plan, source: Source = .phone) -> Recording {
    Recording(id: id, source: source, title: "Call", startedAt: epoch, duration: 60, audio: audio, transcript: transcript)
}
private func importer(_ root: ImportRoot, _ transcriber: FakeTranscriber, runner: FakeRunner? = nil, now: Date = epoch.addingTimeInterval(7200)) throws -> Importer {
    try Importer(root: root, transcriber: transcriber, pusher: runner.map { Pusher(runner: $0) }, now: now)
}

struct ImporterTests {
    @Test func importsEachRecordingOnceAsAClosedSession() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.success(speech))
        let first = try await importer(root, transcriber).run(recording())
        #expect(first.outcome == .imported && first.rows == 2)
        let sid = try #require(first.sid)
        let directory = root.session(sid)
        let meta = try JSON.decoder().decode(SessionMeta.self, from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
        #expect(meta.state == "closed" && meta.source == .phone && meta.asr == SessionBuilder.speechASR)
        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        #expect(transcript.hasSuffix("\n"))
        #expect(transcript.split(separator: "\n").count == 2)

        let second = try await importer(root, transcriber).run(recording())
        #expect(second.outcome == .skipped && second.sid == sid)
        #expect(await transcriber.calls == 1)
    }

    @Test func prefersApplesTranscript() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.success([]))
        let outcome = try await importer(root, transcriber).run(recording(transcript: speech))
        #expect(outcome.outcome == .imported && outcome.rows == 2)
        #expect(await transcriber.calls == 0)
        let meta = try JSON.decoder().decode(SessionMeta.self, from: Data(contentsOf: root.session(outcome.sid!).appendingPathComponent("meta.json")))
        #expect(meta.asr == SessionBuilder.appleASR)
    }

    @Test func waitsForApplesTranscriptThenTranscribesOnDevice() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.success(speech))
        let early = try await importer(root, transcriber, now: epoch.addingTimeInterval(60 + 60)).run(recording())
        #expect(early.outcome == .pending && early.reason == "waiting for Apple transcript")
        #expect(await transcriber.calls == 0)
        let file = try await importer(root, transcriber, now: epoch.addingTimeInterval(120)).run(recording("file:sha256:x", source: .file))
        #expect(file.outcome == .imported)
        let late = try await importer(root, transcriber).run(recording())
        #expect(late.outcome == .imported)
    }

    @Test func missingAudioStaysPending() async throws {
        let root = ImportRoot(try temporaryDirectory())
        let outcome = try await importer(root, FakeTranscriber(.success(speech))).run(recording(audio: nil))
        #expect(outcome.outcome == .pending && outcome.reason == "audio not downloaded")
        #expect(!FileManager.default.fileExists(atPath: root.ledger.path))
    }

    @Test func silenceIsRecordedSoItIsNotRetried() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.success([]))
        let outcome = try await importer(root, transcriber).run(recording())
        #expect(outcome.outcome == .skipped && outcome.reason == "no speech")
        #expect(!FileManager.default.fileExists(atPath: root.sessions.path))
        _ = try await importer(root, transcriber).run(recording())
        #expect(await transcriber.calls == 1)
    }

    @Test func failedTranscriptionIsRetriedNextRun() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.failure(Failure()))
        #expect(try await importer(root, transcriber).run(recording()).outcome == .failed)
        await transcriber.set(.success(speech))
        #expect(try await importer(root, transcriber).run(recording()).outcome == .imported)
    }

    @Test func pushSendsTranscriptThenMetaThenDoneAndStopsOnceDone() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner()
        let outcome = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(outcome.outcome == .done)
        let sid = try #require(outcome.sid)
        let directory = root.session(sid)
        let transcript = try Data(contentsOf: directory.appendingPathComponent("transcript.jsonl"))
        let meta = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        #expect(await runner.calls == [
            .init(remote: ["live-meeting-receive", sid, "transcript.jsonl", "0"], stdin: transcript),
            .init(remote: ["live-meeting-receive", sid, "meta.json", "0"], stdin: meta),
            .init(remote: ["live-meeting-done", sid, String(transcript.count)], stdin: Data()),
        ])
        let again = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(again.outcome == .skipped)
        #expect(await runner.calls.count == 3)
    }

    @Test func forgottenSessionIsNeverSignaled() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner()
        await runner.respond("live-meeting-receive transcript.jsonl", [4])
        let outcome = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(outcome.outcome == .skipped && outcome.reason == "forgotten on the mini")
        #expect(await runner.calls.count == 1)
        _ = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(await runner.calls.count == 1)
    }

    @Test func staleDoneResendsOnTheNextRun() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner()
        await runner.respond("live-meeting-done", [3])
        let first = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(first.outcome == .failed)
        let second = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(second.outcome == .done)
        #expect(await runner.calls.map { $0.remote[0] } == ["live-meeting-receive", "live-meeting-receive", "live-meeting-done",
                                                             "live-meeting-receive", "live-meeting-receive", "live-meeting-done"])
    }

    @Test func pushFailureKeepsTheSessionForTheNextRun() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner(), transcriber = FakeTranscriber(.success(speech))
        await runner.respond("live-meeting-receive meta.json", [255])
        let first = try await importer(root, transcriber, runner: runner).run(recording())
        #expect(first.outcome == .failed)
        let backlog = try await importer(root, transcriber, runner: runner).pushBacklog(excluding: [])
        #expect(backlog.map(\.outcome) == [.done])
        #expect(await transcriber.calls == 1)
    }

    @Test func shortAcknowledgementIsAFailureAndIsRetried() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner()
        await runner.acknowledgeShort(true)
        let first = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(first.outcome == .failed && first.reason?.contains("acknowledged") == true)
        #expect(await runner.calls.count == 1)
        await runner.acknowledgeShort(false)
        #expect(try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording()).outcome == .done)
    }

    @Test func forgottenAtDoneStopsRetrying() async throws {
        let root = ImportRoot(try temporaryDirectory()), runner = FakeRunner()
        await runner.respond("live-meeting-done", [4])
        let outcome = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(outcome.outcome == .skipped && outcome.state == .forgotten)
        _ = try await importer(root, FakeTranscriber(.success(speech)), runner: runner).run(recording())
        #expect(await runner.calls.count == 3)
    }

    @Test func deletedLocalSessionIsRebuiltUnderTheSameID() async throws {
        let root = ImportRoot(try temporaryDirectory()), transcriber = FakeTranscriber(.success(speech))
        let first = try await importer(root, transcriber).run(recording())
        try FileManager.default.removeItem(at: root.session(first.sid!))
        let second = try await importer(root, transcriber).run(recording())
        #expect(second.outcome == .imported && second.sid == first.sid)
        #expect(FileManager.default.fileExists(atPath: root.session(first.sid!).appendingPathComponent("meta.json").path))
        #expect(await transcriber.calls == 2)
    }

    @Test func ledgerAccountsForSilentAndForgottenRecordingsSoInboxFilesMove() async throws {
        let root = ImportRoot(try temporaryDirectory())
        let silent = try await importer(root, FakeTranscriber(.success([]))).run(recording("file:sha256:silent", source: .file))
        #expect(silent.isImported)
        let failed = try await importer(root, FakeTranscriber(.failure(Failure()))).run(recording("file:sha256:broken", source: .file))
        #expect(!failed.isImported)
    }

    @Test func withoutPushNothingIsSent() async throws {
        let root = ImportRoot(try temporaryDirectory())
        let importer = try importer(root, FakeTranscriber(.success(speech)))
        #expect(await importer.run(recording()).outcome == .imported)
        #expect(await importer.pushBacklog(excluding: []).isEmpty)
        #expect(await importer.entry("notes:A")?.state == .written)
    }

    @Test func sshRunnerStreamsLargeInputAndReportsTheExitStatus() async throws {
        let script = try temporaryDirectory().appendingPathComponent("fake-ssh")
        try ("#!/bin/sh\n" + #"n=$(wc -c | tr -d " ")"# + "\n" + #"printf '{"size": %s}' "$n""# + "\nexit 3\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let payload = Data(repeating: 0x61, count: 5_000_000)
        let result = try await SSHRunner(controlPath: URL(fileURLWithPath: "/tmp/unused"), host: "mini", executable: script).run(["live-meeting-receive"], stdin: payload)
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == #"{"size": 5000000}"#)
    }

    @Test func sshRunnerGivesUpOnAStalledConnection() async throws {
        let script = try temporaryDirectory().appendingPathComponent("stalled-ssh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let started = Date()
        await #expect(throws: PushError.timeout(seconds: 0.5)) {
            try await SSHRunner(controlPath: URL(fileURLWithPath: "/tmp/unused"), host: "mini", executable: script, timeout: 0.5).run(["live-meeting-done"], stdin: Data())
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func sshCarriesTheContractCommandToTheSettingsHost() {
        let arguments = SSHRunner(controlPath: URL(fileURLWithPath: "/tmp/x y/ssh-mini"), host: "studio").arguments(["live-meeting-done", "20260921-141320-abcd", "12"])
        #expect(arguments.suffix(2) == ["studio", "live-meeting-done 20260921-141320-abcd 12"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ControlPath=\"/tmp/x y/ssh-mini\""))
    }
}
