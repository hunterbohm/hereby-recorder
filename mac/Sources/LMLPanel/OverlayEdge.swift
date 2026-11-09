import AppKit
import LMLCore

/// What the overlay holds of the screen, as `overlay_command` hears it: the style on screen (or off), the room the
/// side strip takes from the right edge, and the display it is on.
struct OverlayEdge: Equatable {
    var style: OverlayStyle?
    var width: Int
    var display: String?

    static let off = OverlayEdge(style: nil, width: 0, display: nil)

    /// The strip's column plus its gap from the edge; card and pill float over windows and take no room.
    init(style: OverlayStyle?, display: String?) {
        self.init(style: style, width: style == .strip ? Int(OverlayRules.stripWidth + OverlayRules.stripMargin) : 0, display: display)
    }
    init(style: OverlayStyle?, width: Int, display: String?) { self.style = style; self.width = width; self.display = display }

    var environment: [String: String] {
        var env = ["HEREBY_OVERLAY": style?.rawValue ?? "off", "HEREBY_OVERLAY_WIDTH": String(width)]
        if let display { env["HEREBY_OVERLAY_DISPLAY"] = display }
        return env
    }

    /// The edges to announce to go from `old` to `self`. Going off frees the display the overlay was on, and a strip
    /// that moves to another display first frees the old one.
    func changes(from old: OverlayEdge) -> [OverlayEdge] {
        var next = self
        if next.style == nil, next.display == nil { next.display = old.display }
        guard next != old else { return [] }
        if old.width > 0, old.display != next.display { return [OverlayEdge(style: nil, width: 0, display: old.display), next] }
        return [next]
    }

    /// The display's UUID, which window managers match per-screen settings by.
    @MainActor static func uuid(of screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Runs `overlay_command` once per change, in order and off the main thread, so a slow window manager never stalls the overlay.
final class OverlayCommand: @unchecked Sendable {
    private let command: String
    private let queue = DispatchQueue(label: "hereby.overlay-command")
    private let timeout: TimeInterval
    private var sent = OverlayEdge.off

    init(_ command: String, timeout: TimeInterval = 5) { self.command = command; self.timeout = timeout }

    /// Called on the main actor only; `sent` is the last edge handed to the queue.
    func announce(_ edge: OverlayEdge, force: Bool = false) {
        let edges = force ? [edge] : edge.changes(from: sent)
        if let last = edges.last { sent = last }
        for edge in edges { queue.async { [self] in run(edge) } }
    }

    /// Frees the screen before the recorder quits, waiting briefly.
    func finish() {
        let edges = OverlayEdge.off.changes(from: sent)
        if let last = edges.last { sent = last }
        queue.sync { for edge in edges { run(edge) } }
    }

    private func run(_ edge: OverlayEdge) {
        let env = ProcessInfo.processInfo.environment.merging(edge.environment) { $1 }
        Self.run(command, environment: env, timeout: timeout)
    }

    /// Runs `command` under `/bin/sh` in its own process group and waits for it. On timeout the whole group gets
    /// SIGTERM, then SIGKILL a moment later, and the shell is reaped before the next change runs, so nothing the
    /// command started can finish after a later change and undo it.
    static func run(_ command: String, environment: [String: String], timeout: TimeInterval, grace: TimeInterval = 0.5) {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Like Foundation's Process: default signal handling and an empty mask, whatever the recorder itself ignores.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var files = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }

        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { (arg: String) in strdup(arg) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &files, &attr, argv, envp) == 0 else { return }

        if exited(pid, within: timeout) { return }
        kill(-pid, SIGTERM)
        if !exited(pid, within: grace) { kill(-pid, SIGKILL); _ = exited(pid, within: .infinity) }
        kill(-pid, SIGKILL)  // children that ignored SIGTERM after the shell itself quit
    }

    /// Reaps `pid` if it exits before `seconds` pass.
    private static func exited(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno != EINTR) { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }
}
