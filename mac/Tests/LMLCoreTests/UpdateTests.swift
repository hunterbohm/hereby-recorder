import Foundation
import Testing
import Synchronization
@testable import LMLCore

private func folder() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Answers each command from `reply`, keyed by the command's words, and records every command it saw.
private actor ScriptedRunner: ProcessRunner {
    private var replies: [String: ProcessOutput]
    private(set) var commands: [ProcessCommand] = []
    init(_ replies: [String: ProcessOutput] = [:]) { self.replies = replies }
    func set(_ key: String, _ output: ProcessOutput) { replies[key] = output }
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        commands.append(command)
        let words = command.arguments.joined(separator: " ")
        return replies.first { words.contains($0.key) }?.value ?? ProcessOutput(status: 0)
    }
    func cancel() async {}
    func words() -> [String] { commands.map { $0.arguments.joined(separator: " ") } }
}

private func output(_ text: String, status: Int32 = 0) -> ProcessOutput { ProcessOutput(status: status, stdout: Data(text.utf8)) }

private let lsRemote = """
    1111111111111111111111111111111111111111\trefs/tags/v2.9.0
    2222222222222222222222222222222222222222\trefs/tags/v2.13.0
    3333333333333333333333333333333333333333\trefs/tags/v2.13.0^{}
    4444444444444444444444444444444444444444\trefs/tags/v2.14.0
    5555555555555555555555555555555555555555\trefs/tags/v2.15.0-rc.1
    6666666666666666666666666666666666666666\trefs/tags/local-build
    7777777777777777777777777777777777777777\trefs/heads/v9.9.9
    """

struct ReleaseVersionTests {
    @Test func releaseTagsParseWithOrWithoutTheV() {
        #expect(ReleaseVersion(tag: "v2.13.0") == ReleaseVersion(2, 13, 0))
        #expect(ReleaseVersion(tag: "2.13.0") == ReleaseVersion(2, 13, 0))
        #expect(ReleaseVersion(tag: "v0.0.1")?.tag == "v0.0.1")
    }

    @Test func preReleaseBuildAndOtherTagsAreNotReleases() {
        for tag in ["v2.14.0-rc.1", "v2.14.0+build.5", "v2.14", "v2.14.0.1", "local-build", "v2..0", "v1.02.0", "V2.13.0", "v-1.0.0", "v２.1.0", ""] {
            #expect(ReleaseVersion(tag: tag) == nil, "\(tag)")
        }
    }

    @Test func versionsCompareByNumberNotByText() {
        #expect(ReleaseVersion(2, 10, 0) > ReleaseVersion(2, 9, 0))
        #expect(ReleaseVersion(3, 0, 0) > ReleaseVersion(2, 99, 99))
        #expect(ReleaseVersion(2, 13, 1) > ReleaseVersion(2, 13, 0))
        #expect(!(ReleaseVersion(2, 13, 0) < ReleaseVersion(2, 13, 0)))
    }

    @Test func lsRemoteOutputYieldsTheReleaseTagsOnly() {
        #expect(ReleaseTags.versions(lsRemote: lsRemote) == [ReleaseVersion(2, 9, 0), ReleaseVersion(2, 13, 0), ReleaseVersion(2, 14, 0)])
        #expect(ReleaseTags.versions(lsRemote: "") == [])
    }

    @Test func theNewerReleaseIsTheNewestAboveTheAppsOwn() {
        #expect(ReleaseTags.newer(than: ReleaseVersion(2, 13, 0), lsRemote: lsRemote) == ReleaseVersion(2, 14, 0))
        #expect(ReleaseTags.newer(than: ReleaseVersion(2, 9, 0), lsRemote: lsRemote) == ReleaseVersion(2, 14, 0))
        #expect(ReleaseTags.newer(than: ReleaseVersion(2, 14, 0), lsRemote: lsRemote) == nil)
    }

    @Test func theBundleNamesItsCloneAndARelease() {
        let checkout = UpdateCheckout(info: ["HerebyCheckout": "/Users/a/hereby-recorder", "CFBundleShortVersionString": "v2.13.0"])
        #expect(checkout == UpdateCheckout(path: URL(fileURLWithPath: "/Users/a/hereby-recorder"), current: ReleaseVersion(2, 13, 0)))
        #expect(UpdateCheckout(info: ["CFBundleShortVersionString": "v2.13.0"]) == nil)
        #expect(UpdateCheckout(info: ["HerebyCheckout": "/Users/a/r", "CFBundleShortVersionString": "local-build"]) == nil)
        #expect(UpdateCheckout(info: ["HerebyCheckout": "relative", "CFBundleShortVersionString": "v2.13.0"]) == nil)
        #expect(UpdateCheckout(info: nil) == nil)
    }
}

struct UpdateRuleTests {
    @Test func aCallComesFirstThenChangesThenTheTag() {
        #expect(UpdateRules.refusal(inCall: true, changes: " M mac/Info.plist\n", onTag: false) == .inCall)
        #expect(UpdateRules.refusal(inCall: false, changes: " M mac/Info.plist\n", onTag: false) == .uncommitted)
        #expect(UpdateRules.refusal(inCall: false, changes: "\n", onTag: false) == .notOnTag)
        #expect(UpdateRules.refusal(inCall: false, changes: "", onTag: true) == nil)
    }
}

struct UpdateCommandTests {
    private let clone = URL(fileURLWithPath: "/Users/a/hereby recorder")

    @Test func theCheckAsksTheClonesOwnRemoteWithoutPrompting() {
        let command = UpdateCommands.listTags(clone)
        #expect(command.executable == "/usr/bin/env")
        #expect(command.arguments == ["GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-C", "/Users/a/hereby recorder", "ls-remote", "--tags", "origin"])
        #expect(command.timeout != nil)
    }

    @Test func theRulesReadTrackedChangesAndTheExactTag() {
        #expect(UpdateCommands.changes(clone).arguments == ["-C", clone.path, "status", "--porcelain", "--untracked-files=no"])
        #expect(UpdateCommands.exactTag(clone).arguments == ["-C", clone.path, "describe", "--tags", "--exact-match", "HEAD"])
    }

    @Test func theJobIsAOneShotAgentThatLogsAndRunsTheScript() throws {
        let job = UpdateCommands.job(checkout: clone, version: ReleaseVersion(2, 14, 0),
                                     log: URL(fileURLWithPath: "/s/update/update.log"), status: URL(fileURLWithPath: "/s/update/status"))
        #expect(job["Label"] as? String == "sh.hereby.recorder.update")
        #expect(job["ProgramArguments"] as? [String] == ["/bin/bash", "-c", UpdateCommands.script, "hereby-update", clone.path, "v2.14.0", "/s/update/status"])
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] == nil)
        #expect(job["StandardOutPath"] as? String == "/s/update/update.log")
        #expect(job["StandardErrorPath"] as? String == "/s/update/update.log")
        _ = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        #expect(UpdateCommands.script.contains("git fetch --tags origin"))
        #expect(UpdateCommands.script.contains("git checkout --quiet \"refs/tags/$tag\""))
        #expect(UpdateCommands.script.contains("mac/scripts/build-app.sh"))
    }

    @Test func launchctlPrintShowsARunningJobByItsPid() {
        #expect(UpdateCommands.isRunning("gui/501/sh.hereby.recorder.update = {\n\tstate = running\n\tpid = 4242\n}"))
        #expect(!UpdateCommands.isRunning("gui/501/sh.hereby.recorder.update = {\n\tstate = not running\n\tlast exit code = 1\n}"))
    }

    /// The real script against a throwaway clone: it fetches the new tag, checks it out, runs that tag's build-app.sh,
    /// and writes the exit code where the panel looks.
    @Test func theScriptMovesAThrowawayCloneToTheTagAndRunsItsBuild() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func sh(_ line: String) async throws -> ProcessOutput {
            let result = try await LocalProcessRunner().run(ProcessCommand("/bin/bash", ["-c", "set -e; cd \"$1\"; " + line, "sh", root.path], timeout: 60))
            #expect(result.status == 0, "\(line)")
            return result
        }
        let git = "git -c user.name=t -c user.email=t@example.test -c init.defaultBranch=main"
        _ = try await sh("""
            \(git) init -q origin && cd origin && mkdir -p mac/scripts
            printf '#!/bin/sh\\necho old > "$0.ran"\\n' > mac/scripts/build-app.sh && chmod +x mac/scripts/build-app.sh
            \(git) add -A && \(git) commit -qm one && \(git) tag v1.0.0
            cd .. && \(git) clone -q origin clone && cd clone && \(git) checkout -q v1.0.0 && cd ../origin
            printf '#!/bin/sh\\necho "$(git describe --tags)" > ../built\\n' > mac/scripts/build-app.sh
            \(git) commit -qam two && \(git) tag v1.1.0
            """)
        let status = root.appendingPathComponent("status")
        let run = try await LocalProcessRunner().run(ProcessCommand("/bin/bash", ["-c", UpdateCommands.script, "hereby-update",
                                                                                  root.appendingPathComponent("clone").path, "v1.1.0", status.path], timeout: 60))
        #expect(run.status == 0)
        #expect(try String(contentsOf: status, encoding: .utf8) == "0\n")
        #expect(try String(contentsOf: root.appendingPathComponent("built"), encoding: .utf8) == "v1.1.0\n")
        #expect(String(decoding: try await sh("cd clone && git describe --tags --exact-match HEAD").stdout, as: UTF8.self) == "v1.1.0\n")

        let missing = try await LocalProcessRunner().run(ProcessCommand("/bin/bash", ["-c", UpdateCommands.script, "hereby-update",
                                                                                      root.appendingPathComponent("clone").path, "v9.0.0", status.path], timeout: 60))
        #expect(missing.status != 0)
        #expect(try String(contentsOf: status, encoding: .utf8) != "0\n")
    }
}

struct UpdaterTests {
    private func updater(_ runner: ScriptedRunner, root: URL, clone: URL? = nil, current: ReleaseVersion = ReleaseVersion(2, 13, 0)) throws -> Updater {
        let clone = clone ?? root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return Updater(checkout: UpdateCheckout(path: clone, current: current), root: root.appendingPathComponent("state"), runner: runner, uid: 501)
    }

    @Test func theRemoteIsAskedAtMostOnceADayEvenAcrossRestarts() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["ls-remote": output(lsRemote)])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try await updater(runner, root: root).newerRelease(now: start) == ReleaseVersion(2, 14, 0))
        #expect(try await updater(runner, root: root).newerRelease(now: start.addingTimeInterval(23 * 3600)) == ReleaseVersion(2, 14, 0))
        #expect(await runner.words().filter { $0.contains("ls-remote") }.count == 1)
        #expect(try await updater(runner, root: root).newerRelease(now: start.addingTimeInterval(25 * 3600)) == ReleaseVersion(2, 14, 0))
        #expect(await runner.words().filter { $0.contains("ls-remote") }.count == 2)
    }

    @Test func theAppsOwnVersionOrOlderShowsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["ls-remote": output(lsRemote)])
        #expect(try await updater(runner, root: root, current: ReleaseVersion(2, 14, 0)).newerRelease(now: Date()) == nil)
    }

    @Test func aFailedAskShowsNothingAndWaitsADay() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["ls-remote": output("fatal: 'origin' does not appear to be a git repository", status: 128)])
        let updates = try updater(runner, root: root)
        #expect(await updates.newerRelease(now: Date()) == nil)
        #expect(await updates.newerRelease(now: Date()) == nil)
        #expect(await runner.commands.count == 1)
    }

    @Test func aMissingCloneShowsNothingAndRunsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["ls-remote": output(lsRemote)])
        let updates = Updater(checkout: UpdateCheckout(path: root.appendingPathComponent("gone"), current: ReleaseVersion(2, 13, 0)),
                              root: root, runner: runner, uid: 501)
        #expect(await updates.newerRelease(now: Date()) == nil)
        #expect(await runner.commands.isEmpty)
        await #expect(throws: UpdateRefusal.noCheckout) { try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false) }
    }

    @Test func eachRefusalStopsBeforeLaunchd() async throws {
        let cases: [(Bool, [String: ProcessOutput], UpdateRefusal)] = [
            (true, [:], .inCall),
            (false, ["status": output(" M mac/Sources/lml/Main.swift\n")], .uncommitted),
            (false, ["describe": output("", status: 128)], .notOnTag),
            (false, ["print": output("\tstate = running\n\tpid = 77\n")], .running)
        ]
        for (inCall, replies, refusal) in cases {
            let root = try folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = ScriptedRunner(replies)
            let updates = try updater(runner, root: root)
            await #expect(throws: refusal) { try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: inCall) }
            let words = await runner.words()
            #expect(!words.contains { $0.hasPrefix("bootstrap") || $0.hasPrefix("bootout") })
            if inCall { #expect(await runner.commands.isEmpty) }
        }
    }

    @Test func aCleanTaggedCloneStartsTheJobFromItsOwnPlist() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["print": output("", status: 113)])
        let updates = try updater(runner, root: root)
        try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false)
        let plist = root.appendingPathComponent("state/update/sh.hereby.recorder.update.plist")
        let words = await runner.words()
        #expect(words.suffix(2) == ["bootout gui/501/sh.hereby.recorder.update", "bootstrap gui/501 \(plist.path)"])
        let job = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect((job["ProgramArguments"] as? [String])?.suffix(3) == [root.appendingPathComponent("clone").path, "v2.14.0",
                                                                      root.appendingPathComponent("state/update/status").path])
        #expect(updates.logPath == root.appendingPathComponent("state/update/update.log").path)
    }

    @Test func aJobLaunchdWouldNotStartFailsWithALogLine() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["print": output("", status: 113), "bootstrap": output("", status: 5)])
        let updates = try updater(runner, root: root)
        await #expect(throws: UpdateFailure(status: 5)) { try await updates.startUpdate(to: ReleaseVersion(2, 14, 0), inCall: false) }
        #expect(try String(contentsOfFile: updates.logPath, encoding: .utf8).contains("launchctl bootstrap exited 5"))
    }

    @Test func progressComesFromTheStatusFileThenTheJob() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ScriptedRunner(["print": output("\tpid = 77\n")])
        let updates = try updater(runner, root: root)
        #expect(await updates.updateProgress() == .running)
        await runner.set("print", output("\tlast exit code = 1\n"))
        #expect(await updates.updateProgress() == .failed)
        let status = root.appendingPathComponent("state/update/status")
        try FileManager.default.createDirectory(at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("0\n".utf8).write(to: status)
        #expect(await updates.updateProgress() == .succeeded)
        try Data("3\n".utf8).write(to: status)
        #expect(await updates.updateProgress() == .failed)
    }
}
