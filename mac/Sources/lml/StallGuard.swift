import Foundation
import LMLCore

/// Watches the recorder loop from its own thread. A loop stuck past the watch's limit gets a stack sample written
/// to `directory`, then the process exits so launchd starts a fresh recorder that can pick the call back up.
enum StallGuard {
    static let exitCode: Int32 = 70
    static func start(_ watch: LoopWatch, directory: URL) {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 5)
                guard let stall = watch.stall() else { continue }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let file = directory.appendingPathComponent("stall-\(stamp).txt")
                FileHandle.standardError.write(Data("loop_stalled step=\(stall.step) seconds=\(Int(stall.seconds)) sample=\(file.path)\n".utf8))
                sample(into: file)
                _exit(exitCode)
            }
        }
        thread.name = "lml.stall-guard"
        thread.start()
    }
    private static func sample(into file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "3", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate() }
    }
}
