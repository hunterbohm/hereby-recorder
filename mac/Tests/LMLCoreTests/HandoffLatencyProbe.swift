import Foundation
import Testing
@testable import LMLCore

private let environment = ProcessInfo.processInfo.environment

/// Runs the mini's commands from a local checkout instead of over ssh.
private actor LocalMiniRunner: ProcessRunner {
    let directory: String
    let inner = LocalProcessRunner()
    init(directory: String) { self.directory = directory }
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        let host = try #require(command.arguments.lastIndex(of: "mini"))
        let words = Array(command.arguments[(host + 1)...])
        return try await inner.run(ProcessCommand("\(directory)/\(words[0])", Array(words.dropFirst()), input: command.input, timeout: command.timeout))
    }
    func cancel() async { await inner.cancel() }
}

/// Run by `bench/handoff-latency.sh`: one finished fixture session, timed from its end to the done command's start.
struct HandoffLatencyProbe {
    @Test(.enabled(if: environment["LML_PROBE_MODE"] != nil)) func oneSession() async throws {
        let mode = try #require(environment["LML_PROBE_MODE"])
        let work = URL(fileURLWithPath: try #require(environment["LML_PROBE_WORK"]))
        let stamp = try #require(environment["LML_PROBE_STAMP"])
        let sid = SessionPaths.id(at: Date())
        let paths = SessionPaths(root: work.appendingPathComponent("mac"))
        try PrivateFiles.directory(paths.sessions); try PrivateFiles.directory(paths.session(sid))
        let outbox: Outbox
        switch mode {
        case "mini":
            outbox = Outbox(paths: paths, mini: Mini(host: "mini"), runner: LocalMiniRunner(directory: try #require(environment["LML_PROBE_MINI"])))
        case "local":
            outbox = Outbox(paths: paths, mini: nil, done: DoneCommand(words: [try #require(environment["LML_PROBE_STUB"]), "{session}"]))
        default:
            Issue.record("unknown mode \(mode)"); return
        }
        let ended = Date()
        var meta = SessionMeta(sid: sid, started_at: ended.addingTimeInterval(-600))
        meta.state = .closed; meta.ended_at = ended; meta.version = 1
        try PrivateFiles.write(meta, to: paths.session(sid).appendingPathComponent("meta.json"))
        let rows = (1...40).map { #"{"seq": \#($0), "ch": "them", "text": "row \#($0) of a fixture meeting"}"# }.joined(separator: "\n") + "\n"
        try PrivateFiles.write(Data(rows.utf8), to: paths.session(sid).appendingPathComponent("transcript.jsonl"))
        let start = Date().timeIntervalSince1970
        try await outbox.tick(at: Date(), force: true)
        var seen: Double?
        for _ in 0..<100 where seen == nil {
            seen = (try? String(contentsOfFile: stamp, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if seen == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let started = try #require(seen)
        let line = "\(environment["LML_PROBE_LABEL"] ?? mode) \(started - ended.timeIntervalSince1970) \(started - start)\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: try #require(environment["LML_PROBE_OUT"])))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
    }
}
