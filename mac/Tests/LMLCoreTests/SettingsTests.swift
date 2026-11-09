import Foundation
import Testing
@testable import LMLCore

private let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../recorder.example.toml").standardized
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-settings-\(UUID().uuidString)")
    try PrivateFiles.directory(directory); return directory
}
private func failure(_ toml: String) -> SettingsError? {
    do { _ = try Settings(toml: toml); return nil } catch { return error as? SettingsError }
}

struct SettingsFileTests {
    @Test func aMissingFileGivesNoSettingsAndTheDefaultsKeepMeetingsOnTheMac() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Settings.load(root.appendingPathComponent("recorder.toml")) == nil)
        let defaults = Settings()
        #expect(defaults.sshHost == nil && defaults.mini == nil)
        #expect(defaults.storageRoot == "~/.local/state/live-meeting")
        #expect(defaults.meetingApps == Settings.defaultMeetingApps && defaults.meetingApps.contains("us.zoom"))
        #expect(defaults.micOrder.isEmpty && defaults.retentionDays == 14)
        #expect(try Settings(toml: "# nothing set\n\n") == defaults)
    }
    @Test func theFileLivesUnderXDGConfigHomeOrDotConfig() {
        let home = URL(fileURLWithPath: "/Users/sam")
        #expect(Settings.url(environment: [:], home: home).path == "/Users/sam/.config/hereby/recorder.toml")
        #expect(Settings.url(environment: ["XDG_CONFIG_HOME": ""], home: home).path == "/Users/sam/.config/hereby/recorder.toml")
        #expect(Settings.url(environment: ["XDG_CONFIG_HOME": "/tmp/conf"], home: home).path == "/tmp/conf/hereby/recorder.toml")
    }
    @Test func theExampleFileSetsEverySettingTheMacUses() throws {
        let settings = try #require(try Settings.load(example))
        #expect(settings.mini == Mini(host: "studio", root: "~/.local/state/live-meeting"))
        #expect(settings.meetingApps == ["us.zoom", "com.google.Chrome", "com.apple.FaceTime"])
        #expect(settings.micOrder == ["Shure", "AirPods", "MacBook Pro Microphone"])
        #expect(settings.retentionDays == 14)
        #expect(settings.screenContext)
    }
    @Test func screenContextIsOnUnlessTurnedOffAndMustBeTrueOrFalse() throws {
        #expect(Settings().screenContext)
        #expect(try Settings(toml: "screen_context = false").screenContext == false)
        #expect(throws: SettingsError.self) { try Settings(toml: "screen_context = \"no\"") }
    }
    @Test func readsTheTOMLThatSettingsFilesUse() throws {
        let settings = try Settings(toml: """
            ssh_host = 'studio.local'   # a literal string
            mic_order = [
              "Blue \\"Yeti\\"", # quoted
              "R\\u00f8de",
            ]
            retention_days = +1_0\r
            user_name = "Sam" # read by the mini
            """)
        #expect(settings.sshHost == "studio.local")
        #expect(settings.micOrder == ["Blue \"Yeti\"", "Røde"])
        #expect(settings.retentionDays == 10)
    }
    @Test(arguments: [
        ("retention_days = 0", "retention_days", "must be a whole number of days, 1 or more"),
        ("retention_days = -3", "retention_days", "must be a whole number of days, 1 or more"),
        ("retention_days = \"14\"", "retention_days", "must be a whole number of days, 1 or more"),
        ("retention_days = true", "retention_days", "must be a whole number of days, 1 or more"),
        ("ssh_host = \"-oProxyCommand=x\"", "ssh_host", "must be an ssh host with no spaces"),
        ("ssh_host = \"my mini\"", "ssh_host", "must be an ssh host with no spaces"),
        ("storage_root = \"state/lml\"", "storage_root", "must be a path that starts with ~/ or /, with no quotes, $, or backslashes"),
        ("storage_root = \"~/$(id)\"", "storage_root", "must be a path that starts with ~/ or /, with no quotes, $, or backslashes"),
        ("mic_order = \"Shure\"", "mic_order", "must be a list of strings"),
        ("emails = [\"a@example.com\", 3]", "emails", "must be a list of strings"),
        ("user_name = \"  \"", "user_name", "must be a string"),
        ("retention_day = 14", "retention_day", "is not a setting"),
        ("retention_days = 7\nretention_days = 8", "retention_days", "is set twice"),
    ])
    func aBadValueNamesItsField(toml: String, field: String, problem: String) {
        #expect(failure(toml) == SettingsError(field: field, problem: problem))
    }
    @Test(arguments: [
        ("[mac]\nssh_host = \"mini\"", "line 1: tables are not supported"),
        ("ssh_host \"mini\"", "line 1: expected = after ssh_host"),
        ("\n\nretention_days = 1.5", "line 3: unsupported value 1.5"),
        ("ssh_host = \"mini", "line 1: unterminated string"),
        ("mic_order = [\"a\" \"b\"]", "line 1: expected , or ] in a list"),
        ("ssh_host = \"mini\" extra", "line 1: unexpected text after ssh_host"),
        ("retention_days = 014", "line 1: unsupported value 014"),
        ("user_name = \"a\u{1}b\"", "line 1: control character in a string"),
        ("user_name = 'a\u{7f}b'", "line 1: control character in a string"),
    ])
    func aSyntaxErrorNamesItsLine(toml: String, problem: String) {
        #expect(failure(toml) == SettingsError(problem: problem))
    }
    @Test func aLoadErrorNamesTheFile() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recorder.toml")
        try Data("retention_days = 0\n".utf8).write(to: url)
        #expect(throws: SettingsError(file: url.path, field: "retention_days", problem: "must be a whole number of days, 1 or more")) { try Settings.load(url) }
        #expect("\(SettingsError(file: url.path, field: "retention_days", problem: "must be a whole number of days, 1 or more"))"
                == "\(url.path): retention_days must be a whole number of days, 1 or more")
    }
}

struct SettingsUseTests {
    @Test func theOutboxSendsToTheSettingsHostAndStorageRoot() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root, test: true)
        let command = Outbox.remoteCommand(paths: paths, mini: Mini(host: "studio", root: "/srv/meetings/"), "live-meeting-done", ["sid", "4"], timeout: 60)
        #expect(command.arguments.suffix(2) == ["studio", "LML_ROOT=\"/srv/meetings-test\" live-meeting-done sid 4"])
        let home = Outbox.remoteCommand(paths: paths, mini: Mini(host: "studio"), "live-meeting-done", ["sid", "4"], timeout: 60)
        #expect(home.arguments.last == "LML_ROOT=\"$HOME/.local/state/live-meeting-test\" live-meeting-done sid 4")
        let live = Outbox.remoteCommand(paths: SessionPaths(root: root), mini: Mini(host: "studio"), "live-meeting-done", ["sid", "4"], timeout: 60)
        #expect(live.arguments.suffix(4) == ["studio", "live-meeting-done", "sid", "4"])
    }
    @Test func aChangedSshHostInTheFileIsTheHostTheOutboxTargetsAndKeepsItsOwnConnection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root)
        let before = try #require(try Settings(toml: "ssh_host = \"mini\"\n").mini)
        let after = try #require(try Settings(toml: "ssh_host = \"studio\"\nstorage_root = \"/srv/meetings\"\n").mini)
        let old = Outbox.remoteCommand(paths: paths, mini: before, "live-meeting-done", ["sid", "4"], timeout: 60)
        let new = Outbox.remoteCommand(paths: paths, mini: after, "live-meeting-done", ["sid", "4"], timeout: 60)
        #expect(old.arguments.suffix(4) == ["mini", "live-meeting-done", "sid", "4"])
        #expect(new.arguments.suffix(4) == ["studio", "live-meeting-done", "sid", "4"])
        #expect(old.arguments.contains("ControlPath=\"\(root.path)/ssh-mini\""))
        #expect(new.arguments.contains("ControlPath=\"\(root.path)/ssh-studio\""))
        #expect(after.shellRoot(test: true) == "/srv/meetings-test")
    }
    @Test func withoutAMiniTheOutboxSendsNothingAndAskFails() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root)
        let directory = paths.session("20261013-190012-a3f1")
        try PrivateFiles.directory(directory)
        var meta = SessionMeta(sid: "20261013-190012-a3f1", started_at: epoch); meta.state = .closed; meta.ended_at = epoch
        try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json"))
        try PrivateFiles.write(Data("a\n".utf8), to: directory.appendingPathComponent("transcript.jsonl"))
        let runner = StubRunner([])
        let outbox = Outbox(paths: paths, mini: nil, runner: runner)
        let heartbeat = Heartbeat(at: epoch, app_version: "test", state: .idle, sid: nil, mic_ok: true, audio_ok: true)
        try await outbox.tick(at: epoch, heartbeat: heartbeat)
        try await outbox.forget("20261013-190012-a3f1", at: epoch)
        try await outbox.tick(at: epoch)
        #expect(await runner.recorded().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: RecorderError(reply: "no_mini")) { _ = try await ControlActions(paths: paths, mini: nil, runner: runner).ask("anything") }
    }
    @Test func theDetectorWatchesOnlyTheListedApps() {
        var detector = Detector(ownPID: 1, clients: MeetingClients(prefixes: ["com.apple.FaceTime"]))
        let zoom = ProcessRow(bundle: "us.zoom.xos", input: true, pid: 4)
        let faceTime = ProcessRow(bundle: "com.apple.FaceTime", input: true, pid: 5)
        #expect(detector.update(ProcessSnapshot(procs: [zoom], ts: epoch), schedule: nil) == nil)
        #expect(detector.update(ProcessSnapshot(procs: [faceTime], ts: epoch), schedule: nil) == .arm)
        #expect(MeetingClients().allowed("us.zoom.xos"))
    }
    @Test func aMicOnlyAppRecordsOnlyWhenItIsListed() throws {
        let helper = ProcessSnapshot(procs: [ProcessRow(bundle: "com.granola.app.helper", input: true, pid: 6)], ts: epoch)
        var listed = Detector(ownPID: 1, clients: MeetingClients(prefixes: []))
        #expect(listed.update(helper, schedule: nil) == .arm)
        var unlisted = Detector(ownPID: 1, clients: MeetingClients(prefixes: [], micPrefixes: []))
        #expect(unlisted.update(helper, schedule: nil) == nil)
        #expect(try Settings(toml: "mic_apps = []\n").micApps.isEmpty)
        #expect(try Settings(toml: "meeting_apps = []\n").micApps == ["com.granola.app.helper"])
    }
    @Test func theMicOrderPicksTheFirstFragmentThatMatches() {
        let names = ["MacBook Pro Microphone", "Ari's AirPods Pro", "Shure MV7"]
        #expect(MicOrder.pick(names, order: ["Shure", "AirPods"]) == 2)
        #expect(MicOrder.pick(names, order: ["airpods", "Shure"]) == 1)
        #expect(MicOrder.pick(names, order: ["Yeti"]) == nil)
        #expect(MicOrder.pick(names, order: []) == nil)
    }

    @Test func theMicSwitchGuardPausesAfterTooManySwitchesBack() {
        var guard_ = MicSwitchGuard(limit: 3, window: 10, pause: 60)
        #expect([0.0, 1, 2].map { guard_.verdict(at: $0) } == [.switchBack, .switchBack, .switchBack])
        #expect(guard_.verdict(at: 3) == .pauseStarted)
        #expect(guard_.verdict(at: 62) == .paused)
        #expect(guard_.verdict(at: 63) == .switchBack, "the pause ends 60 s after it began")
    }

    @Test func theMicSwitchGuardForgetsSwitchesOutsideTheWindow() {
        var guard_ = MicSwitchGuard(limit: 3, window: 10, pause: 60)
        #expect([0.0, 5, 10.5, 15.5, 21].map { guard_.verdict(at: $0) } == Array(repeating: .switchBack, count: 5))
    }
}
