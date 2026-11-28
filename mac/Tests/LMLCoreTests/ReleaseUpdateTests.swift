import Foundation
import Testing
@testable import LMLCore

private func folder() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-release-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func output(_ text: String, status: Int32 = 0) -> ProcessOutput { ProcessOutput(status: status, stdout: Data(text.utf8)) }

private let team = "ABCDE12345"
private let bundleID = "sh.hereby.recorder"
private let key = UpdateSigning.newPrivateKey()
private let publicKey = try! UpdateSigning.publicKey(ofPrivate: key)
private let feedURL = URL(string: "https://github.com/example/recorder/releases/latest/download/appcast.json")!
private let zipURL = URL(string: "https://github.com/example/recorder/releases/download/v2.14.0/LiveMeetingListener-v2.14.0.zip")!

private func feed(_ archive: Data, version: ReleaseVersion = ReleaseVersion(2, 14, 0), signedWith signer: String = key,
                  length: Int? = nil, minimum: String = "26.0") throws -> ReleaseFeed {
    ReleaseFeed(version: version, url: zipURL, length: length ?? archive.count,
                ed_signature: try UpdateSigning.sign(archive, privateKey: signer), minimum_system_version: minimum)
}

/// Serves one feed and one zip, and counts how often each was asked for.
private actor FakeDownloads: UpdateDownloads {
    var feed: Data?
    var archive: Data
    private(set) var feedRequests = 0
    private(set) var archiveRequests = 0
    init(feed: Data?, archive: Data) { self.feed = feed; self.archive = archive }
    func set(feed: Data?) { self.feed = feed }
    func data(from url: URL) async throws -> Data {
        feedRequests += 1
        guard let feed else { throw WebDownloads.BadResponse(status: 404) }
        return feed
    }
    func download(from url: URL, to file: URL) async throws {
        archiveRequests += 1
        try archive.write(to: file)
    }
}

/// Runs `ditto` for real, so the zip really unpacks, and answers codesign, spctl and launchctl from `replies`.
private actor HybridRunner: ProcessRunner {
    private var replies: [String: ProcessOutput]
    private(set) var commands: [ProcessCommand] = []
    init(_ replies: [String: ProcessOutput] = [:]) { self.replies = replies }
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        commands.append(command)
        if command.arguments.contains("/usr/bin/ditto") { return try await LocalProcessRunner().run(command) }
        let words = command.arguments.joined(separator: " ")
        return replies.first { words.contains($0.key) }?.value ?? ProcessOutput(status: 0)
    }
    func cancel() async {}
    func words() -> [String] { commands.map { $0.arguments.joined(separator: " ") } }
}

/// A zipped stand-in for a release: an app folder with an Info.plist and the installer, zipped by real ditto.
private func releaseZip(in root: URL, id: String = bundleID, version: String = "v2.14.0", installer: Bool = true) async throws -> Data {
    let app = root.appendingPathComponent("source-\(UUID().uuidString)/LiveMeetingListener.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/scripts"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    if installer { try Data("#!/bin/bash\necho installed\n".utf8).write(to: ReleaseCommands.installer(in: app)) }
    let zip = root.appendingPathComponent("release-\(UUID().uuidString).zip")
    let result = try await LocalProcessRunner().run(ProcessCommand("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]))
    #expect(result.status == 0)
    return try Data(contentsOf: zip)
}

private let installed = URL(fileURLWithPath: "/Users/a/Applications/LiveMeetingListener.app")
private func channel(current: ReleaseVersion = ReleaseVersion(2, 13, 0)) -> ReleaseChannel {
    ReleaseChannel(feed: feedURL, publicKey: publicKey, teamID: team, bundleID: bundleID, current: current, app: installed)
}

struct ReleaseFeedTests {
    @Test func aFeedRoundTripsThroughItsJSON() throws {
        let original = try feed(Data("zip".utf8))
        let text = String(decoding: try original.encoded(), as: UTF8.self)
        #expect(text.contains("\"version\" : \"v2.14.0\""))
        #expect(text.contains("\"url\" : \"https://github.com/example/"))
        #expect(ReleaseFeed.parse(try original.encoded()) == original)
    }

    @Test func aFeedThatIsNotHttpsHasNoLengthOrNoSystemIsRefused() throws {
        func parse(_ edit: (inout [String: Any]) -> Void) throws -> ReleaseFeed? {
            var value = try JSONSerialization.jsonObject(with: try feed(Data("zip".utf8)).encoded()) as! [String: Any]
            edit(&value)
            return ReleaseFeed.parse(try JSONSerialization.data(withJSONObject: value))
        }
        #expect(try parse { _ in } != nil)
        #expect(try parse { $0["url"] = "http://github.com/x.zip" } == nil)
        #expect(try parse { $0["url"] = "file:///tmp/x.zip" } == nil)
        #expect(try parse { $0["length"] = 0 } == nil)
        #expect(try parse { $0["minimum_system_version"] = "twenty-six" } == nil)
        #expect(try parse { $0["version"] = "v2.15.0-rc.1" } == nil)
        #expect(try parse { $0.removeValue(forKey: "ed_signature") } == nil)
        #expect(ReleaseFeed.parse(Data("<html>".utf8)) == nil)
    }

    @Test func onlyANewerReleaseThatRunsHereIsOffered() throws {
        let item = try feed(Data("zip".utf8), minimum: "26.1")
        let system = SystemVersion("26.1")!
        #expect(item.offer(current: ReleaseVersion(2, 13, 0), system: system) == ReleaseVersion(2, 14, 0))
        #expect(item.offer(current: ReleaseVersion(2, 14, 0), system: system) == nil)
        #expect(item.offer(current: ReleaseVersion(2, 15, 0), system: system) == nil)
        #expect(item.offer(current: ReleaseVersion(2, 13, 0), system: SystemVersion("26.0.9")!) == nil)
    }

    @Test func systemVersionsCompareByNumber() {
        #expect(SystemVersion("26.0") == SystemVersion("26.0.0"))
        #expect(SystemVersion("26.10")! > SystemVersion("26.9")!)
        #expect(SystemVersion("27")! > SystemVersion("26.99.99")!)
        for text in ["", "26.", "26.0.0.0", "26.x", "-1"] { #expect(SystemVersion(text) == nil, "\(text)") }
    }
}

struct UpdateSigningTests {
    @Test func aSignatureVerifiesOnlyForItsBytesAndKey() throws {
        let data = Data("release bytes".utf8)
        let signature = try UpdateSigning.sign(data, privateKey: key)
        #expect(UpdateSigning.verify(data, signature: signature, publicKey: publicKey))
        #expect(!UpdateSigning.verify(Data("release bytez".utf8), signature: signature, publicKey: publicKey))
        let other = try UpdateSigning.publicKey(ofPrivate: UpdateSigning.newPrivateKey())
        #expect(!UpdateSigning.verify(data, signature: signature, publicKey: other))
        #expect(!UpdateSigning.verify(data, signature: "not base64", publicKey: publicKey))
        #expect(!UpdateSigning.verify(data, signature: signature, publicKey: "AAAA"))
    }

    @Test func keysAreThirtyTwoRawBytesInBase64() throws {
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(Data(base64Encoded: publicKey)?.count == 32)
        #expect(UpdateSigning.isPublicKey(publicKey))
        #expect(!UpdateSigning.isPublicKey("short"))
        #expect(throws: UpdateSigning.BadKey.self) { try UpdateSigning.publicKey(ofPrivate: "AAAA") }
        #expect(try UpdateSigning.publicKey(ofPrivate: key + "\n") == publicKey)
    }

    /// A known Ed25519 vector (RFC 8032, test 1), so signatures stay plain Ed25519 like Sparkle's.
    @Test func signaturesAreStandardEd25519() throws {
        func bytes(_ hex: String) -> Data {
            Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
        }
        let seed = bytes("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60").base64EncodedString()
        #expect(try UpdateSigning.publicKey(ofPrivate: seed) == bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a").base64EncodedString())
        let signature = bytes("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        #expect(UpdateSigning.verify(Data(), signature: signature.base64EncodedString(), publicKey: try UpdateSigning.publicKey(ofPrivate: seed)))
    }
}

struct ReleaseChannelTests {
    private let info: [String: Any] = [
        "HerebyUpdateFeed": feedURL.absoluteString, "HerebyUpdatePublicKey": publicKey, "HerebyTeamID": team,
        "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "v2.13.0"
    ]

    @Test func aSignedReleaseNamesItsFeedKeyAndTeam() {
        #expect(ReleaseChannel(info: info, app: installed) == channel())
    }

    @Test func anyMissingOrMalformedKeyMeansNoSignedUpdates() {
        let edits: [(String, Any?)] = [
            ("HerebyUpdateFeed", nil), ("HerebyUpdateFeed", "http://example.com/appcast.json"),
            ("HerebyUpdatePublicKey", nil), ("HerebyUpdatePublicKey", "nope"),
            ("HerebyTeamID", nil), ("HerebyTeamID", "abcde12345"), ("HerebyTeamID", "ABC\" or 1"),
            ("CFBundleIdentifier", "sh.hereby\"recorder"), ("CFBundleShortVersionString", "local-build")
        ]
        for (name, value) in edits {
            var edited = info
            edited[name] = value
            #expect(ReleaseChannel(info: edited, app: installed) == nil, "\(name)")
        }
        #expect(ReleaseChannel(info: nil, app: installed) == nil)
    }

    @Test func aSourceBuildStampedWithItsCloneKeepsTheCloneUpdater() {
        let source: [String: Any] = ["HerebyCheckout": "/Users/a/r", "CFBundleShortVersionString": "v2.13.0", "CFBundleIdentifier": bundleID]
        #expect(ReleaseChannel(info: source, app: installed) == nil)
        #expect(UpdateCheckout(info: source) != nil)
    }

    @Test func updatesMustBeAppleIssuedForThisTeamAndBundle() {
        #expect(channel().requirement == "anchor apple generic and identifier \"sh.hereby.recorder\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}

struct ReleaseUpdaterTests {
    private func updater(_ runner: HybridRunner, _ downloads: FakeDownloads, root: URL, current: ReleaseVersion = ReleaseVersion(2, 13, 0),
                         system: String = "26.0") -> ReleaseUpdater {
        ReleaseUpdater(channel: channel(current: current), root: root.appendingPathComponent("state"), runner: runner,
                       downloads: downloads, uid: 501, system: SystemVersion(system)!)
    }

    @Test func theFeedIsAskedAtMostOnceADayAndAFailedAskCounts() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = FakeDownloads(feed: try feed(Data("zip".utf8)).encoded(), archive: Data())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await updater(HybridRunner(), downloads, root: root).newerRelease(now: start) == ReleaseVersion(2, 14, 0))
        #expect(await updater(HybridRunner(), downloads, root: root).newerRelease(now: start.addingTimeInterval(23 * 3600)) == ReleaseVersion(2, 14, 0))
        #expect(await downloads.feedRequests == 1)
        await downloads.set(feed: nil)
        #expect(await updater(HybridRunner(), downloads, root: root).newerRelease(now: start.addingTimeInterval(25 * 3600)) == nil)
        #expect(await updater(HybridRunner(), downloads, root: root).newerRelease(now: start.addingTimeInterval(26 * 3600)) == nil)
        #expect(await downloads.feedRequests == 2)
    }

    @Test func theAppsOwnVersionOrAReleaseForANewerSystemShowsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = FakeDownloads(feed: try feed(Data("zip".utf8), minimum: "27.0").encoded(), archive: Data())
        #expect(await updater(HybridRunner(), downloads, root: root).newerRelease(now: Date()) == nil)
        let current = FakeDownloads(feed: try feed(Data("zip".utf8)).encoded(), archive: Data())
        #expect(await updater(HybridRunner(), current, root: try folder(), current: ReleaseVersion(2, 14, 0)).newerRelease(now: Date()) == nil)
    }

    @Test func aCheckedReleaseStartsTheInstallJobWithItsOwnInstaller() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await releaseZip(in: root)
        let downloads = FakeDownloads(feed: try feed(archive).encoded(), archive: archive)
        let runner = HybridRunner(["print": output("", status: 113)])
        let updates = updater(runner, downloads, root: root)
        #expect(await updates.newerRelease(now: Date()) == ReleaseVersion(2, 14, 0))
        try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false)

        let state = root.appendingPathComponent("state/update")
        let app = state.appendingPathComponent("download/unpacked/LiveMeetingListener.app")
        let words = await runner.words()
        #expect(words.contains { $0.contains("/usr/bin/codesign --verify --deep --strict -R =\(channel().requirement) \(app.path)") })
        #expect(words.contains { $0.contains("/usr/sbin/spctl --assess --type execute \(app.path)") })
        let plist = state.appendingPathComponent("sh.hereby.recorder.update.plist")
        #expect(words.suffix(2) == ["bootout gui/501/sh.hereby.recorder.update", "bootstrap gui/501 \(plist.path)"])
        let job = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let installer = state.appendingPathComponent("install-app.sh")
        #expect(job["ProgramArguments"] as? [String] == ["/bin/bash", "-c", ReleaseCommands.script, "hereby-update", app.path, installed.path,
                                                         state.appendingPathComponent("status").path, installer.path])
        #expect(job["Label"] as? String == "sh.hereby.recorder.update" && job["KeepAlive"] == nil)
        #expect(try String(contentsOf: installer, encoding: .utf8).contains("echo installed"))
        #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("download/LiveMeetingListener.zip").path))
        #expect(await downloads.archiveRequests == 1)
    }

    @Test func aCallOrARunningJobRefusesBeforeAnyDownload() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = FakeDownloads(feed: try feed(Data("zip".utf8)).encoded(), archive: Data("zip".utf8))
        await #expect(throws: UpdateRefusal.inCall) {
            try await updater(HybridRunner(), downloads, root: root).startUpdate(to: ReleaseVersion(2, 14, 0), inCall: true)
        }
        let busy = HybridRunner(["print": output("\tstate = running\n\tpid = 77\n")])
        await #expect(throws: UpdateRefusal.running) {
            try await updater(busy, downloads, root: root).startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false)
        }
        #expect(await downloads.archiveRequests == 0)
    }

    /// Each bad download stops before launchd and says why in the log.
    @Test func eachFailedCheckStopsBeforeTheInstallAndLogsWhy() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try await releaseZip(in: root)
        let otherKey = UpdateSigning.newPrivateKey()
        let cases: [(Data, (Data) throws -> ReleaseFeed, [String: ProcessOutput], String)] = [
            (good, { try feed($0, signedWith: otherKey) }, [:], ReleaseCheckFailure.signature.description),
            (good, { try feed($0, length: $0.count + 1) }, [:], ReleaseCheckFailure.length(expected: good.count + 1, got: good.count).description),
            (try await releaseZip(in: root, id: "com.example.other"), { try feed($0) }, [:], ReleaseCheckFailure.identity("com.example.other").description),
            (try await releaseZip(in: root, version: "v2.15.0"), { try feed($0) }, [:], ReleaseCheckFailure.version("v2.15.0").description),
            (try await releaseZip(in: root, installer: false), { try feed($0) }, [:], ReleaseCheckFailure.archive("no installer in the app").description),
            (Data("not a zip".utf8), { try feed($0) }, [:], "the download is not a usable app: "),
            (good, { try feed($0) }, ["codesign": output("test requirement failed", status: 3)], ReleaseCheckFailure.codeSignature("test requirement failed").description),
            (good, { try feed($0) }, ["spctl": output("rejected", status: 3)], ReleaseCheckFailure.gatekeeper("rejected").description)
        ]
        for (archive, makeFeed, replies, reason) in cases {
            let state = try folder()
            defer { try? FileManager.default.removeItem(at: state) }
            let downloads = FakeDownloads(feed: try makeFeed(archive).encoded(), archive: archive)
            let runner = HybridRunner(replies.merging(["print": output("", status: 113)]) { kept, _ in kept })
            let updates = updater(runner, downloads, root: state)
            _ = await updates.newerRelease(now: Date())
            await #expect(throws: ReleaseCheckFailure.self, "\(reason)") { try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false) }
            #expect(!(await runner.words()).contains { $0.hasPrefix("bootstrap") }, "\(reason)")
            let log = try String(contentsOfFile: updates.logPath, encoding: .utf8)
            #expect(log.hasPrefix("Couldn't update to v2.14.0: \(reason)"), "\(log)")
        }
    }

    @Test func aFeedThatMovedOnSinceTheCheckIsNotInstalled() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = Data("zip".utf8)
        let downloads = FakeDownloads(feed: try feed(archive).encoded(), archive: archive)
        let updates = updater(HybridRunner(["print": output("", status: 113)]), downloads, root: root)
        await #expect(throws: ReleaseCheckFailure.changed(ReleaseVersion(2, 14, 0))) {
            try await updates.startUpdate(to: ReleaseVersion(2, 15, 0), inCall: false)
        }
        #expect(await downloads.archiveRequests == 0)
    }

    /// The real job script, with a stand-in installer: it gets the new app, the installed app's path in
    /// LML_APP_DESTINATION, and its exit code lands in the status file.
    @Test func theJobScriptRunsTheInstallerAndRecordsItsExit() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = root.appendingPathComponent("install-app.sh")
        let status = root.appendingPathComponent("status")
        func run(exit code: Int) async throws -> String {
            try Data("printf '%s %s\\n' \"$LML_APP_DESTINATION\" \"$1\" > \"\(root.path)/ran\"\nexit \(code)\n".utf8).write(to: installer)
            let result = try await LocalProcessRunner().run(ProcessCommand("/bin/bash", ["-c", ReleaseCommands.script, "hereby-update", "/tmp/new.app",
                                                                                         "/Apps/LiveMeetingListener.app", status.path, installer.path], timeout: 30))
            #expect((result.status == 0) == (code == 0))
            return try String(contentsOf: status, encoding: .utf8)
        }
        #expect(try await run(exit: 0) == "0\n")
        #expect(try String(contentsOf: root.appendingPathComponent("ran"), encoding: .utf8) == "/Apps/LiveMeetingListener.app /tmp/new.app\n")
        #expect(try await run(exit: 3) == "3\n")
    }
}
