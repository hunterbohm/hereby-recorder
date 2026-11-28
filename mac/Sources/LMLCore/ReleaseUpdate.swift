import Darwin
import Foundation

/// Where a signed app finds its updates. `mac/scripts/release.sh` stamps these keys into the signed app's Info.plist; a
/// source build has none of them, so it keeps the clone updater (`Updater`).
public struct ReleaseChannel: Sendable, Equatable {
    public static let feedKey = "HerebyUpdateFeed"
    public static let publicKeyKey = "HerebyUpdatePublicKey"
    public static let teamKey = "HerebyTeamID"

    public var feed: URL
    public var publicKey: String
    public var teamID: String
    public var bundleID: String
    public var current: ReleaseVersion
    /// The installed app, which the update replaces.
    public var app: URL

    public init(feed: URL, publicKey: String, teamID: String, bundleID: String, current: ReleaseVersion, app: URL) {
        self.feed = feed; self.publicKey = publicKey; self.teamID = teamID
        self.bundleID = bundleID; self.current = current; self.app = app
    }

    /// Nil unless every key is present and well formed, so a half-stamped app offers nothing rather than failing.
    public init?(info: [String: Any]?, app: URL) {
        guard let info, let text = info[Self.feedKey] as? String, let feed = URL(string: text), feed.scheme == "https",
              let key = info[Self.publicKeyKey] as? String, UpdateSigning.isPublicKey(key),
              let team = info[Self.teamKey] as? String, Self.isTeamID(team),
              let bundleID = info["CFBundleIdentifier"] as? String, Self.isBundleID(bundleID),
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init(tag:)) else { return nil }
        self.init(feed: feed, publicKey: key, teamID: team, bundleID: bundleID, current: version, app: app)
    }

    /// What every update's signature must meet: issued through Apple, by this team, for this bundle id. macOS keys the
    /// microphone and screen grants to the same requirement, so an update that meets it keeps them.
    public var requirement: String {
        "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    static func isBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// Fetches the feed and the release zip. `WebDownloads` is the real one.
public protocol UpdateDownloads: Sendable {
    func data(from url: URL) async throws -> Data
    /// Saves the body at `url` to `file`, replacing it.
    func download(from url: URL, to file: URL) async throws
}

public struct WebDownloads: UpdateDownloads {
    public struct BadResponse: Error, CustomStringConvertible {
        public var status: Int
        public var description: String { "the server answered \(status)" }
    }
    static let feedLimit = 1 << 20
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        guard data.count <= Self.feedLimit else { throw BadResponse(status: 413) }
        return data
    }

    public func download(from url: URL, to file: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        try Self.check(response)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BadResponse(status: status) }
    }
}

/// Why a downloaded release was not installed. The update log carries the description.
public enum ReleaseCheckFailure: Error, Equatable, CustomStringConvertible {
    case feed
    case changed(ReleaseVersion?)
    case length(expected: Int, got: Int)
    case signature
    case archive(String)
    case identity(String)
    case version(String)
    case codeSignature(String)
    case gatekeeper(String)

    public var description: String {
        switch self {
        case .feed: "the update feed could not be read"
        case .changed(let version): "the update feed now offers \(version?.tag ?? "nothing"); check again"
        case .length(let expected, let got): "the download is \(got) bytes, the feed says \(expected)"
        case .signature: "the download's update signature does not match the app's update key"
        case .archive(let why): "the download is not a usable app: \(why)"
        case .identity(let id): "the downloaded app is \(id), not this app"
        case .version(let version): "the downloaded app says it is \(version), not the version the feed offers"
        case .codeSignature(let output): "the downloaded app is not signed by this app's developer: \(output)"
        case .gatekeeper(let output): "macOS would not open the downloaded app (not notarized?): \(output)"
        }
    }
}

/// The commands a signed update runs, built here so tests can check them.
public enum ReleaseCommands {
    /// Each runs through bash so its stderr reaches the log; LocalProcessRunner drops stderr.
    static func merged(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessCommand {
        ProcessCommand("/bin/bash", ["-c", "\"$@\" 2>&1", "hereby-check", executable] + arguments, timeout: timeout)
    }

    public static func unzip(_ archive: URL, into folder: URL) -> ProcessCommand {
        merged("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], timeout: 300)
    }

    public static func verifySignature(_ app: URL, requirement: String) -> ProcessCommand {
        merged("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path], timeout: 120)
    }

    public static func assess(_ app: URL) -> ProcessCommand {
        merged("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 120)
    }

    /// Run by bash as `bash -c script hereby-update <new app> <installed app> <status file> <installer>`. The installer is
    /// the new release's own `install-app.sh`, copied out of the checked bundle: it refuses during a call, stops the
    /// recorder through launchd, swaps the bundle, and restarts it. The exit code lands in the status file for the panel.
    public static let script = """
        app="$1" destination="$2" status_file="$3" installer="$4"
        finish() { code=$?; printf '%s\\n' "$code" > "$status_file"; printf 'Finished %s with exit %s\\n' "$(date)" "$code"; }
        trap finish EXIT
        set -euo pipefail
        printf 'Installing %s into %s, %s\\n' "$app" "$destination" "$(date)"
        LML_APP_DESTINATION="$destination" /bin/bash "$installer" "$app"
        """

    /// A one-shot LaunchAgent like the clone updater's, so the install outlives the recorder it stops.
    public static func job(app: URL, destination: URL, installer: URL, log: URL, status: URL) -> [String: Any] {
        [
            "Label": UpdateCommands.label,
            "ProgramArguments": ["/bin/bash", "-c", script, "hereby-update", app.path, destination.path, status.path, installer.path],
            "RunAtLoad": true,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            "Umask": 63
        ]
    }

    /// Where a release bundle carries its installer.
    public static func installer(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Resources/scripts/install-app.sh")
    }
}

/// Offers and installs signed releases from the feed in the app's Info.plist. It checks the feed at most once a day.
/// An update downloads the zip, checks its Ed25519 signature against the app's update key, unpacks it, checks the
/// app inside is this app at the offered version, signed by the same team and accepted by Gatekeeper, and only then
/// starts the install job. Its files live in `<state root>/update`.
public actor ReleaseUpdater: UpdateActions {
    private struct Check: Codable { var checked_at: Date; var feed: ReleaseFeed? }

    public nonisolated let logPath: String
    private let channel: ReleaseChannel
    private let folder: URL
    private let runner: any ProcessRunner
    private let downloads: any UpdateDownloads
    private let system: SystemVersion
    private let job: UpdateJob

    public init(channel: ReleaseChannel, root: URL, runner: any ProcessRunner = LocalProcessRunner(),
                downloads: any UpdateDownloads = WebDownloads(), uid: uid_t = getuid(), system: SystemVersion = .running) {
        self.channel = channel
        self.runner = runner
        self.downloads = downloads
        self.system = system
        folder = root.appendingPathComponent("update")
        job = UpdateJob(folder: folder, runner: runner, uid: uid)
        logPath = job.log.path
    }

    private var checkURL: URL { folder.appendingPathComponent("release-check.json") }
    private var work: URL { folder.appendingPathComponent("download") }

    /// Like the clone updater: one ask a day across restarts, and a failed ask counts.
    public func newerRelease(now: Date) async -> ReleaseVersion? {
        if let last = try? JSON.read(Check.self, from: checkURL), last.checked_at <= now,
           now.timeIntervalSince(last.checked_at) < Updater.checkInterval {
            return last.feed?.offer(current: channel.current, system: system)
        }
        return await fetchFeed(now: now)?.offer(current: channel.current, system: system)
    }

    private func fetchFeed(now: Date) async -> ReleaseFeed? {
        let feed = (try? await downloads.data(from: channel.feed)).flatMap(ReleaseFeed.parse)
        try? PrivateFiles.directory(folder)
        try? PrivateFiles.write(Check(checked_at: now, feed: feed), to: checkURL)
        return feed
    }

    public func startUpdate(to version: ReleaseVersion, inCall: Bool) async throws {
        if inCall { throw UpdateRefusal.inCall }
        if try await job.isRunning() { throw UpdateRefusal.running }
        try job.prepare()
        do {
            var feed = (try? JSON.read(Check.self, from: checkURL))?.feed
            if feed?.version != version { feed = await fetchFeed(now: Date()) }
            guard let feed else { throw ReleaseCheckFailure.feed }
            guard feed.offer(current: channel.current, system: system) == version else { throw ReleaseCheckFailure.changed(feed.version) }
            let app = try await fetchAndCheck(feed)
            let installer = folder.appendingPathComponent("install-app.sh")
            try? FileManager.default.removeItem(at: installer)
            try FileManager.default.copyItem(at: ReleaseCommands.installer(in: app), to: installer)
            let plist = ReleaseCommands.job(app: app, destination: channel.app, installer: installer, log: job.log, status: job.status)
            try await job.launch(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            job.note("Couldn't update to \(version.tag): \(error)")
            throw error
        }
    }

    public func updateProgress() async -> UpdateProgress { await job.progress() }

    /// Downloads and checks the release; returns the unpacked app, ready to install.
    private func fetchAndCheck(_ feed: ReleaseFeed) async throws -> URL {
        try? FileManager.default.removeItem(at: work)
        try PrivateFiles.directory(work)
        let archive = work.appendingPathComponent("LiveMeetingListener.zip")
        try await downloads.download(from: feed.url, to: archive)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == feed.length else { throw ReleaseCheckFailure.length(expected: feed.length, got: data.count) }
        guard UpdateSigning.verify(data, signature: feed.ed_signature, publicKey: channel.publicKey) else { throw ReleaseCheckFailure.signature }

        let unpacked = work.appendingPathComponent("unpacked")
        try PrivateFiles.directory(unpacked)
        let unzip = try await runner.run(ReleaseCommands.unzip(archive, into: unpacked))
        guard unzip.status == 0 else { throw ReleaseCheckFailure.archive(Self.text(unzip)) }
        try? FileManager.default.removeItem(at: archive)
        let items = try FileManager.default.contentsOfDirectory(atPath: unpacked.path).filter { !$0.hasPrefix(".") }
        guard items.count == 1, let name = items.first, name.hasSuffix(".app") else {
            throw ReleaseCheckFailure.archive("expected one app, found \(items.sorted())")
        }
        let app = unpacked.appendingPathComponent(name)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let infoData = FileManager.default.contents(atPath: infoURL.path),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw ReleaseCheckFailure.archive("no Info.plist")
        }
        let id = info["CFBundleIdentifier"] as? String ?? "unknown"
        guard id == channel.bundleID else { throw ReleaseCheckFailure.identity(id) }
        let shown = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard ReleaseVersion(tag: shown) == feed.version else { throw ReleaseCheckFailure.version(shown) }
        guard FileManager.default.fileExists(atPath: ReleaseCommands.installer(in: app).path) else {
            throw ReleaseCheckFailure.archive("no installer in the app")
        }

        let signature = try await runner.run(ReleaseCommands.verifySignature(app, requirement: channel.requirement))
        guard signature.status == 0 else { throw ReleaseCheckFailure.codeSignature(Self.text(signature)) }
        let gatekeeper = try await runner.run(ReleaseCommands.assess(app))
        guard gatekeeper.status == 0 else { throw ReleaseCheckFailure.gatekeeper(Self.text(gatekeeper)) }
        return app
    }

    private static func text(_ output: ProcessOutput) -> String {
        let text = String(decoding: output.stdout.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(output.status)" : text
    }
}
