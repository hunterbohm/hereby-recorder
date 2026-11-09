import Foundation
import Darwin

public struct ControlCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable, CaseIterable { case start, stop, pause, resume, forget, mark, ping }
    public static let noteLimit = 1000
    public var action: Action
    public var sid: String?
    public var note: String?
    public var kind: CaptureKind?
    public init(action: Action, sid: String? = nil, note: String? = nil, kind: CaptureKind? = nil) {
        self.action = action; self.sid = sid; self.note = note.map { String($0.prefix(Self.noteLimit)) }; self.kind = kind
    }
}

extension ControlCommand {
    /// The answer to `ping`: the recorder's own process id, so a caller can tell which process replied.
    public static func pingReply(pid: Int32) -> String { "pong \(pid)" }
    public static func pingPID(_ reply: String) -> Int32? {
        let words = reply.split(separator: " ")
        guard words.count == 2, words[0] == "pong", let pid = Int32(words[1]), pid > 1 else { return nil }
        return pid
    }
}

public struct PauseState: Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case pause, forget
        /// pause.json is only read for its existence, so a reason this build does not know (a newer or hand-edited file)
        /// still means "paused" and decodes as the generic `pause` rather than failing the read.
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pause
        }
    }
    public var reason: Reason
    public var set_at: Date
    public var until = "meeting_end"
    public init(reason: Reason, at: Date) { self.reason = reason; set_at = at }
}

public struct PauseStore: Sendable {
    private let url: URL
    private var lostAt: Date?
    public init(root: URL) { url = root.appendingPathComponent("pause.json") }
    public mutating func migrateLegacy(at: Date) throws {
        let legacy = url.deletingLastPathComponent().appendingPathComponent("control.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        struct Legacy: Decodable { var paused: Bool }
        if try JSON.read(Legacy.self, from: legacy).paused && !isPaused { try set(reason: .pause, at: at) }
        try FileManager.default.removeItem(at: legacy)
    }
    public var isPaused: Bool { FileManager.default.fileExists(atPath: url.path) }
    public mutating func set(reason: PauseState.Reason, at: Date) throws {
        try PrivateFiles.write(PauseState(reason: reason, at: at), to: url); lostAt = nil
    }
    public mutating func resume() throws {
        if isPaused { try FileManager.default.removeItem(at: url) }
        lostAt = nil
    }
    @discardableResult public mutating func observe(meetingSignal: Bool, at: Date) throws -> Bool {
        guard isPaused else { lostAt = nil; return false }
        if meetingSignal { lostAt = nil; return false }
        if lostAt == nil { lostAt = at }
        guard at.timeIntervalSince(lostAt!) >= 120 else { return false }
        try resume(); return true
    }
}

public enum ActiveForget {
    @MainActor public static func perform(
        cancelOutbox: () async throws -> Void,
        stopSources: () async throws -> Void,
        cancelAnalyzers: () async throws -> Void,
        closeWriter: () async throws -> Void,
        deleteSession: () async throws -> Void,
        writeTombstone: () async throws -> Void,
        reply: () async throws -> Void
    ) async throws {
        try await cancelOutbox()
        try await stopSources()
        try await cancelAnalyzers()
        try await closeWriter()
        try await deleteSession()
        try await writeTombstone()
        try await reply()
    }
}

public struct AgentIdentity: Codable, Sendable {
    public let pid: Int32
    public let pgid: Int32
    public init(pid: Int32, pgid: Int32) { self.pid = pid; self.pgid = pgid }
}
public struct SurvivingProcesses: Error, Sendable {
    public let pids: [Int32]
}
public enum UnresponsiveForget {
    @MainActor public static func perform(
        launchKill: () async throws -> Bool,
        readIdentity: () throws -> AgentIdentity,
        killGroup: (Int32) async throws -> Void,
        survivingPIDs: (AgentIdentity) async throws -> [Int32],
        wait: () async throws -> Void,
        deleteSession: () async throws -> Void
    ) async throws {
        // The process group is also killed after a launchd kill, to stop rsync.
        _ = (try? await launchKill()) ?? false
        let identity = try readIdentity()
        guard identity.pid > 1, identity.pgid > 1 else { throw POSIXError(.EINVAL) }
        try? await killGroup(identity.pgid)
        var remaining = try await survivingPIDs(identity)
        for _ in 0..<100 where !remaining.isEmpty {
            try await wait()
            remaining = try await survivingPIDs(identity)
        }
        guard remaining.isEmpty else { throw SurvivingProcesses(pids: remaining) }
        try await deleteSession()
    }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [UInt8(0)]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
}
private func withSocketAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
private func socketFD() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return fd
}
private func sendLine(_ data: Data, fd: Int32) throws {
    try (data + Data("\n".utf8)).withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            sent += count
        }
    }
}
private func readLine(fd: Int32, deadline: Date) throws -> Data {
    var data = Data()
    while Date() < deadline {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(100, deadline.timeIntervalSinceNow * 1000)))
        let ready = poll(&pollFD, 1, milliseconds)
        if ready == 0 { continue }
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw POSIXError(.EIO) }
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        if byte == 10 { return data }
        data.append(byte)
        guard data.count <= 16384 else { throw POSIXError(.EMSGSIZE) }
    }
    throw POSIXError(.ETIMEDOUT)
}

public final class ControlConnection: Sendable {
    public let command: ControlCommand
    private let fd: Int32
    fileprivate init(command: ControlCommand, fd: Int32) { self.command = command; self.fd = fd }
    deinit { Darwin.close(fd) }
    public func reply(_ message: String) throws { try sendLine(Data(message.utf8), fd: fd) }
}

public final class ControlServer: Sendable {
    private let fd: Int32
    private let url: URL
    public init(root: URL) throws {
        url = root.appendingPathComponent("control.sock")
        var address = try socketAddress(url.path)
        fd = try socketFD()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard withSocketAddress(&address, { bind(fd, $0, $1) }) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard chmod(url.path, 0o600) == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
    }
    deinit { Darwin.close(fd); try? FileManager.default.removeItem(at: url) }
    /// The next well-formed command, or nil when none is waiting. A connection that sends an unknown action, bad JSON, or
    /// nothing is answered `bad_request` where possible and dropped. It never throws for that, because the recorder treats
    /// a thrown error here as a reason to close the capture and exit.
    public func acceptCommand() async throws -> ControlConnection? {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
            if client < 0 && (errno == EINTR || errno == ECONNABORTED) { continue }
            guard client >= 0 else { throw POSIXError(.EIO) }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let connection: ControlConnection? = await Task.detached {
                guard let data = try? readLine(fd: client, deadline: Date().addingTimeInterval(1)) else { Darwin.close(client); return nil }
                guard let command = try? JSON.decoder().decode(ControlCommand.self, from: data) else {
                    try? sendLine(Data("bad_request".utf8), fd: client); Darwin.close(client); return nil
                }
                return ControlConnection(command: command, fd: client)
            }.value
            if let connection { return connection }
        }
    }
}
public enum ControlClient {
    /// Asks the running recorder for its process id. Changes nothing, so it is safe to send at any time.
    public static func ping(root: URL, timeout: TimeInterval = 3) async throws -> Int32 {
        let reply = try await request(ControlCommand(action: .ping), root: root, timeout: timeout)
        guard let pid = ControlCommand.pingPID(reply) else { throw POSIXError(.EPROTO) }
        return pid
    }
    public static func request(_ command: ControlCommand, root: URL, timeout: TimeInterval = 10) async throws -> String {
        try await Task.detached {
            let fd = try socketFD(); defer { Darwin.close(fd) }
            var address = try socketAddress(root.appendingPathComponent("control.sock").path)
            guard withSocketAddress(&address, { connect(fd, $0, $1) }) == 0 else { throw POSIXError(.ECONNREFUSED) }
            let deadline = Date().addingTimeInterval(timeout)
            try sendLine(JSON.encoder().encode(command), fd: fd)
            return String(decoding: try readLine(fd: fd, deadline: deadline), as: UTF8.self)
        }.value
    }
}
