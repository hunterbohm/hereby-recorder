import AVFoundation
import Foundation
import LMLCore
import Darwin
import os

struct RunOptions {
    var test = false
    var duration: Double?
    var meFile: String?
    var themFile: String?
    var forceMic = false
    var noSync = false
    var noControl = false
    var root: URL?
    var stallAfter: Double?
}

@MainActor final class CaptureSession {
    let writer: SessionWriter
    let kind: CaptureKind
    let startedAt: Date
    private let options: RunOptions
    private let monitor: ProcessMonitor
    private let clock = CaptureClock()
    private let streams: [Channel: AsyncStream<CaptureEvent>.Continuation]
    private let energy: AsyncStream<(Channel, CaptureEvent)>.Continuation
    private let micMeter = PeakMeter()
    private var energyTask: Task<Void, Never>?
    private var source: (any SystemAudioSource)?
    private var mic: (any MicrophoneSource)?
    private var consumers: [Task<Void, Error>] = []
    private var files: [Task<Void, Error>] = []
    private var active = true
    private var silence = SilenceGuard()
    private var micSilence = SilenceGuard()
    private var meter: PeakMeter?
    private var vocabulary: [String] = []
    private let recording: ThemRecording?
    private let clients: MeetingClients
    private(set) var failure = false
    private(set) var micRetry = MicRetry()
    /// The mic that failed to start twice in a row this session; capture uses the built-in mic in its place.
    private var replacedMic: AudioDeviceID?
    /// The mic `micRetry` counts failures for; a different mic starts with a fresh count.
    private var retriedMic: AudioDeviceID?
    /// The open mic and the device it stands in for, so a mic that goes quiet can fall back like one that fails.
    private var openMic: (device: AudioDeviceID, chosen: AudioDeviceID, builtIn: AudioDeviceID?)?
    private var micDelivered = 0
    private var micQuietSince: Date?
    private var micStalls = 0
    /// When the mic stopped giving audio: a failed start or a stall. Cleared when audio arrives or no mic is wanted.
    private var micDownSince: Date?
    private(set) var micDown = false
    static let fallbackAfterFailures = 2
    static let micStallAfter: TimeInterval = 5
    static let micDownAfter: TimeInterval = 30
    var systemAudioSilent: Bool { silence.warning }
    var micSilent: Bool { micSilence.warning }
    init(writer: SessionWriter, startedAt: Date, options: RunOptions, monitor: ProcessMonitor, clients: MeetingClients, backend: Config.Backend, audio: URL?, microphone: (any MicrophoneSource)? = nil, transcriber: (any Transcriber)? = nil) {
        self.writer = writer; kind = writer.kind; self.startedAt = startedAt; self.options = options; self.monitor = monitor; self.clients = clients
        let recording = writer.kind == .call ? audio.map(ThemRecording.init) : nil
        self.recording = recording
        var continuations: [Channel: AsyncStream<CaptureEvent>.Continuation] = [:]
        var inputs: [(Channel, AsyncStream<CaptureEvent>)] = []
        for channel in Channel.channels(for: writer.kind) {
            let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
            continuations[channel] = continuation; inputs.append((channel, stream))
        }
        streams = continuations
        let (energyStream, energyContinuation) = AsyncStream.makeStream(of: (Channel, CaptureEvent).self)
        energy = energyContinuation
        energyTask = Task {
            for await (channel, event) in energyStream {
                if case .chunk(let chunk) = event {
                    await writer.addEnergy(channel: channel, samples: chunk.samples, sampleRate: chunk.sampleRate, at: chunk.at)
                    if channel == .them { await recording?.append(chunk) }
                }
                continuations[channel]?.yield(event)
            }
        }
        for (channel, stream) in inputs {
            let transcriber = transcriber ?? AppleTranscriber(channel: channel, writer: writer, downloadAssets: !options.noSync)
            consumers.append(Task { [weak self] in
                do { try await transcriber.run(stream) }
                catch { self?.failure = true; throw error }
            })
        }
        let voice: Channel = writer.kind == .call ? .me : .room
        if writer.kind == .call {
            let meter = PeakMeter(); self.meter = meter
            let themSink: @Sendable (AudioChunk) -> Void = { chunk in meter.add(chunk.samples); energyContinuation.yield((.them, .chunk(chunk))) }
            if options.themFile == nil { source = backend == .tap ? TapSource(clock: clock, sink: themSink) : SCKSource(clock: clock, sink: themSink) }
            if let path = options.themFile {
                let clock = clock
                files.append(Task { [weak self] in
                    do { try await injectFile(path, clock: clock, sink: themSink) }
                    catch is CancellationError {} catch { self?.failure = true; throw error }
                })
            }
        }
        let micMeter = micMeter
        if options.meFile == nil {
            if let microphone { mic = microphone }
            else {
                let source = MicSource(clock: clock) { chunk in micMeter.add(chunk.samples); energyContinuation.yield((voice, .chunk(chunk))) }
                source.onRunEnd = { energyContinuation.yield((voice, .endRun)) }
                source.onConfigurationChange = { [weak self] in Task { await self?.refreshMic(restart: true) } }
                mic = source
            }
        }
        if let path = options.meFile {
            let clock = clock
            files.append(Task { [weak self] in
                do { try await injectFile(path, clock: clock) { micMeter.add($0.samples); energyContinuation.yield((voice, .chunk($0))) } }
                catch is CancellationError {} catch { self?.failure = true; throw error }
            })
        }
    }
    func start() async throws {
        await refreshMic()
        try await source?.start()
    }
    func refreshMic(restart: Bool = false) async {
        guard active, mic != nil else { return }
        refreshMic(await monitor.read(), restart: restart)
    }
    func refreshMic(_ state: AudioState, restart: Bool = false) {
        guard active, let mic else { return }
        let snapshot = state.snapshot, defaultInput = state.defaultInput
        let required = options.forceMic || kind == .inPerson
        let chosen = required ? (defaultInput == 0 ? nil : defaultInput) :
            MicDeviceSelector(ownPID: getpid(), clients: clients).eligible(snapshot, defaultInput: defaultInput)
        // A call whose meeting app holds no mic needs none; an in-person recording with no input device is down.
        guard let chosen else { mic.stop(); openMic = nil; micDownSince = required ? (micDownSince ?? snapshot.ts) : nil; return }
        let builtIn = state.builtInInput.flatMap { $0 == chosen ? nil : $0 }
        let device = replacedMic == chosen ? (builtIn ?? chosen) : chosen
        let now = snapshot.ts
        if retriedMic != device { micRetry = MicRetry(); retriedMic = device; micStalls = 0 }
        guard micRetry.allows(at: now) else { return }
        let reopens = restart || openMic?.device != device || !mic.isOpen
        // A new mic run must prove itself again: one that gives only zeros warns even after earlier speech. The old
        // run is stopped before the meter is drained and the new run starts, so neither run's samples cross over.
        if reopens { mic.stop(); _ = micMeter.take(); micSilence = SilenceGuard() }
        do { try mic.start(on: device, restart: restart); micRetry.succeeded(); openMic = (device, chosen, builtIn) }
        catch {
            mic.stop(); openMic = nil; micDownSince = micDownSince ?? now
            let at = micRetry.failed(at: now)
            if device == chosen, let builtIn, micRetry.failures >= Self.fallbackAfterFailures {
                replacedMic = chosen; micRetry.succeeded()
                FileHandle.standardError.write(Data("mic_fallback from=\(chosen) to=\(builtIn) error=\(error)\n".utf8))
                refreshMic(state, restart: restart)
                return
            }
            let line = "mic_start_failed attempt=\(micRetry.failures) device=\(device) retry_in=\(at.timeIntervalSince(now))s error=\(error)"
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
    /// An open mic whose device stops delivering audio (IO stopped, a wedged driver) restarts after 5 s, and after
    /// two stalls in a row it falls back to the built-in mic, as a mic that will not start does.
    func checkMicFlow(_ state: AudioState) {
        let now = state.snapshot.ts
        defer { micDown = micDownSince.map { now.timeIntervalSince($0) >= Self.micDownAfter } ?? false }
        guard active, let mic, mic.isOpen, let current = openMic else { micQuietSince = nil; return }
        let delivered = mic.delivered
        if delivered != micDelivered { micDelivered = delivered; micQuietSince = nil; micStalls = 0; micDownSince = nil; return }
        let since = micQuietSince ?? now; micQuietSince = since
        guard now.timeIntervalSince(since) >= Self.micStallAfter else { return }
        micQuietSince = nil; micStalls += 1; micDownSince = micDownSince ?? since
        FileHandle.standardError.write(Data("mic_stalled device=\(current.device) stalls=\(micStalls)\n".utf8))
        if current.device == current.chosen, let builtIn = current.builtIn, micStalls >= Self.fallbackAfterFailures {
            replacedMic = current.chosen
            FileHandle.standardError.write(Data("mic_fallback from=\(current.chosen) to=\(builtIn) error=stalled\n".utf8))
        }
        refreshMic(state, restart: true)
    }
    func tick(_ state: AudioState, schedule: Schedule?) async throws {
        refreshMic(state)
        checkMicFlow(state)
        let snapshot = state.snapshot
        let (peak, count) = meter?.take() ?? (0, 0)
        let external = snapshot.procs.filter { $0.pid != getpid() }
        let output = external.contains { clients.allowed($0.bundle) && $0.output }
        silence.update(peak: peak, sampleCount: count, outputRunning: output, at: snapshot.ts)
        let (micPeak, micCount) = micMeter.take()
        micSilence.update(peak: micPeak, sampleCount: micCount, outputRunning: mic?.isOpen == true || options.meFile != nil, at: snapshot.ts)
        let terms = schedule?.vocabulary(at: snapshot.ts) ?? []
        if terms != vocabulary {
            vocabulary = terms
            for continuation in streams.values { continuation.yield(.context(terms)) }
        }
        await writer.setSchedule(schedule)
        await writer.setContext(apps: clients.callApps(snapshot, ownPID: getpid()),
            calKeys: schedule?.current(at: snapshot.ts).map(\.key) ?? [], micOpen: mic?.isOpen == true || options.meFile != nil, silent: silence.warning)
        try await writer.publish(at: snapshot.ts)
    }
    /// True while the call is held: the mic and system audio are stopped, and the analyzers and the call's audio
    /// file stay open in case the same call comes back.
    private(set) var suspended = false
    func suspend() async {
        guard !suspended else { return }
        suspended = true; active = false
        mic?.stop(); openMic = nil; micQuietSince = nil; micDownSince = nil; micDown = false; micSilence = SilenceGuard(); silence = SilenceGuard()
        await source?.stop()
    }
    /// Listens again after a hold. A mic that will not open is retried and reported as during any call; a system
    /// audio source that will not start throws, and the caller files the held call.
    func resume() async throws {
        guard suspended else { return }
        suspended = false; active = true
        await refreshMic()
        try await source?.start()
    }
    func stopSources() async {
        active = false; mic?.dispose(); await source?.stop(); source = nil
        for file in files { file.cancel() }
        for file in files { _ = await file.result }
    }
    func finishAnalyzers(discard: Bool) async throws {
        if discard { for consumer in consumers { consumer.cancel() } }
        energy.finish(); await energyTask?.value
        for continuation in streams.values { continuation.finish() }
        var failed = false
        for consumer in consumers { if case .failure = await consumer.result, !discard { failed = true } }
        if failed { throw NSError(domain: "lml.asr.failed", code: 1) }
    }
    func stop(discard: Bool = false) async throws {
        await stopSources()
        try await finishAnalyzers(discard: discard)
    }
    /// The finished call audio and its first sample's time, for labeling speakers.
    func themAudio() async -> (url: URL, start: Date)? {
        guard let recording, let start = await recording.finish() else { return nil }
        return (recording.url, start)
    }
    func deleteAudio() async { await recording?.delete() }
}

/// Fed from the audio IO thread, so it holds an unfair lock for a few instructions and never blocks on a waiter.
final class PeakMeter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (peak: Float(0), count: 0))
    func add(_ samples: [Float]) {
        let highest = samples.reduce(Float(0)) { max($0, abs($1)) }
        state.withLock { $0 = (max($0.peak, highest), $0.count + samples.count) }
    }
    func take() -> (Float, Int) {
        state.withLock { current in defer { current = (0, 0) }; return current }
    }
}

/// Why automatic capture is held off. A stop or forget holds until the meeting ends; a failed capture re-arms
/// after a short wait, so one failure costs seconds of a call instead of the rest of it.
enum Suppression: Equatable {
    static let rearmAfterFailure: TimeInterval = 30
    case off, untilMeetingEnds, until(Date)
    func lifts(at now: Date, meetingSignal: Bool) -> Bool {
        switch self {
        case .off: false
        case .untilMeetingEnds: !meetingSignal
        case .until(let at): !meetingSignal || now >= at
        }
    }
}

/// Whether the meeting is still on for a hold: its signal must stay gone 2 minutes, the wait a pause uses, so one
/// flicker (a headset reconnecting) does not end a Stop's hold and restart recording mid-call.
struct MeetingPresence {
    static let endedAfter: TimeInterval = 120
    private var lostAt: Date?
    mutating func isOn(signal: Bool, at now: Date) -> Bool {
        if signal { lostAt = nil; return true }
        let since = lostAt ?? now; lostAt = since
        return now.timeIntervalSince(since) < Self.endedAfter
    }
}

@MainActor final class Listener {
    static let endedPhase: TimeInterval = 1800
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    let store = RecorderStore()
    private let paths: SessionPaths
    private let options: RunOptions
    private let configURL: URL
    private let config: Config
    private let settings: Settings
    private let monitor = ProcessMonitor()
    private let watch = LoopWatch(limit: 60)
    private let outbox: Outbox
    private var detector: Detector
    /// The capture, or the held call while `hold` is set. A new capture, or none, ends the hold.
    private var capture: CaptureSession? { didSet { if capture !== oldValue { hold = nil } } }
    /// Set from the moment a detected call's signal goes away until it comes back and records again, or files.
    private var hold: CallHold?
    private var schedule: Schedule?
    private var pause: PauseStore
    private var control: ControlServer?
    private var manual = false
    private var suppression = Suppression.off
    private var presence = MeetingPresence()
    private var lastPurge: Date?
    private var lockFD: Int32 = -1
    private var stopping = false
    private var signalSources: [DispatchSourceSignal] = []
    private var lastEnded: (sid: String, kind: CaptureKind, at: Date)?
    private var lastForgotten: String?
    private var permissionsCheckedAt: Date?
    private var permissions: (mic: Bool, audio: Bool?) = (true, nil)
    private var labeling: [String: (task: Task<Void, Never>, writer: SessionWriter)] = [:]
    private let idleSleep = IdleSleepGuard()
    private var sleepWatcher: SleepWatcher?
    init(paths: SessionPaths, options: RunOptions, configURL: URL, settings: Settings) {
        self.paths = paths; self.options = options; self.configURL = configURL; self.settings = settings
        config = (try? Config.load(configURL)) ?? Config()
        outbox = Outbox(paths: paths, mini: settings.mini, done: settings.mini == nil ? Self.doneCommand(settings) : nil, onHandoff: Self.announce, interval: config.sync_interval_s)
        detector = Detector(ownPID: getpid(), clients: MeetingClients(prefixes: settings.meetingApps, micPrefixes: settings.micApps))
        pause = PauseStore(root: paths.root)
    }
    var actions: ControlActions { ControlActions(paths: paths, mini: settings.mini, screenContext: settings.screenContext) }
    /// What a finished meeting runs when it stays on this Mac. Nil, with a note, when the setting is unreadable or no handoff script is installed.
    private static func doneCommand(_ settings: Settings) -> DoneCommand? {
        do {
            if let command = try DoneCommand.resolve(settings, executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) { return command }
            FileHandle.standardError.write(Data("handoff_unavailable: no \(DoneCommand.handoffName) found beside this app, so finished meetings wait\n".utf8))
        } catch { FileHandle.standardError.write(Data("handoff_unavailable: \(error)\n".utf8)) }
        return nil
    }
    func run(whenReady: () -> Void = {}) async throws {
        try PrivateFiles.directory(paths.root); try PrivateFiles.directory(paths.sessions)
        lockFD = open(paths.root.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "lml.already_running", code: 1) }
        defer {
            control = nil
            sleepWatcher?.invalidate(); sleepWatcher = nil; idleSleep.hold(false)
            try? FileManager.default.removeItem(at: paths.root.appendingPathComponent("agent.pid"))
            monitor.stop()
            for source in signalSources { source.cancel() }
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
        }
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        guard getpgrp() == getpid() || setpgid(0, 0) == 0 else { throw POSIXError(.EPERM) }
        try PrivateFiles.write(AgentIdentity(pid: getpid(), pgid: getpgrp()), to: paths.root.appendingPathComponent("agent.pid"))
        if !options.noControl { control = try ControlServer(root: paths.root) }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.stopping = true } }
            source.resume(); signalSources.append(source)
        }
        try pause.migrateLegacy(at: Date())
        try await outbox.recover()
        try? FileManager.default.removeItem(at: paths.audio)
        monitor.observe { [weak self] state, restart in Task { @MainActor in self?.capture?.refreshMic(state, restart: restart) } }
        if !options.test { sleepWatcher = SleepWatcher { [weak self] in await self?.prepareForSleep() } }
        whenReady()
        let syncTask = Task { [outbox, options, store, weak self] in
            guard !options.noSync else { return }
            while !Task.isCancelled {
                let heartbeat = Heartbeat(at: Date(), appVersion: Self.appVersion, snapshot: store.snapshot)
                do {
                    let report = try await outbox.tick(at: Date(), heartbeat: heartbeat)
                    if let receipt = report.receipt {
                        store.update { snapshot in
                            snapshot.feedReceivedAt = receipt.at
                            if let feed = receipt.feed { snapshot.feed = feed }
                        }
                    }
                    await self?.handleForgotten(report)
                } catch { FileHandle.standardError.write(Data("outbox_failed\n".utf8)) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { syncTask.cancel() }
        let started = Date()
        StallGuard.start(watch, directory: options.root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LiveMeetingListener"))
        do {
            if options.test && !pause.isPaused { try await begin(at: started, forced: true, kind: .call) }
            while !stopping {
                let now = Date()
                if let duration = options.duration, now.timeIntervalSince(started) >= duration { break }
                let scheduleURL = paths.root.appendingPathComponent("schedule.json")
                if FileManager.default.fileExists(atPath: scheduleURL.path) {
                    schedule = try? JSON.read(Schedule.self, from: scheduleURL)
                }
                watch.enter("controls")
                try await controls()
                watch.enter("detect")
                let state = await monitor.read()
                let snapshot = state.snapshot
                let signal = detector.signal(snapshot, schedule: schedule)
                let meetingOn = presence.isOn(signal: signal, at: snapshot.ts)
                if try pause.observe(meetingSignal: signal, at: snapshot.ts) {
                    detector.reset(); suppression = .off
                }
                do {
                    // A held call files once its wait is over, or as soon as a different call starts.
                    if let hold, capture?.suspended == true, hold.expired(at: now) || (signal && !hold.continues(
                        apps: detector.clients.callApps(snapshot, ownPID: detector.ownPID),
                        calKeys: schedule?.current(at: snapshot.ts).map(\.key) ?? [])) {
                        watch.enter("file_held")
                        try await end(at: now, discard: false)
                    }
                    if !options.test && !pause.isPaused && !manual {
                        if suppression.lifts(at: now, meetingSignal: meetingOn) { suppression = .off }
                        if suppression == .off {
                            let transition = detector.update(snapshot, schedule: schedule)
                            if let transition { watch.enter(String(describing: transition)) }
                            switch transition {
                            case .arm:
                                if let capture, capture.suspended { try await resumeHeld(capture, at: now) }
                                else { try await begin(at: snapshot.ts, forced: false, kind: .call) }
                            case .activate: hold = nil; try await capture?.writer.activate(at: now)
                            case .discard:
                                // A held call that came back for under 10 s goes back to waiting; its transcript stays.
                                if hold != nil, let capture { await capture.suspend() } else { try await end(at: now, discard: true) }
                            case .close: try await holdCall(at: now)
                            default: break
                            }
                        }
                    }
                    watch.enter("capture")
                    if options.test, let after = options.stallAfter, now.timeIntervalSince(started) >= after { sleep(600) }
                    if capture?.suspended != true { try await capture?.tick(state, schedule: schedule) }
                    if capture?.failure == true { throw NSError(domain: "lml.capture.failed", code: 1) }
                    if let capture, capture.kind == .inPerson, await capture.writer.silence(at: now) >= config.in_person_silence_s {
                        try await end(at: now, discard: false)
                    }
                } catch { await failCapture(at: now) }
                watch.enter("purge")
                if lastPurge == nil || now.timeIntervalSince(lastPurge!) >= 86400 {
                    let days = Retention.days(settings.retentionDays, schedule: schedule)
                    for sid in try Retention.expired(in: paths, days: days, now: now) { try await outbox.forget(sid, at: now) }
                    lastPurge = now
                }
                watch.enter("publish")
                await publish(at: now)
                watch.enter("idle")
                try await Task.sleep(for: .seconds(1))
            }
            watch.enter("shutdown")
            try await end(at: Date(), discard: false)
        } catch {
            watch.enter("shutdown")
            try? await end(at: Date(), discard: detector.state != .active)
            await finishLabeling()
            throw error
        }
        await finishLabeling()
        syncTask.cancel(); await outbox.interrupt(); _ = await syncTask.result
        if !options.noSync { await outbox.flush(within: 5) }
    }
    nonisolated private static func announce(_ handoff: Handoff) {
        FileHandle.standardOutput.write(Data("handoff sid=\(handoff.sid) \(handoff.output)\n".utf8))
    }
    private func publish(at now: Date) async {
        if permissionsCheckedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            permissions = (CapturePermissions.microphone, CapturePermissions.systemAudio(config.system_audio))
            permissionsCheckedAt = now
        }
        var next = RecorderSnapshot()
        let live = capture.flatMap { $0.suspended ? nil : $0 }
        if let capture = live {
            next.phase = await capture.writer.isPersisted() ? .recording : .armed
            next.sid = capture.writer.sid; next.kind = capture.kind; next.startedAt = capture.startedAt
            next.lines = await capture.writer.transcriptLines()
            next.markTimes = await capture.writer.marks()
            next.marks = next.markTimes.count
        } else if pause.isPaused {
            next.phase = .paused
        } else if let capture {
            // Held: shown as ended and waiting to file, which it does unless the call comes back.
            next.phase = .ended; next.sid = capture.writer.sid; next.kind = capture.kind; next.heldUntil = hold?.until
        } else if let lastEnded, now.timeIntervalSince(lastEnded.at) < Self.endedPhase {
            next.phase = .ended; next.sid = lastEnded.sid; next.kind = lastEnded.kind
        }
        next.forgottenSid = lastForgotten
        next.micOK = permissions.mic && live?.micSilent != true && live?.micDown != true
        next.audioOK = (permissions.audio ?? true) && !(live?.kind == .call && live?.systemAudioSilent == true)
        store.update { current in
            let feed = current.feed
            next.feed = feed; next.feedReceivedAt = current.feedReceivedAt
            next.match(feed?.next, at: now)
            current = next
        }
    }
    private func prepareForSleep() async {
        let delivery = Task { @MainActor in
            if self.capture != nil { try? await self.end(at: Date(), discard: self.detector.state != .active) }
            if !self.options.noSync { await self.handleForgotten(self.outbox.flush(within: 10)) }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await delivery.value }
            group.addTask { try? await Task.sleep(for: .seconds(20)) }
            await group.next(); group.cancelAll()
        }
    }
    /// Drops the finished or failed capture. `resetting: false` is begin()'s failure path, which has no detector or manual
    /// state to undo yet. `suppress` is left alone when nil.
    private func clearCapture(resetting: Bool = true, suppress: Suppression? = nil) {
        capture = nil
        if resetting { detector.reset(); manual = false }
        if let suppress { suppression = suppress }
        idleSleep.hold(false)
    }
    private func failCapture(at now: Date) async {
        if let capture {
            await outbox.cancelSession(capture.writer.sid)
            try? await capture.stop(discard: true)
            await capture.deleteAudio()
            try? await capture.writer.fail(at: now)
            await outbox.resume(capture.writer.sid)
            lastEnded = (capture.writer.sid, capture.kind, now)
        }
        clearCapture(suppress: .until(now.addingTimeInterval(Suppression.rearmAfterFailure)))
        FileHandle.standardError.write(Data("session_failed\n".utf8))
    }
    private func begin(at now: Date, forced: Bool, kind: CaptureKind) async throws {
        if let capture {
            if forced { detector.forceActive(); try await capture.writer.activate(at: now) }
            return
        }
        let config = try Config.load(configURL)
        var sid = SessionPaths.id(at: now)
        while FileManager.default.fileExists(atPath: paths.session(sid).path) { sid = SessionPaths.id(at: now) }
        let writer = SessionWriter(sid: sid, startedAt: now, directory: paths.session(sid), test: options.test, kind: kind)
        await writer.setSchedule(schedule)
        let session = CaptureSession(writer: writer, startedAt: now, options: options, monitor: monitor, clients: detector.clients, backend: config.system_audio,
                                     audio: paths.audio.appendingPathComponent(sid + ".caf"))
        capture = session
        idleSleep.hold(true)
        do {
            try await session.start()
            if forced { detector.forceActive(); try await writer.activate(at: now) }
        } catch {
            try? await session.stop(discard: true); await session.deleteAudio(); try? await writer.fail(at: now)
            clearCapture(resetting: false); throw error
        }
    }
    private func end(at now: Date, discard: Bool) async throws {
        guard let capture else { detector.reset(); manual = false; return }
        // A held call already has a transcript worth keeping, and it ended when its signal went away, not now.
        let discard = discard && hold == nil
        let now = capture.suspended ? hold?.endedAt ?? now : now
        defer { self.clearCapture() }
        if discard { await capture.writer.discard() }
        do {
            try await capture.stop(discard: discard)
            let audio = await capture.themAudio()
            if discard { await capture.deleteAudio() }
            else if await capture.writer.shouldDiscardShortSession() { await capture.deleteAudio(); try await outbox.forget(capture.writer.sid, at: now) }
            else if let audio, await capture.writer.isPersisted() {
                label(capture.writer, audio: audio, expected: schedule?.others(keys: await capture.writer.metadata().cal_keys), endedAt: now)
                lastEnded = (capture.writer.sid, capture.kind, now)
            } else {
                await capture.deleteAudio()
                try await capture.writer.close(at: now); lastEnded = (capture.writer.sid, capture.kind, now)
            }
        } catch {
            await capture.deleteAudio()
            try? await capture.writer.fail(at: now)
            throw error
        }
    }
    /// A detected call whose signal stayed gone: stops listening and holds the session for `CallHold.window`, so the
    /// same call coming back continues it. A call that never recorded, or an in-person one, ends as before.
    private func holdCall(at now: Date) async throws {
        guard let capture, capture.kind == .call, await capture.writer.isPersisted() else { try await end(at: now, discard: false); return }
        let meta = await capture.writer.metadata()
        await capture.suspend()
        hold = CallHold(endedAt: now, apps: meta.apps, calKeys: meta.cal_keys)
        detector.reset()
    }
    /// The held call came back: listening restarts into the same session. If capture will not restart, the held
    /// call files, and the next detection starts a new one.
    private func resumeHeld(_ capture: CaptureSession, at now: Date) async throws {
        do { try await capture.resume() }
        catch {
            FileHandle.standardError.write(Data("resume_failed \(error)\n".utf8))
            await capture.suspend()
            try await end(at: now, discard: false)
        }
    }
    /// Labels the call's speakers off the main loop, deletes the audio, then closes the session, so the mini
    /// files it with its speakers. A session whose labeling fails is closed without them.
    private func label(_ writer: SessionWriter, audio: (url: URL, start: Date), expected: Int?, endedAt: Date) {
        let sid = writer.sid
        labeling[sid] = (Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: audio.url) }
            do { try await writer.saveSpeakers(SpeakerLabeler.label(audio.url, start: audio.start, expected: expected)) }
            catch is CancellationError {}
            catch { FileHandle.standardError.write(Data("speakers_failed \(error)\n".utf8)) }
            do { try await writer.close(at: endedAt) } catch { FileHandle.standardError.write(Data("close_failed\n".utf8)) }
            self?.labeling[sid] = nil
        }, writer)
    }
    /// On quit: gives labeling a few seconds, then stops it and closes each session without speakers.
    private func finishLabeling(within seconds: Double = 12) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !labeling.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        let running = labeling.values
        for entry in running { entry.task.cancel() }
        for entry in running { await entry.task.value }
    }
    private func forgetSession(_ sid: String, reply: @escaping () throws -> Void) async throws {
        guard SessionPaths.validID(sid) else { throw CocoaError(.fileReadInvalidFileName) }
        if lastEnded?.sid == sid { lastEnded = nil }
        lastForgotten = sid
        if let entry = labeling.removeValue(forKey: sid) {
            await entry.writer.discard(); entry.task.cancel()
            try? FileManager.default.removeItem(at: paths.audio.appendingPathComponent(sid + ".caf"))
        }
        guard let session = capture, sid == session.writer.sid else {
            try await outbox.forget(sid, at: Date())
            try reply(); return
        }
        // A pause that cannot be written must not leave the forgotten call recording; the hold below covers it.
        do { try pause.set(reason: .forget, at: Date()) }
        catch { FileHandle.standardError.write(Data("forget_pause_failed\n".utf8)) }
        do {
            try await ActiveForget.perform(
                cancelOutbox: { await self.outbox.cancelSession(sid) },
                stopSources: { await session.stopSources() },
                cancelAnalyzers: { try await session.finishAnalyzers(discard: true) },
                closeWriter: { await session.writer.discard(); await session.deleteAudio() },
                deleteSession: { try await self.outbox.deleteSession(sid) },
                writeTombstone: { try await self.outbox.recordForget(sid, at: Date()) },
                reply: {
                    self.clearCapture(suppress: .untilMeetingEnds)
                    try reply()
                })
        } catch {
            if capture === session { clearCapture(suppress: .untilMeetingEnds) }
            throw error
        }
    }
    /// Acts on calls the mini said were forgotten, from a regular tick or a flush before sleep.
    private func handleForgotten(_ report: SyncReport) async {
        for sid in report.forgottenActive { await forgetRemotely(sid) }
        for sid in report.forgottenEnded { await forgotEnded(sid) }
    }
    /// An ended call the mini forgot before its upload finished: the outbox already deleted it, so only the panel's
    /// saved frame and any speaker labeling still running for it are left to drop.
    private func forgotEnded(_ sid: String) async {
        if lastEnded?.sid == sid { lastEnded = nil }
        lastForgotten = sid
        if let entry = labeling.removeValue(forKey: sid) {
            await entry.writer.discard(); entry.task.cancel()
            try? FileManager.default.removeItem(at: paths.audio.appendingPathComponent(sid + ".caf"))
        }
    }
    private func forgetRemotely(_ sid: String) async {
        do { try await forgetSession(sid, reply: {}) }
        catch { FileHandle.standardError.write(Data("remote_forget_failed\n".utf8)) }
    }
    private func controls() async throws {
        while let connection = try await control?.acceptCommand() {
            let command = connection.command
            do {
                switch command.action {
                case .start:
                    guard !pause.isPaused else { try connection.reply("paused"); continue }
                    let kind = command.kind ?? .call
                    // A held call files first; Start always begins a recording that is listening.
                    if capture?.suspended == true { try await end(at: Date(), discard: false) }
                    if let capture, capture.kind != kind { try connection.reply("busy"); continue }
                    suppression = .off; try await begin(at: Date(), forced: true, kind: kind); manual = true
                case .stop:
                    if pause.isPaused { try pause.resume() }
                    try await end(at: Date(), discard: detector.state != .active); suppression = .untilMeetingEnds
                case .pause:
                    try pause.set(reason: .pause, at: Date())
                    try await end(at: Date(), discard: detector.state != .active)
                case .resume:
                    try pause.resume(); suppression = .off
                    if capture == nil { detector.reset() }
                case .mark:
                    guard let capture, !capture.suspended, await capture.writer.isPersisted() else { try connection.reply("not_recording"); continue }
                    _ = try await capture.writer.mark(note: command.note, at: Date())
                case .ping:
                    try connection.reply(ControlCommand.pingReply(pid: getpid()))
                    continue
                case .forget:
                    guard let sid = command.sid else { throw CocoaError(.fileReadInvalidFileName) }
                    try await forgetSession(sid) { try connection.reply("forgotten") }
                    continue
                }
                try connection.reply(command.action.rawValue)
            } catch {
                if [.start, .stop, .pause].contains(command.action) { await failCapture(at: Date()) }
                if [.stop, .pause].contains(command.action) { suppression = .untilMeetingEnds }
                try? connection.reply("failed")
                FileHandle.standardError.write(Data("control_failed\n".utf8))
            }
        }
    }
}
