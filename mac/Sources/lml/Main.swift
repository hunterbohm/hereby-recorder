import AppKit
import AVFoundation
import Speech
import Foundation
import LMLCore
import LMLPanel
import Darwin

struct UsageError: Error {}

@main struct LML {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        Task { @MainActor in
            let code = await outcome(args)
            PanelHost.finish()
            exit(code)
        }
        if args.first == "run" {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                NSApplication.shared.run()
            }
        }
        dispatchMain()
    }
    @MainActor static func presentPanel(model: any RecorderModel, actions: any RecorderActions, settings: Settings) {
        PanelHost.start(model: model, actions: actions, hasMini: settings.mini != nil, overlay: OverlayOptions(settings))
    }
    @MainActor static func outcome(_ args: [String]) async -> Int32 {
        do { try await execute(args); return 0 }
        catch is UsageError {
            FileHandle.standardError.write(Data("usage: lml run [--test] [--duration seconds] [--stall-after seconds] [--them-file wav] [--me-file wav] | start [--in-person] | stop | mark [note] | status | capabilities | ping | doctor | config system-audio tap|sck | request-permissions | transcribe-file wav [--ch me|them|room] [--vocabulary term,term] | label-speakers wav [--speakers n] | pause | resume | forget sid\n".utf8)); return 2
        } catch let error as SettingsError {
            FileHandle.standardError.write(Data("lml: \(error)\n".utf8)); return 1
        } catch let error as SurvivingProcesses {
            FileHandle.standardError.write(Data("forget_failed surviving_pids=\(error.pids.map(String.init).joined(separator: ","))\n".utf8)); return 1
        } catch {
            let ns = error as NSError, code = ns.code
            FileHandle.standardError.write(Data("lml_failed domain=\(ns.domain) code=\(code)\n".utf8)); return 1
        }
    }
    @MainActor static func execute(_ args: [String]) async throws {
        guard let action = args.first else { throw UsageError() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/live-meeting/config.json")
        let settingsURL = Settings.url()
        switch action {
        case "run":
            let options = try parseRun(Array(args.dropFirst()))
            let paths = options.root.map { SessionPaths(root: $0, test: options.test) } ?? SessionPaths(test: options.test)
            let recorder = try settings(settingsURL)
            let listener = Listener(paths: paths, options: options, configURL: options.root?.appendingPathComponent("config.json") ?? configURL,
                                    settings: recorder)
            defer { withExtendedLifetime(listener) {} }
            try await listener.run(whenReady: options.test ? {} : {
                presentPanel(model: listener.store, actions: listener.actions, settings: recorder)
            })
        case "mark":
            let note = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let paths = SessionPaths()
            print(try await ControlClient.request(ControlCommand(action: .mark, note: note.isEmpty ? nil : note), root: paths.root))
        case "start", "stop", "pause", "resume", "forget":
            let forget = action == "forget"
            let inPerson = action == "start" && args.count == 2 && args[1] == "--in-person"
            guard args.count == (forget ? 2 : 1) || inPerson, !forget || SessionPaths.validID(args[1]) else { throw UsageError() }
            let paths = SessionPaths()
            try PrivateFiles.directory(paths.root)
            let command = ControlCommand(action: ControlCommand.Action(rawValue: action)!, sid: forget ? args[1] : nil, kind: inPerson ? .inPerson : nil)
            if !forget {
                print(try await ControlClient.request(command, root: paths.root)); return
            }
            let sid = args[1]
            let outbox = Outbox(paths: paths, mini: try settings(settingsURL).mini)
            let fd = open(paths.root.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let metaURL = paths.session(sid).appendingPathComponent("meta.json")
            if (try? JSON.read(SessionMeta.self, from: metaURL).state) == .active {
                var pause = PauseStore(root: paths.root)
                try pause.set(reason: .forget, at: Date())
            }
            try await outbox.recordForget(sid, at: Date())
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try await outbox.forget(sid, at: Date())
            } else {
                let deadline = Date().addingTimeInterval(10)
                let reply = try? await ControlClient.request(command, root: paths.root)
                if reply != "forgotten" {
                    if deadline > Date() { try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow)) }
                    try await UnresponsiveForget.perform(
                        launchKill: {
                            try await LocalProcessRunner().run(ProcessCommand("/bin/launchctl", ["kill", "SIGKILL", "gui/\(getuid())/sh.hereby.recorder"], timeout: 10)).status == 0
                        },
                        readIdentity: { try JSON.read(AgentIdentity.self, from: paths.root.appendingPathComponent("agent.pid")) },
                        killGroup: { pgid in
                            guard kill(-pgid, SIGKILL) == 0 || errno == ESRCH else { throw POSIXError(.EPERM) }
                        },
                        survivingPIDs: { try groupMembers($0) },
                        wait: { try await Task.sleep(for: .milliseconds(100)) },
                        deleteSession: { try await outbox.deleteSession(sid) })
                }
            }
            try await outbox.tick(at: Date(), pushSessions: false)
            print("forgotten")
        case "capabilities":
            guard args.count == 1 else { throw UsageError() }
            print("control-actions \(ControlCommand.Action.allCases.map(\.rawValue).joined(separator: " "))")
        case "ping":
            guard args.count == 1 else { throw UsageError() }
            print(ControlCommand.pingReply(pid: try await ControlClient.ping(root: SessionPaths().root)))
        case "status":
            guard args.count == 1 else { throw UsageError() }
            try status(paths: SessionPaths())
        case "config":
            guard args.count == 3, args[1] == "system-audio", let backend = Config.Backend(rawValue: args[2]) else { throw UsageError() }
            var config = FileManager.default.fileExists(atPath: configURL.path) ? try JSON.read(Config.self, from: configURL) : Config()
            config.system_audio = backend
            try PrivateFiles.directory(configURL.deletingLastPathComponent()); try PrivateFiles.write(config, to: configURL)
            print("system-audio \(backend.rawValue)")
        case "doctor":
            guard args.count == 1 else { throw UsageError() }
            try await doctor(configURL: configURL, settings: try settings(settingsURL), settingsURL: settingsURL)
        case "request-permissions":
            guard args.count == 1 else { throw UsageError() }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("microphone \(granted ? "granted" : "denied")")
            let config = FileManager.default.fileExists(atPath: configURL.path) ? try JSON.read(Config.self, from: configURL) : Config()
            let source: any SystemAudioSource = config.system_audio == .tap ? TapSource(clock: CaptureClock(), sink: { _ in }) : SCKSource(clock: CaptureClock(), sink: { _ in })
            try await source.start(); try await Task.sleep(for: .seconds(2)); await source.stop()
            print("\(config.system_audio.rawValue) permission request complete; run doctor while output is active")
        case "transcribe-file":
            guard args.count >= 2, args.count % 2 == 0 else { throw UsageError() }
            var channel = Channel.them, vocabulary: [String] = []
            for index in stride(from: 2, to: args.count, by: 2) {
                switch args[index] {
                case "--ch": guard let value = Channel(rawValue: args[index + 1]) else { throw UsageError() }; channel = value
                case "--vocabulary": vocabulary = args[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                default: throw UsageError()
                }
            }
            let writer = SessionWriter(sid: SessionPaths.id(at: Date()), startedAt: Date(), directory: nil, test: true, kind: channel == .room ? .inPerson : .call)
            let transcriber = AppleTranscriber(channel: channel, writer: writer, printFinals: true, vocabulary: vocabulary)
            let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
            let producer = Task {
                defer { continuation.finish() }
                try await injectFile(args[1], clock: CaptureClock()) { continuation.yield(.chunk($0)) }
            }
            do { try await transcriber.run(stream); try await producer.value }
            catch { producer.cancel(); _ = await producer.result; throw error }
        case "label-speakers":
            guard args.count == 2 || (args.count == 4 && args[2] == "--speakers"), let expected = args.count == 4 ? Int(args[3]) : 0 else { throw UsageError() }
            let start = Date(timeIntervalSince1970: 0)
            let turns = try await SpeakerLabeler.label(URL(fileURLWithPath: args[1]), start: start, expected: expected > 0 ? expected : nil)
            for turn in turns.turns {
                print(String(format: "%7.2f %7.2f  speaker %d", turn.t0.timeIntervalSince(start), turn.t1.timeIntervalSince(start), turn.speaker))
            }
        default: throw UsageError()
        }
    }
    /// The settings in `url`, or the defaults, which keep meetings on this Mac, with a note on where the file goes.
    static func settings(_ url: URL) throws -> Settings {
        let settings = try Settings.load(url)
        if settings?.sshHost == nil {
            let missing = settings == nil ? "no settings at \(url.path)" : "no ssh_host in \(url.path)"
            FileHandle.standardError.write(Data("lml: \(missing), so meetings stay on this Mac. Set ssh_host there to sync them to another computer.\n".utf8))
        }
        return settings ?? Settings()
    }
    static func groupMembers(_ identity: AgentIdentity) throws -> [Int32] {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pgid="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            guard columns.count == 2, columns[0] == identity.pid || columns[1] == identity.pgid else { return nil }
            return columns[0]
        }
    }
    static func parseRun(_ arguments: [String]) throws -> RunOptions {
        var options = RunOptions(); var index = 0
        while index < arguments.count {
            let flag = arguments[index]; index += 1
            switch flag {
            case "--test": options.test = true
            case "--no-control": options.noControl = true
            case "--no-sync": options.noSync = true
            case "--force-mic": options.forceMic = true
            case "--duration", "--stall-after", "--them-file", "--me-file", "--root":
                guard index < arguments.count else { throw UsageError() }
                let value = arguments[index]; index += 1
                switch flag {
                case "--duration":
                    guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { throw UsageError() }; options.duration = seconds
                case "--stall-after":
                    guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else { throw UsageError() }; options.stallAfter = seconds
                case "--them-file": options.themFile = value
                case "--me-file": options.meFile = value
                default: options.root = URL(fileURLWithPath: value)
                }
            default: throw UsageError()
            }
        }
        guard (!options.forceMic && options.root == nil && !options.noSync && !options.noControl && options.stallAfter == nil) || options.test else { throw UsageError() }
        return options
    }
    static func status(paths: SessionPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.sessions.path) else { print("idle"); return }
        var sessions: [SessionMeta] = []
        for directory in try FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil) where SessionPaths.validID(directory.lastPathComponent) {
            sessions.append(try JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json")))
        }
        guard let latest = sessions.max(by: { $0.started_at < $1.started_at }) else { print("idle"); return }
        let state = latest.state == .active && Date().timeIntervalSince(latest.heartbeat_at) >= 30 ? "stale" : latest.state.rawValue
        print("\(latest.sid) \(state) segments=\(latest.segments) me=\(latest.me) warnings=\(latest.warnings.joined(separator: ","))")
    }
    @MainActor static func doctor(configURL: URL, settings: Settings, settingsURL: URL) async throws {
        let config = FileManager.default.fileExists(atPath: configURL.path) ? try JSON.read(Config.self, from: configURL) : Config()
        print("settings \(settingsURL.path)")
        print("config system_audio=\(config.system_audio.rawValue) retention_days=\(settings.retentionDays)")
        print("microphone authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let assets = await AssetInventory.status(forModules: [transcriber])
        print("speech assets=\(assets)")
        let meter = PeakMeter(); let monitor = ProcessMonitor()
        let clients = MeetingClients(prefixes: settings.meetingApps, micPrefixes: settings.micApps)
        let runningOutput = await monitor.read().snapshot.procs.contains { $0.pid != getpid() && $0.output && clients.allowed($0.bundle) }
        let tap = TapSource(clock: CaptureClock()) { meter.add($0.samples) }
        do {
            try await tap.start(); try await Task.sleep(for: .seconds(2)); await tap.stop()
            let (peak, count) = meter.take()
            print("tap \(peak > 0 ? "nonzero" : (runningOutput && count > 0 ? "them_silent" : "inconclusive_no_output_or_samples")) samples=\(count)")
        } catch { await tap.stop(); print("tap probe_failed") }
        let paths = SessionPaths(); try PrivateFiles.directory(paths.root)
        if let mini = settings.mini {
            let output = try await LocalProcessRunner().run(Outbox.remoteCommand(paths: paths, mini: mini, "true", [], timeout: 20))
            print("mini \(output.status == 0 ? "reachable" : "unreachable")")
        } else {
            print("sync none, meetings stay on this Mac")
        }
        try status(paths: paths)
    }
}
