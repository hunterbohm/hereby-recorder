import Foundation
import Darwin
import CryptoKit

public enum SyncFile: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case transcript = "transcript.jsonl", marks = "marks.jsonl", live = "live.json", speakers = "speakers.json", meta = "meta.json"
    public var appendOnly: Bool { self == .transcript || self == .marks }
}

/// Mac-side delivery record for one session, stored as `sync.json`.
public struct SyncState: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable, Equatable {
        case streaming
        case verifying
        case closeAcked = "close_acked"
        case doneSignaled = "done_signaled"
    }
    public var stage: Stage = .streaming
    public var offsets: [SyncFile: Int] = [:]
    public var digests: [SyncFile: String] = [:]
    public var meta_version = 0
    public var meta_state: SessionMeta.State?
    public var pushed_at: Date?
    public var failures = 0
    public var retry_at: Date?
    /// What the done command printed, kept until the recorder has printed it, so a crash cannot lose the line.
    public var pending_handoff: String?
    public var close_acked: Bool { stage == .closeAcked || stage == .doneSignaled }
    public var done_signaled: Bool { stage == .doneSignaled }
    public init() {}
    enum CodingKeys: String, CodingKey {
        case stage, offsets, digests, meta_version, meta_state, pushed_at, failures, retry_at, pending_handoff, close_acked, done_signaled
        case transcript_bytes_acked, meta_acked_version
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offsets = try c.decodeIfPresent([SyncFile: Int].self, forKey: .offsets) ?? [:]
        if let legacy = try c.decodeIfPresent(Int.self, forKey: .transcript_bytes_acked) { offsets[.transcript] = legacy }
        digests = try c.decodeIfPresent([SyncFile: String].self, forKey: .digests) ?? [:]
        meta_version = try c.decodeIfPresent(Int.self, forKey: .meta_version) ?? c.decodeIfPresent(Int.self, forKey: .meta_acked_version) ?? 0
        meta_state = try c.decodeIfPresent(SessionMeta.State.self, forKey: .meta_state)
        pushed_at = try c.decodeIfPresent(Date.self, forKey: .pushed_at)
        failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        retry_at = try c.decodeIfPresent(Date.self, forKey: .retry_at)
        pending_handoff = try c.decodeIfPresent(String.self, forKey: .pending_handoff)
        if let stage = try c.decodeIfPresent(Stage.self, forKey: .stage) { self.stage = stage; return }
        let closed = try c.decodeIfPresent(Bool.self, forKey: .close_acked) ?? false
        // Sessions acked before done signals existed were already filed by the mini's poll.
        let done = try c.decodeIfPresent(Bool.self, forKey: .done_signaled) ?? closed
        stage = done ? .doneSignaled : closed ? .closeAcked : .streaming
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stage, forKey: .stage)
        try c.encode(offsets, forKey: .offsets); try c.encode(digests, forKey: .digests)
        try c.encode(meta_version, forKey: .meta_version); try c.encodeIfPresent(meta_state, forKey: .meta_state)
        try c.encodeIfPresent(pushed_at, forKey: .pushed_at)
        try c.encode(failures, forKey: .failures); try c.encodeIfPresent(retry_at, forKey: .retry_at)
        try c.encodeIfPresent(pending_handoff, forKey: .pending_handoff)
        try c.encode(close_acked, forKey: .close_acked); try c.encode(done_signaled, forKey: .done_signaled)
    }
}

public struct Tombstone: Codable, Sendable {
    public var at: Date
    public var acked = false
    public var failures = 0
    public var retry_at: Date?
    public init(at: Date) { self.at = at }
}

/// Mac heartbeat for `live-meeting-sync-status` (PLAN.md contract C4).
public struct Heartbeat: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case idle, armed, recording, paused }
    public var at: Date
    public var app_version: String
    public var state: State
    public var sid: String?
    public var mic_ok: Bool
    public var audio_ok: Bool
    public init(at: Date, app_version: String, state: State, sid: String?, mic_ok: Bool, audio_ok: Bool) {
        self.at = at; self.app_version = app_version; self.state = state; self.sid = sid; self.mic_ok = mic_ok; self.audio_ok = audio_ok
    }
    public init(at: Date, appVersion: String, snapshot: RecorderSnapshot) {
        let state: State = switch snapshot.phase {
        case .idle, .ended: .idle
        case .armed: .armed
        case .recording: .recording
        case .paused: .paused
        }
        self.init(at: at, app_version: appVersion, state: state, sid: state == .idle ? nil : snapshot.sid,
                  mic_ok: snapshot.micOK, audio_ok: snapshot.audioOK)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at); try c.encode(app_version, forKey: .app_version); try c.encode(state, forKey: .state)
        try c.encode(sid, forKey: .sid); try c.encode(mic_ok, forKey: .mic_ok); try c.encode(audio_ok, forKey: .audio_ok)
    }
}

/// A successful `live-meeting-sync-status` reply; `feed` is nil when the mini sent no readable status.
public struct FeedReceipt: Sendable, Equatable {
    public var at: Date
    public var feed: PanelFeed?
    public init(at: Date, feed: PanelFeed?) { self.at = at; self.feed = feed }
}

/// A finished session the done command took, with what it printed. The recorder prints it at least once.
public struct Handoff: Sendable, Equatable {
    public var sid: String
    public var output: String
    public init(sid: String, output: String) { self.sid = sid; self.output = output }
}

public struct SyncReport: Sendable, Equatable {
    public var receipt: FeedReceipt?
    public var forgottenActive: [String] = []
    /// Ended sessions the mini said were forgotten; already deleted here, reported so the panel drops their frame.
    public var forgottenEnded: [String] = []
    public init(receipt: FeedReceipt? = nil, forgottenActive: [String] = [], forgottenEnded: [String] = []) {
        self.receipt = receipt; self.forgottenActive = forgottenActive; self.forgottenEnded = forgottenEnded
    }
}

public actor Outbox {
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                                    "-o", "ControlMaster=auto", "-o", "ControlPersist=120"]
    public static let heartbeatInterval: TimeInterval = 60
    private let paths: SessionPaths
    /// Nil when meetings stay on this Mac: `tick` then sends nothing and runs `done` itself.
    private let mini: Mini?
    /// What a session that ended on this Mac runs when there is no mini. Nil runs nothing.
    private let done: DoneCommand?
    private let runner: any ProcessRunner
    private let interval: TimeInterval
    private var busy = false
    private var heartbeatDue: Date?
    private var blocked: Set<String> = []
    private var transfers: [String: Task<Forgotten?, Error>] = [:]
    private var tombstoneCache: (stamp: [Int], entries: [String: Tombstone])?
    /// `sync.json` stamps of sessions whose handoff is done and reported; `tick` skips them until that file changes.
    private var finished: [String: [Int]] = [:]
    /// Identifies one version of a file without reading it: inode, size and modification time.
    static func stamp(_ url: URL) -> [Int]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
    }
    private func markIfFinished(_ sid: String, _ state: SyncState, _ directory: URL) {
        guard state.stage == .doneSignaled, state.pending_handoff == nil,
              let stamp = Self.stamp(directory.appendingPathComponent("sync.json")) else { return }
        finished[sid] = stamp
    }
    /// Called with each handoff once it is saved in `sync.json`; one that was saved but not yet reported is reported again after a restart.
    private let onHandoff: (@Sendable (Handoff) -> Void)?
    static let handoffTimeout: TimeInterval = 120
    public init(paths: SessionPaths, mini: Mini?, done: DoneCommand? = nil, onHandoff: (@Sendable (Handoff) -> Void)? = nil,
                runner: any ProcessRunner = LocalProcessRunner(), interval: TimeInterval = 30) {
        self.paths = paths; self.mini = mini; self.done = done; self.onHandoff = onHandoff; self.runner = runner; self.interval = interval
    }
    public static func sshArguments(paths: SessionPaths, mini: Mini) -> [String] {
        sshOptions + ["-o", "ControlPath=\"\(paths.root.appendingPathComponent(mini.controlName).path)\""]
    }
    public static func remoteCommand(paths: SessionPaths, mini: Mini, _ name: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) -> ProcessCommand {
        let target = paths.test ? [mini.host, (["LML_ROOT=\"\(mini.shellRoot(test: true))\"", name] + arguments).joined(separator: " ")] : [mini.host, name] + arguments
        return ProcessCommand("/usr/bin/ssh", sshArguments(paths: paths, mini: mini) + target, input: input, timeout: timeout)
    }
    private func remote(_ mini: Mini, _ name: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) -> ProcessCommand {
        Self.remoteCommand(paths: paths, mini: mini, name, arguments, input: input, timeout: timeout)
    }
    public static func backoff(failures: Int) -> TimeInterval { min(60, 5 * pow(2, Double(min(4, max(0, failures - 1))))) }
    static func timeout(bytes: Int) -> TimeInterval { min(120, 15 + Double(bytes) / 50_000) }

    /// `forgotten.json`, decoded again only when the file changes (other processes write it under `forgotten.lock`).
    public func tombstones() throws -> [String: Tombstone] {
        let url = paths.root.appendingPathComponent("forgotten.json")
        guard let stamp = Self.stamp(url) else { tombstoneCache = nil; return [:] }
        if let tombstoneCache, tombstoneCache.stamp == stamp { return tombstoneCache.entries }
        let entries = try JSON.read([String: Tombstone].self, from: url)
        tombstoneCache = (stamp, entries)
        return entries
    }
    private func updateTombstones(_ update: (inout [String: Tombstone]) -> Void) throws {
        let fd = open(paths.root.appendingPathComponent("forgotten.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN); close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        var entries = try tombstones()
        update(&entries)
        try PrivateFiles.write(entries, to: paths.root.appendingPathComponent("forgotten.json"))
    }
    public func cancelSession(_ sid: String) async {
        blocked.insert(sid)
        transfers[sid]?.cancel()
        await runner.cancel()
        _ = await transfers[sid]?.result
    }
    /// Lets a session cancelled by `cancelSession` sync again, for a capture that failed rather than was forgotten.
    public func resume(_ sid: String) { blocked.remove(sid) }
    /// Kills the remote command in flight, if any.
    public func interrupt() async { await runner.cancel() }
    public func recordForget(_ sid: String, at now: Date) throws {
        guard SessionPaths.validID(sid) else { throw CocoaError(.fileReadInvalidFileName) }
        try PrivateFiles.directory(paths.root)
        let localOnly = mini == nil
        try updateTombstones { entries in
            if entries[sid] == nil {
                var tombstone = Tombstone(at: now)
                tombstone.acked = localOnly
                entries[sid] = tombstone
            }
        }
    }
    public func deleteSession(_ sid: String) throws {
        guard SessionPaths.validID(sid) else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = paths.session(sid)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    public func forget(_ sid: String, at now: Date) async throws {
        guard SessionPaths.validID(sid) else { throw CocoaError(.fileReadInvalidFileName) }
        await cancelSession(sid)
        try recordForget(sid, at: now)
        try deleteSession(sid)
    }
    public func recover() throws {
        try PrivateFiles.directory(paths.root); try PrivateFiles.directory(paths.sessions)
        let forgotten = try tombstones()
        for directory in try FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil) where SessionPaths.validID(directory.lastPathComponent) {
            if forgotten[directory.lastPathComponent] != nil { try FileManager.default.removeItem(at: directory); continue }
            let url = directory.appendingPathComponent("meta.json")
            guard var meta = try? JSON.read(SessionMeta.self, from: url) else { continue }
            if meta.state == .active {
                meta.state = .crashed; meta.ended_at = meta.heartbeat_at; meta.version += 1
                try PrivateFiles.write(meta, to: url)
                var state = try syncState(directory)
                state.stage = .streaming; state.retry_at = nil
                try PrivateFiles.write(state, to: directory.appendingPathComponent("sync.json"))
            }
        }
    }
    private func syncState(_ directory: URL) throws -> SyncState {
        let url = directory.appendingPathComponent("sync.json")
        return FileManager.default.fileExists(atPath: url.path) ? try JSON.read(SyncState.self, from: url) : SyncState()
    }

    @discardableResult
    public func tick(at now: Date, heartbeat: Heartbeat? = nil, pushSessions: Bool = true, force: Bool = false) async throws -> SyncReport {
        var report = SyncReport()
        guard !busy, mini != nil || done != nil else { return report }
        busy = true; defer { busy = false }
        try PrivateFiles.directory(paths.root)
        if let mini {
            if let heartbeat, (heartbeatDue ?? .distantPast) <= now {
                let receipt = await syncStatus(heartbeat, at: now, mini: mini)
                heartbeatDue = now.addingTimeInterval(receipt == nil ? 15 : Self.heartbeatInterval)
                report.receipt = receipt
            }
            for (sid, tombstone) in try tombstones().sorted(by: { $0.key < $1.key }) where !tombstone.acked && (tombstone.retry_at ?? .distantPast) <= now {
                let output = try? await runner.run(remote(mini, "live-meeting-forget", [sid], timeout: 20))
                try updateTombstones { current in
                    guard var entry = current[sid] else { return }
                    if output?.status == 0 { entry.acked = true; entry.retry_at = nil }
                    else { entry.failures += 1; entry.retry_at = now.addingTimeInterval(Self.backoff(failures: entry.failures)) }
                    current[sid] = entry
                }
            }
        }
        guard pushSessions, FileManager.default.fileExists(atPath: paths.sessions.path) else { return report }
        for directory in try FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            let sid = directory.lastPathComponent
            if let stamp = finished[sid], stamp == Self.stamp(directory.appendingPathComponent("sync.json")) { continue }
            guard SessionPaths.validID(sid), !blocked.contains(sid), try tombstones()[sid] == nil else { continue }
            let task = Task { try await self.sync(directory, sid: sid, at: now, force: force, mini: mini) }
            transfers[sid] = task
            let result = await task.result
            transfers[sid] = nil
            switch result {
            case .success(.forgottenActive): report.forgottenActive.append(sid)
            case .success(.forgottenEnded): report.forgottenEnded.append(sid)
            case .success(nil): break
            case .failure(let error) where error is CancellationError: break
            case .failure: FileHandle.standardError.write(Data("sync_failed sid=\(sid)\n".utf8))
            }
        }
        return report
    }

    /// Pushes every due session now, ignoring backoff; waits up to `seconds` for a tick already running.
    @discardableResult
    public func flush(within seconds: TimeInterval) async -> SyncReport {
        let deadline = Date().addingTimeInterval(seconds)
        while busy, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return (try? await tick(at: Date(), force: true)) ?? SyncReport()
    }

    private struct SizeReply: Decodable { var size: Int }
    private enum Delivery { case acked, failed, forgotten }
    private enum Forgotten { case forgottenActive, forgottenEnded }

    private func due(_ meta: SessionMeta, _ state: SyncState, at now: Date, force: Bool) -> Bool {
        guard force || (state.retry_at ?? .distantPast) <= now else { return false }
        switch state.stage {
        case .doneSignaled: return false
        case .closeAcked, .verifying: return true
        case .streaming:
            if meta.state != state.meta_state || meta.state != .active { return true }
            return state.pushed_at.map { now.timeIntervalSince($0) >= interval } ?? true
        }
    }

    private func sync(_ directory: URL, sid: String, at now: Date, force: Bool, mini: Mini?) async throws -> Forgotten? {
        var state = try syncState(directory)
        try reportPending(directory, sid: sid, state: &state)
        guard state.stage != .doneSignaled else { markIfFinished(sid, state, directory); return nil }
        guard let metaBytes = try? Data(contentsOf: directory.appendingPathComponent(SyncFile.meta.rawValue)),
              let meta = try? JSON.decoder().decode(SessionMeta.self, from: metaBytes) else { return nil }
        guard due(meta, state, at: now, force: force) else { return nil }
        var delivery = Delivery.acked
        if mini == nil {
            guard meta.state != .active else { return nil }
            state.stage = .closeAcked
        } else if let mini, state.stage == .streaming || state.stage == .verifying {
            delivery = try await push(directory, sid: sid, meta: meta, metaBytes: metaBytes, state: &state, mini: mini)
            if delivery == .acked {
                state.pushed_at = now
                if meta.state != .active { state.stage = .closeAcked }
                else if state.stage == .verifying { state.stage = .streaming }
            }
        }
        if delivery == .acked && state.stage == .closeAcked {
            if let mini {
                let transcript = state.offsets[.transcript] ?? 0
                let output = try? await runner.run(remote(mini, "live-meeting-done", [sid, String(transcript)], timeout: 60))
                try Task.checkCancellation()
                switch output?.status {
                case 0: state.stage = .doneSignaled
                case 3: state.stage = .verifying; delivery = .failed
                case 4: delivery = .forgotten
                default: delivery = .failed
                }
            } else if let done {
                let output = try? await runner.run(done.process(session: directory, timeout: Self.handoffTimeout))
                try Task.checkCancellation()
                if let output, output.status == 0 {
                    guard !blocked.contains(sid), try tombstones()[sid] == nil else { return nil }
                    state.stage = .doneSignaled
                    state.pending_handoff = Self.handoffLine(output.stdout, in: directory)
                    try PrivateFiles.write(state, to: directory.appendingPathComponent("sync.json"))
                    try reportPending(directory, sid: sid, state: &state)
                } else {
                    delivery = .failed
                    FileHandle.standardError.write(Data("handoff_failed sid=\(sid) status=\(output.map { String($0.status) } ?? "none")\n".utf8))
                }
            } else { return nil }
        }
        guard !blocked.contains(sid), try tombstones()[sid] == nil else { return nil }
        switch delivery {
        case .acked:
            state.failures = 0; state.retry_at = nil
        case .failed:
            state.failures += 1; state.retry_at = now.addingTimeInterval(Self.backoff(failures: state.failures))
        case .forgotten:
            try recordForget(sid, at: now)
            if meta.state == .active { return .forgottenActive }
            try deleteSession(sid)
            return .forgottenEnded
        }
        try PrivateFiles.write(state, to: directory.appendingPathComponent("sync.json"))
        markIfFinished(sid, state, directory)
        return nil
    }

    /// The handoff script writes `handoff.json` before it prints, so a crash in between leaves the marker and no line,
    /// and a rerun prints nothing. The command only runs for a session not yet handed off, so a marker with no line
    /// means the path never went out.
    static func handoffLine(_ stdout: Data, in directory: URL) -> String {
        let line = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty, FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.json").path) else { return line }
        return directory.appendingPathComponent("transcript.jsonl").path
    }

    private func reportPending(_ directory: URL, sid: String, state: inout SyncState) throws {
        guard let output = state.pending_handoff else { return }
        onHandoff?(Handoff(sid: sid, output: output))
        state.pending_handoff = nil
        try PrivateFiles.write(state, to: directory.appendingPathComponent("sync.json"))
    }

    private func push(_ directory: URL, sid: String, meta: SessionMeta, metaBytes: Data, state: inout SyncState, mini: Mini) async throws -> Delivery {
        let verifying = state.stage == .verifying
        for file in SyncFile.allCases {
            let bytes: Data
            if file == .meta { bytes = metaBytes }
            else {
                let url = directory.appendingPathComponent(file.rawValue)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                bytes = try Data(contentsOf: url)
            }
            if file.appendOnly {
                let complete = bytes.lastIndex(of: 10).map { bytes.distance(from: bytes.startIndex, to: $0) + 1 } ?? 0
                for _ in 0..<3 {
                    let offset = min(state.offsets[file] ?? 0, complete)
                    guard offset < complete || verifying || state.offsets[file] == nil else { break }
                    let (status, size) = try await receive(sid, file, offset: offset, bytes: bytes.subdata(in: offset..<complete), mini: mini)
                    switch status {
                    case 0:
                        guard let size else { return .failed }
                        state.offsets[file] = min(size, complete)
                    case 3: state.offsets[file] = min(size ?? 0, complete); continue
                    case 4: return .forgotten
                    default: return .failed
                    }
                    if state.offsets[file] == complete { break }
                }
                guard state.offsets[file] ?? 0 == complete else { return .failed }
            } else {
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard state.digests[file] != digest || verifying else { continue }
                let (status, _) = try await receive(sid, file, offset: 0, bytes: bytes, mini: mini)
                switch status {
                case 0: state.digests[file] = digest
                case 4: return .forgotten
                default: return .failed
                }
                if file == .meta { state.meta_version = meta.version; state.meta_state = meta.state }
            }
        }
        return .acked
    }

    private func receive(_ sid: String, _ file: SyncFile, offset: Int, bytes: Data, mini: Mini) async throws -> (Int32, Int?) {
        try Task.checkCancellation()
        let command = remote(mini, "live-meeting-receive", [sid, file.rawValue, String(offset)], input: bytes, timeout: Self.timeout(bytes: bytes.count))
        let output = try? await runner.run(command)
        try Task.checkCancellation()
        guard let output else { return (-1, nil) }
        return (output.status, (try? JSONDecoder().decode(SizeReply.self, from: output.stdout))?.size)
    }

    private struct StatusReply: Decodable {
        var schedule: Schedule?
        var status: PanelFeed?
        enum CodingKeys: String, CodingKey { case schedule, status }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schedule = try? c.decodeIfPresent(Schedule.self, forKey: .schedule)
            status = try? c.decodeIfPresent(PanelFeed.self, forKey: .status)
        }
    }

    private func syncStatus(_ heartbeat: Heartbeat, at now: Date, mini: Mini) async -> FeedReceipt? {
        guard let body = try? JSON.encoder().encode(heartbeat),
              let output = try? await runner.run(remote(mini, "live-meeting-sync-status", [], input: body, timeout: 20)),
              output.status == 0,
              let reply = try? JSON.decoder().decode(StatusReply.self, from: output.stdout) else { return nil }
        if let schedule = reply.schedule, let encoded = try? JSON.encoder().encode(schedule) {
            let url = paths.root.appendingPathComponent("schedule.json")
            if (try? Data(contentsOf: url)) != encoded { try? PrivateFiles.write(encoded, to: url) }
        }
        return FeedReceipt(at: now, feed: reply.status)
    }
}

public enum Retention {
    /// The mini's retention when its schedule names one, else this Mac's `retention_days` setting.
    public static func days(_ setting: Int, schedule: Schedule?) -> Int {
        max(0, schedule?.retention_days ?? setting)
    }
    public static func expired(in paths: SessionPaths, days: Int, now: Date) throws -> [String] {
        guard FileManager.default.fileExists(atPath: paths.sessions.path) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return try FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil).compactMap { directory in
            guard SessionPaths.validID(directory.lastPathComponent),
                  let meta = try? JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json")) else { return nil }
            return meta.state != .active && (meta.ended_at ?? meta.started_at) < cutoff ? meta.sid : nil
        }
    }
}
