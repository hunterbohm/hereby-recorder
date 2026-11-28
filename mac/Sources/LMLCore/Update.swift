import Foundation
import Darwin

/// A release tag, `v<major>.<minor>.<patch>`. A pre-release or build tag (`v2.14.0-rc.1`) is not a release.
public struct ReleaseVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    public init?(tag: String) {
        let text = tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ ("0"..."9").contains($0) }),
                  part == "0" || !part.hasPrefix("0"), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var tag: String { "v\(major).\(minor).\(patch)" }
    public var description: String { tag }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ReleaseVersion(tag: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a release tag"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tag)
    }
}

public enum ReleaseTags {
    /// The releases in `git ls-remote --tags` output. A peeled line (`refs/tags/v2.13.0^{}`) names the same tag.
    public static func versions(lsRemote output: String) -> Set<ReleaseVersion> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line -> ReleaseVersion? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { return nil }
            var name = fields[1].dropFirst("refs/tags/".count)
            if name.hasSuffix("^{}") { name = name.dropLast(3) }
            return ReleaseVersion(tag: String(name))
        })
    }

    /// The newest release above `current`, if there is one.
    public static func newer(than current: ReleaseVersion, lsRemote output: String) -> ReleaseVersion? {
        versions(lsRemote: output).filter { $0 > current }.max()
    }
}

/// The clone the app was built from and the release it was built at. `build-app.sh` records the clone's path in the
/// bundle's Info.plist under `infoKey`.
public struct UpdateCheckout: Sendable, Equatable {
    public static let infoKey = "HerebyCheckout"
    public var path: URL
    public var current: ReleaseVersion
    public init(path: URL, current: ReleaseVersion) { self.path = path; self.current = current }

    /// Nil when the bundle has no recorded clone, or was built at a tag that is not a release (like `local-build`),
    /// so there is nothing to compare against.
    public init?(info: [String: Any]?) {
        guard let path = info?[Self.infoKey] as? String, path.hasPrefix("/"),
              let version = (info?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init(tag:)) else { return nil }
        self.init(path: URL(fileURLWithPath: path), current: version)
    }
}

/// Why the Update button did not start an update.
public enum UpdateRefusal: Error, Equatable, Sendable {
    /// A call is recording, paused, held, or about to start; building restarts the recorder.
    case inCall
    /// The clone has uncommitted changes to tracked files, which a checkout could lose or refuse.
    case uncommitted
    /// The clone is not exactly on a tag, so someone is working in it; it is left alone.
    case notOnTag
    /// The clone the app was built from is gone or is no longer a git clone.
    case noCheckout
    /// An update job is still running.
    case running
}

public enum UpdateRules {
    /// `changes` is `git status --porcelain --untracked-files=no`; `onTag` is whether `git describe --tags
    /// --exact-match HEAD` succeeded. First match wins.
    public static func refusal(inCall: Bool, changes: String, onTag: Bool) -> UpdateRefusal? {
        if inCall { return .inCall }
        if !changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .uncommitted }
        if !onTag { return .notOnTag }
        return nil
    }
}

public enum UpdateProgress: Equatable, Sendable { case running, succeeded, failed }

/// What the panel needs to offer an update. `Updater` is the real one.
public protocol UpdateActions: Sendable {
    /// Where the update writes its log, shown when it fails.
    var logPath: String { get }
    /// The newest release above the running app's, or nil.
    func newerRelease(now: Date) async -> ReleaseVersion?
    /// Starts the update in the background, or throws an `UpdateRefusal` (or another error when it could not start).
    func startUpdate(to version: ReleaseVersion, inCall: Bool) async throws
    func updateProgress() async -> UpdateProgress
}

/// The commands an update runs, built here so tests can check them.
public enum UpdateCommands {
    public static let label = "sh.hereby.recorder.update"
    static let git = "/usr/bin/git"
    static let launchctl = "/bin/launchctl"
    /// git never stops to ask for a password: a remote that needs one fails, and the check tries again tomorrow.
    static let quietGit = ["/usr/bin/env", "GIT_TERMINAL_PROMPT=0", git]

    public static func listTags(_ checkout: URL) -> ProcessCommand {
        ProcessCommand(quietGit[0], Array(quietGit.dropFirst()) + ["-C", checkout.path, "ls-remote", "--tags", "origin"], timeout: 60)
    }

    public static func changes(_ checkout: URL) -> ProcessCommand {
        ProcessCommand(git, ["-C", checkout.path, "status", "--porcelain", "--untracked-files=no"], timeout: 30)
    }

    public static func exactTag(_ checkout: URL) -> ProcessCommand {
        ProcessCommand(git, ["-C", checkout.path, "describe", "--tags", "--exact-match", "HEAD"], timeout: 30)
    }

    public static func jobState(uid: uid_t) -> ProcessCommand {
        ProcessCommand(launchctl, ["print", "gui/\(uid)/\(label)"], timeout: 10)
    }

    public static func bootout(uid: uid_t) -> ProcessCommand {
        ProcessCommand(launchctl, ["bootout", "gui/\(uid)/\(label)"], timeout: 30)
    }

    public static func bootstrap(uid: uid_t, plist: URL) -> ProcessCommand {
        ProcessCommand(launchctl, ["bootstrap", "gui/\(uid)", plist.path], timeout: 30)
    }

    /// Whether `launchctl print` output shows the job with a running process.
    public static func isRunning(_ printed: String) -> Bool {
        printed.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
    }

    /// Run by bash as `bash -c script hereby-update <clone> <tag> <status file>`. It lives in the job, not in the clone,
    /// because the checkout rewrites the clone's scripts while they run. build-app.sh refuses during a call and
    /// restarts the recorder; the exit code lands in the status file for the panel.
    public static let script = """
        clone="$1" tag="$2" status_file="$3"
        finish() { code=$?; printf '%s\\n' "$code" > "$status_file"; printf 'Finished %s with exit %s\\n' "$(date)" "$code"; }
        trap finish EXIT
        set -euo pipefail
        printf 'Updating %s to %s, %s\\n' "$clone" "$tag" "$(date)"
        cd "$clone"
        git fetch --tags origin
        git checkout --quiet "refs/tags/$tag"
        mac/scripts/build-app.sh
        """

    /// A one-shot LaunchAgent, so the update outlives the recorder that build-app.sh stops: a child of the recorder's
    /// own job would be killed with it. It is not in ~/Library/LaunchAgents, so it never runs again at login.
    public static func job(checkout: URL, version: ReleaseVersion, log: URL, status: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/bash", "-c", script, "hereby-update", checkout.path, version.tag, status.path],
            "RunAtLoad": true,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "GIT_TERMINAL_PROMPT": "0"],
            "Umask": 63
        ]
    }
}

/// The one-shot launchd job that installs an update, shared by both updaters. Its plist, log and status file live in
/// `folder`; the job writes its exit code to the status file for the panel.
struct UpdateJob: Sendable {
    let folder: URL
    let runner: any ProcessRunner
    let uid: uid_t

    var log: URL { folder.appendingPathComponent("update.log") }
    var status: URL { folder.appendingPathComponent("status") }
    var plist: URL { folder.appendingPathComponent("\(UpdateCommands.label).plist") }

    func isRunning() async throws -> Bool {
        let state = try await runner.run(UpdateCommands.jobState(uid: uid))
        return state.status == 0 && UpdateCommands.isRunning(String(decoding: state.stdout, as: UTF8.self))
    }

    /// Makes the folder and clears the last run's status and log.
    func prepare() throws {
        try PrivateFiles.directory(folder)
        try? FileManager.default.removeItem(at: status)
        try? FileManager.default.removeItem(at: log)
    }

    func note(_ line: String) {
        let previous = FileManager.default.contents(atPath: log.path) ?? Data()
        try? PrivateFiles.write(previous + Data((line.hasSuffix("\n") ? line : line + "\n").utf8), to: log)
    }

    /// Writes the job's plist and loads it. `job` is the plist's XML.
    func launch(_ job: Data) async throws {
        try PrivateFiles.write(job, to: plist)
        // A finished job stays loaded until it is booted out; booting out one that is not loaded fails harmlessly.
        _ = try? await runner.run(UpdateCommands.bootout(uid: uid))
        var started = try await runner.run(UpdateCommands.bootstrap(uid: uid, plist: plist))
        if started.status != 0 {
            // launchd can still be tearing down the old job just after bootout.
            try await Task.sleep(for: .seconds(1))
            started = try await runner.run(UpdateCommands.bootstrap(uid: uid, plist: plist))
        }
        guard started.status == 0 else {
            note("Couldn't start the update: launchctl bootstrap exited \(started.status).")
            throw UpdateFailure(status: started.status)
        }
    }

    /// The job's exit code once it wrote one; a job that stopped without writing one failed.
    func progress() async -> UpdateProgress {
        if let finished = readStatus() { return finished }
        if (try? await isRunning()) == true { return .running }
        return readStatus() ?? .failed
    }

    private func readStatus() -> UpdateProgress? {
        guard let data = FileManager.default.contents(atPath: status.path) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0" ? .succeeded : .failed
    }
}

/// Finds newer releases on the clone's remote and runs the update job. Its files live in `<state root>/update`.
public actor Updater: UpdateActions {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    private struct Check: Codable { var checked_at: Date; var newest: ReleaseVersion? }

    public nonisolated let logPath: String
    private let checkout: UpdateCheckout
    private let folder: URL
    private let runner: any ProcessRunner
    private let job: UpdateJob

    public init(checkout: UpdateCheckout, root: URL, runner: any ProcessRunner = LocalProcessRunner(), uid: uid_t = getuid()) {
        self.checkout = checkout
        self.runner = runner
        folder = root.appendingPathComponent("update")
        job = UpdateJob(folder: folder, runner: runner, uid: uid)
        logPath = job.log.path
    }

    private var checkURL: URL { folder.appendingPathComponent("check.json") }
    private var cloneExists: Bool { FileManager.default.fileExists(atPath: checkout.path.appendingPathComponent(".git").path) }

    /// Asks the remote at most once a day, across restarts; between asks the last answer stands. A failed ask counts,
    /// so a remote that can't be reached is not asked again until tomorrow.
    public func newerRelease(now: Date) async -> ReleaseVersion? {
        if let last = try? JSON.read(Check.self, from: checkURL), last.checked_at <= now,
           now.timeIntervalSince(last.checked_at) < Self.checkInterval {
            return last.newest.flatMap { $0 > checkout.current ? $0 : nil }
        }
        guard cloneExists else { return nil }
        let output = try? await runner.run(UpdateCommands.listTags(checkout.path))
        let newest = output.flatMap { $0.status == 0 ? ReleaseTags.versions(lsRemote: String(decoding: $0.stdout, as: UTF8.self)).max() : nil }
        try? PrivateFiles.directory(folder)
        try? PrivateFiles.write(Check(checked_at: now, newest: newest), to: checkURL)
        return newest.flatMap { $0 > checkout.current ? $0 : nil }
    }

    public func startUpdate(to version: ReleaseVersion, inCall: Bool) async throws {
        if inCall { throw UpdateRefusal.inCall }
        guard cloneExists else { throw UpdateRefusal.noCheckout }
        let changes = try await runner.run(UpdateCommands.changes(checkout.path))
        guard changes.status == 0 else { throw UpdateRefusal.noCheckout }
        let onTag = try await runner.run(UpdateCommands.exactTag(checkout.path)).status == 0
        if let refusal = UpdateRules.refusal(inCall: false, changes: String(decoding: changes.stdout, as: UTF8.self), onTag: onTag) {
            throw refusal
        }
        if try await job.isRunning() { throw UpdateRefusal.running }
        try job.prepare()
        let plist = UpdateCommands.job(checkout: checkout.path, version: version, log: job.log, status: job.status)
        try await job.launch(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }

    public func updateProgress() async -> UpdateProgress { await job.progress() }
}

public struct UpdateFailure: Error, Equatable { public var status: Int32 }
