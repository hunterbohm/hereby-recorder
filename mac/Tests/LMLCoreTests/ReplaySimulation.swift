import Foundation
import Darwin
@testable import LMLCore

struct ReplaySimulation {
    struct Row { let at: Date; let ts1: Date; let seq: Int; let line: Data }
    let rows: [Row]
    let meta: SessionMeta
    /// The recorded session's final speech intervals, reused in every synthesized live.json.
    let speech: Data
    var sid: String { meta.sid }

    init(directory: URL) throws {
        meta = try JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json"))
        let recorded = (try? Data(contentsOf: directory.appendingPathComponent("live.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["speech"]
        speech = try recorded.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data(#"{"me":[],"them":[]}"#.utf8)
        struct Times: Decodable { let at: Date; let ts1: Date; let seq: Int? }
        let decoder = JSON.decoder()
        let bytes = try Data(contentsOf: directory.appendingPathComponent("transcript.jsonl"))
        rows = try bytes.split(separator: 10).map { line in
            let times = try decoder.decode(Times.self, from: Data(line))
            return Row(at: times.at, ts1: times.ts1, seq: times.seq ?? 0, line: Data(line) + Data("\n".utf8))
        }
    }

    struct Result { var ticks = 0; var syncWrites = 0; var syncBytes = 0; var liveBytesAtClose = 0; var transcriptBytes = 0 }

    /// `liveFinals` reproduces the legacy writer, which also copied the last 15 minutes of finals into live.json.
    func run(into root: URL, tickEvery: Int, liveFinals: Bool = false, tick: (Date) async throws -> Void, settled: (URL) throws -> Bool) async throws -> Result {
        let directory = root.appendingPathComponent("sessions").appendingPathComponent(sid)
        try PrivateFiles.directory(directory)
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try PrivateFiles.write(Data(), to: transcript)
        let sync = directory.appendingPathComponent("sync.json")
        var current = SessionMeta(sid: sid, started_at: meta.started_at, test: true)
        current.apps = meta.apps; current.segments = 0
        var result = Result()
        var appended = 0
        var lastInode: ino_t = 0
        func observeSync() {
            var info = stat()
            guard stat(sync.path, &info) == 0, info.st_ino != lastInode else { return }
            lastInode = info.st_ino; result.syncWrites += 1; result.syncBytes += Int(info.st_size)
        }
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        let ended = meta.ended_at ?? meta.heartbeat_at
        let seconds = Int(ended.timeIntervalSince(meta.started_at).rounded(.up))
        for second in 0...seconds {
            let now = meta.started_at.addingTimeInterval(Double(second))
            var chunk = Data()
            while appended < rows.count && rows[appended].at <= now { chunk += rows[appended].line; appended += 1 }
            if !chunk.isEmpty { try handle.seekToEnd(); try handle.write(contentsOf: chunk); try handle.synchronize() }
            current.segments = appended
            let live = liveSnapshot(at: now, through: appended, finals: liveFinals)
            try PrivateFiles.write(live, to: directory.appendingPathComponent("live.json"))
            if second % 5 == 0 {
                current.heartbeat_at = now; current.version += 1
                try PrivateFiles.write(current, to: directory.appendingPathComponent("meta.json"))
            }
            if second % tickEvery == 0 { try await tick(now); result.ticks += 1; observeSync() }
        }
        var chunk = Data()
        while appended < rows.count { chunk += rows[appended].line; appended += 1 }
        if !chunk.isEmpty { try handle.seekToEnd(); try handle.write(contentsOf: chunk); try handle.synchronize() }
        let finalLive = liveSnapshot(at: ended, through: appended, finals: liveFinals)
        result.liveBytesAtClose = finalLive.count
        try PrivateFiles.write(finalLive, to: directory.appendingPathComponent("live.json"))
        current.state = .closed; current.ended_at = ended; current.heartbeat_at = ended; current.version += 1; current.segments = appended
        try PrivateFiles.write(current, to: directory.appendingPathComponent("meta.json"))
        for step in 0..<30 {
            try await tick(ended.addingTimeInterval(Double(step * tickEvery)))
            result.ticks += 1; observeSync()
            if try settled(sync) { break }
        }
        result.transcriptBytes = try Data(contentsOf: transcript).count
        return result
    }

    private func liveSnapshot(at now: Date, through count: Int, finals: Bool) -> Data {
        let since = now.addingTimeInterval(-900)
        let visible = rows.prefix(count).filter { $0.ts1 >= since }
        var data = Data("{\"at\":\"".utf8)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        data += Data(formatter.string(from: now).utf8)
        data += Data("\",\"finals\":[".utf8)
        for (index, row) in visible.enumerated() where finals {
            if index > 0 { data += Data(",".utf8) }
            data += row.line.dropLast()
        }
        data += Data("],\"partials\":{\"me\":null,\"them\":null},\"seq_hi\":\(visible.last?.seq ?? 0),\"sid\":\"\(sid)\",\"speech\":".utf8)
        data += speech + Data(",\"v\":1}".utf8)
        return data
    }
}
