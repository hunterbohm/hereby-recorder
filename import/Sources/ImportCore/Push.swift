import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public init(status: Int32, stdout: Data = Data()) { self.status = status; self.stdout = stdout }
}

public protocol CommandRunner: Sendable {
    func run(_ remote: [String], stdin: Data) async throws -> CommandResult
}

public enum PushError: Error, Equatable, CustomStringConvertible {
    case receive(file: String, status: Int32)
    case sizeMismatch(file: String, sent: Int, acknowledged: Int?)
    case done(status: Int32)
    case invalidSID
    case timeout(seconds: Double)
    public var description: String {
        switch self {
        case .invalidSID: return "invalid session id"
        case .timeout(let seconds): return "ssh gave no answer within \(Int(seconds)) s"
        case .receive(let file, let status): return "live-meeting-receive \(file) exited \(status)"
        case .sizeMismatch(let file, let sent, let acknowledged):
            return "live-meeting-receive \(file) acknowledged \(acknowledged.map(String.init) ?? "no size") of \(sent) bytes"
        case .done(let status): return "live-meeting-done exited \(status)"
        }
    }
}

/// Sends a finished session to the mini over contracts C2 (receive at offset 0, so resends converge) and C3 (done signal).
public struct Pusher: Sendable {
    public enum Delivery: Sendable, Equatable { case received, forgotten }
    public enum Signal: Sendable, Equatable { case done, stale, forgotten }

    public let runner: any CommandRunner
    public init(runner: any CommandRunner) { self.runner = runner }

    public func send(sid: String, directory: URL) async throws -> Delivery {
        guard SessionBuilder.validID(sid) else { throw PushError.invalidSID }
        for file in ["transcript.jsonl", "meta.json"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let result = try await runner.run(["live-meeting-receive", sid, file, "0"], stdin: data)
            switch result.status {
            case 0:
                let size = (try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])?["size"] as? Int
                guard size == data.count else { throw PushError.sizeMismatch(file: file, sent: data.count, acknowledged: size) }
            case 4:
                return .forgotten
            default:
                throw PushError.receive(file: file, status: result.status)
            }
        }
        return .received
    }

    public func signalDone(sid: String, transcriptBytes: Int) async throws -> Signal {
        guard SessionBuilder.validID(sid) else { throw PushError.invalidSID }
        let result = try await runner.run(["live-meeting-done", sid, String(transcriptBytes)], stdin: Data())
        switch result.status {
        case 0: return .done
        case 3: return .stale
        case 4: return .forgotten
        default: throw PushError.done(status: result.status)
        }
    }
}

public struct SSHRunner: CommandRunner {
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                                    "-o", "ControlMaster=auto", "-o", "ControlPersist=120"]
    public let controlPath: URL
    public let host: String
    public let executable: URL
    public let timeout: Double
    public init(controlPath: URL, host: String, executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: Double = 120) {
        self.controlPath = controlPath; self.host = host; self.executable = executable; self.timeout = timeout
    }

    /// Remote words are a validated sid, fixed file names, and integers, so joining them needs no shell quoting.
    public func arguments(_ remote: [String]) -> [String] {
        Self.sshOptions + ["-o", "ControlPath=\"\(controlPath.path)\"", host, remote.joined(separator: " ")]
    }

    public func run(_ remote: [String], stdin: Data) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(remote)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let finished = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished.continuation.yield($0.terminationStatus); finished.continuation.finish() }
        try process.run()
        let pid = process.processIdentifier, limit = timeout
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(limit))
            kill(pid, SIGKILL)
        }
        let writer = Task.detached {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let stdout = await reader.value
        await writer.value
        var status: Int32 = -1
        for await code in finished.stream { status = code }
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal && status == SIGKILL { throw PushError.timeout(seconds: timeout) }
        return CommandResult(status: status, stdout: stdout)
    }
}
