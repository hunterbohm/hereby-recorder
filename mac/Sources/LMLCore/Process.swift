import Foundation
import Darwin
import Synchronization

public struct ProcessCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var input: Data?
    public var timeout: TimeInterval?
    public init(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval? = nil) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.timeout = timeout
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public init(status: Int32, stdout: Data = Data()) { self.status = status; self.stdout = stdout }
}

public protocol ProcessRunner: Sendable {
    func run(_ command: ProcessCommand) async throws -> ProcessOutput
    /// Like `run`, and hands each piece of stdout to `onOutput` as it arrives.
    func stream(_ command: ProcessCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> ProcessOutput
    func cancel() async
}

public extension ProcessRunner {
    func stream(_ command: ProcessCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> ProcessOutput {
        let output = try await run(command)
        if !output.stdout.isEmpty { onOutput(output.stdout) }
        return output
    }
}

private final class Exited: Sendable {
    let flag = Atomic<Bool>(false)
}

private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
    }
}

public actor LocalProcessRunner: ProcessRunner {
    public static let outputLimit = 8 << 20
    private var pid: pid_t?
    private var completion: Task<Int32, Never>?
    public init() {}
    public func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        try await stream(command) { _ in }
    }
    public func stream(_ command: ProcessCommand, onOutput: @escaping @Sendable (Data) -> Void) async throws -> ProcessOutput {
        try Task.checkCancellation()
        var stdin: [Int32] = [-1, -1], stdout: [Int32] = [-1, -1]
        guard pipe(&stdin) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&stdout) == 0 else { close(stdin[0]); close(stdin[1]); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0o600)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let strings = ([command.executable] + command.arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        var arguments = strings + [nil]
        var child: pid_t = 0
        let code = posix_spawn(&child, command.executable, &actions, &attributes, &arguments, environ)
        close(stdin[0]); close(stdout[1])
        guard code == 0 else {
            close(stdin[1]); close(stdout[0])
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        pid = child
        let process = child, writer = stdin[1], reader = stdout[0], input = command.input ?? Data()
        let exited = Exited()
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        let feeding = Task { await blocking { Self.write(input, to: writer, until: exited) } }
        let collecting = Task { await blocking { Self.read(from: reader, until: exited, onOutput: onOutput) } }
        let waiting = Task { await blocking { () -> Int32 in let status = Self.wait(for: process); exited.flag.store(true, ordering: .releasing); return status } }
        completion = waiting
        let deadline = command.timeout.map { seconds in
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { kill(process, SIGKILL) }
            }
        }
        let status = await waiting.value
        deadline?.cancel()
        await feeding.value
        let output = await collecting.value
        pid = nil; completion = nil
        try Task.checkCancellation()
        return ProcessOutput(status: status, stdout: output)
    }
    public func cancel() async {
        if let pid { kill(pid, SIGKILL) }
        _ = await completion?.value
    }
    private static func write(_ data: Data, to fd: Int32, until exited: Exited) {
        defer { close(fd) }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                var request = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&request, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 { if exited.flag.load(ordering: .acquiring) { return } else { continue } }
                let count = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
    private static func read(from fd: Int32, until exited: Exited, onOutput: @Sendable (Data) -> Void) -> Data {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { if exited.flag.load(ordering: .acquiring) { return data } else { continue } }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return data }
            if data.count < outputLimit {
                let piece = Data(buffer[0..<min(count, outputLimit - data.count)])
                data.append(piece)
                onOutput(piece)
            }
        }
    }
    private static func wait(for child: pid_t) -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(child, &status, 0) } while result == -1 && errno == EINTR
        guard result == child else { return -1 }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
