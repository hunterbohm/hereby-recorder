import Foundation
import Testing
@testable import LMLCore

actor LegacyRsyncCounter: ProcessRunner {
    var miniBytes = 0, macStagingBytes = 0, remoteCalls = 0, pushes = 0
    func run(_ command: ProcessCommand) async throws -> Int32 {
        remoteCalls += 1
        guard command.executable == "/usr/bin/rsync" else { return 0 }
        if command.arguments.contains(where: { $0.hasPrefix("mini:") }) && !command.arguments.last!.hasPrefix("mini:") { return 1 }
        let files = command.arguments.filter { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }
        let size = try files.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: $1)[.size] as! Int) }
        miniBytes += size; macStagingBytes += size; pushes += 1
        return 0
    }
    func cancel() async {}
    func totals() -> (Int, Int, Int, Int) { (miniBytes, macStagingBytes, remoteCalls, pushes) }
}

struct LegacyOutboxReplay {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LML_REPLAY_SESSION"] != nil))
    func legacyBytesPerCall() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LML_REPLAY_SESSION"]!)
        let simulation = try ReplaySimulation(directory: source)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-replay-legacy-\(UUID().uuidString)")
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let counter = LegacyRsyncCounter()
        let outbox = Outbox(paths: SessionPaths(root: root, test: true), runner: counter)
        let result = try await simulation.run(into: root, tickEvery: 2, liveFinals: true, tick: { try await outbox.tick(at: $0) }, settled: { url in
            (try? JSON.read(SyncState.self, from: url).close_acked) == true
        })
        let (mini, staging, calls, pushes) = await counter.totals()
        print("REPLAY legacy mini_bytes=\(mini) mac_bytes=\(staging + result.syncBytes) mac_staging=\(staging) mac_sync=\(result.syncBytes) remote_calls=\(calls) pushes=\(pushes) ticks=\(result.ticks) transcript=\(result.transcriptBytes) live_at_close=\(result.liveBytesAtClose)")
        #expect(pushes > 0)
    }
}
