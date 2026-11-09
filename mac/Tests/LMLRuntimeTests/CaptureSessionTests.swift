import CoreAudio
import Foundation
import LMLCore
import Testing
@testable import lml

@MainActor private final class ReconfiguringMic: MicrophoneSource {
    var isOpen = false
    var attempts = 0
    var stops = 0
    var failures: Int
    private var count = 0
    var delivered: Int { if isOpen { count += 1 }; return count }
    init(failures: Int = 1) { self.failures = failures }
    func start(on device: AudioDeviceID, restart: Bool) throws {
        attempts += 1; isOpen = true
        if failures > 0 {
            failures -= 1
            throw NSError(domain: "lml.test.configuration-pending", code: 254)
        }
    }
    func stop() { stops += 1; isOpen = false }
    func dispose() { stop() }
}

@MainActor private final class DeviceMic: MicrophoneSource {
    var isOpen = false
    var device: AudioDeviceID?
    var broken: Set<AudioDeviceID>
    var stalled: Set<AudioDeviceID> = []
    var attempts: [AudioDeviceID] = []
    private var count = 0
    var delivered: Int { if isOpen, let device, !stalled.contains(device) { count += 1 }; return count }
    init(broken: Set<AudioDeviceID>) { self.broken = broken }
    func start(on device: AudioDeviceID, restart: Bool) throws {
        if self.device == device && isOpen && !restart { return }
        attempts.append(device)
        if broken.contains(device) { isOpen = false; self.device = nil; throw NSError(domain: "lml.mic.format_pending", code: 2) }
        isOpen = true; self.device = device
    }
    func stop() { isOpen = false; device = nil }
    func dispose() { stop() }
}

private struct QuietTranscriber: Transcriber {
    func run(_ chunks: AsyncStream<CaptureEvent>) async throws { for await _ in chunks {} }
}
private struct BrokenTranscriber: Transcriber {
    func run(_ chunks: AsyncStream<CaptureEvent>) async throws { throw NSError(domain: "lml.test.asr", code: 1) }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func state(_ seconds: TimeInterval) -> AudioState {
    AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(seconds)), defaultInput: 7)
}

private func state(_ seconds: TimeInterval, builtIn: AudioDeviceID) -> AudioState {
    AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(seconds)), defaultInput: 7, builtInInput: builtIn)
}

@MainActor struct CaptureSessionTests {
    private func session(mic: any MicrophoneSource, transcriber: any Transcriber, kind: CaptureKind = .inPerson) -> CaptureSession {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: .distantPast, directory: nil, test: true, kind: kind)
        return CaptureSession(writer: writer, startedAt: .distantPast, options: RunOptions(), monitor: ProcessMonitor(),
                              clients: MeetingClients(), backend: .tap, audio: nil, microphone: mic, transcriber: transcriber)
    }
    @Test func micReconfigurationFailureBacksOffThenRestartsInTheSameSession() async throws {
        let mic = ReconfiguringMic(failures: 2)
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        try await capture.tick(state(0), schedule: nil)
        #expect(mic.attempts == 1); #expect(mic.stops == 2); #expect(!mic.isOpen)
        #expect(!capture.failure)
        #expect(await capture.writer.metadata().state == .active)
        capture.refreshMic(state(0.5), restart: true)
        try await capture.tick(state(0.9), schedule: nil)
        #expect(mic.attempts == 1)
        try await capture.tick(state(1), schedule: nil)
        #expect(mic.attempts == 2); #expect(!mic.isOpen)
        try await capture.tick(state(2.9), schedule: nil)
        #expect(mic.attempts == 2)
        try await capture.tick(state(3), schedule: nil)
        #expect(mic.attempts == 3); #expect(mic.isOpen)
        #expect(capture.micRetry == MicRetry())
        #expect(!capture.failure)
        #expect(capture.writer.sid == "20261013-190012-a3f1")
        #expect(await capture.writer.metadata().state == .active)
        try await capture.stop()
    }
    @Test func micThatNeverRestartsKeepsTheCallAndRetriesEveryFifteenSeconds() async throws {
        let mic = ReconfiguringMic(failures: .max)
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        var now: TimeInterval = 0
        for delay in MicRetry.delays {
            try await capture.tick(state(now), schedule: nil)
            now += delay
        }
        let afterBackoff = mic.attempts
        for _ in 0..<240 {
            try await capture.tick(state(now), schedule: nil)
            now += 15
        }
        #expect(!capture.failure)
        #expect(mic.attempts == afterBackoff + 240)
        #expect(await capture.writer.metadata().state == .active)
        mic.failures = 0
        try await capture.tick(state(now), schedule: nil)
        #expect(mic.isOpen)
        await capture.stopSources()
    }
    @Test func aMicThatWillNotStartFallsBackToTheBuiltInMicWithinSeconds() async throws {
        let mic = DeviceMic(broken: [7])
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        try await capture.tick(state(0, builtIn: 9), schedule: nil)
        try await capture.tick(state(1, builtIn: 9), schedule: nil)
        #expect(mic.attempts == [7, 7, 9])
        #expect(mic.isOpen && mic.device == 9)
        for second in stride(from: 2.0, through: 3600, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(mic.attempts == [7, 7, 9])
        #expect(mic.device == 9)
        #expect(!capture.failure)
        await capture.stopSources()
    }
    @Test func aNewlyChosenMicGetsItsOwnTwoAttemptsBeforeTheFallback() async throws {
        let mic = DeviceMic(broken: [7, 8])
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        try await capture.tick(state(0, builtIn: 9), schedule: nil)
        let other = AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(0.5)), defaultInput: 8, builtInInput: 9)
        try await capture.tick(other, schedule: nil)
        #expect(mic.attempts == [7, 8])
        #expect(!mic.isOpen)
        let later = AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(1.5)), defaultInput: 8, builtInInput: 9)
        try await capture.tick(later, schedule: nil)
        #expect(mic.attempts == [7, 8, 8, 9])
        #expect(mic.device == 9)
        await capture.stopSources()
    }
    @Test func aBrokenBuiltInMicKeepsRetryingWithoutEndingTheCall() async throws {
        let mic = DeviceMic(broken: [7, 9])
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        for second in stride(from: 0.0, through: 600, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(!capture.failure)
        #expect(mic.attempts.count > 30)
        mic.broken = []
        for second in stride(from: 601.0, through: 620, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(mic.isOpen)
        await capture.stopSources()
    }
    @Test func aMicThatGoesQuietRestartsThenFallsBackToTheBuiltInMic() async throws {
        let mic = DeviceMic(broken: [])
        mic.stalled = [7]
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        for second in stride(from: 0.0, through: 4, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(mic.attempts == [7])
        try await capture.tick(state(5, builtIn: 9), schedule: nil)
        #expect(mic.attempts == [7, 7])
        for second in stride(from: 6.0, through: 10, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(mic.attempts == [7, 7])
        try await capture.tick(state(11, builtIn: 9), schedule: nil)
        #expect(mic.attempts == [7, 7, 9])
        for second in stride(from: 12.0, through: 120, by: 1) { try await capture.tick(state(second, builtIn: 9), schedule: nil) }
        #expect(mic.attempts == [7, 7, 9]); #expect(mic.device == 9)
        #expect(!capture.micDown); #expect(!capture.failure)
        await capture.stopSources()
    }
    @Test func aMicThatStaysDownIsReportedAfterThirtySecondsAndClearsWhenAudioArrives() async throws {
        let mic = ReconfiguringMic(failures: .max)
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        try await capture.tick(state(0), schedule: nil)
        try await capture.tick(state(29), schedule: nil)
        #expect(!capture.micDown)
        try await capture.tick(state(30), schedule: nil)
        #expect(capture.micDown)
        mic.failures = 0
        try await capture.tick(state(45), schedule: nil)
        try await capture.tick(state(46), schedule: nil)
        #expect(mic.isOpen); #expect(!capture.micDown)
        await capture.stopSources()
    }
    @Test func aCallWhoseMeetingAppHoldsNoMicIsNotReportedDown() async throws {
        let mic = DeviceMic(broken: [7])
        let capture = session(mic: mic, transcriber: QuietTranscriber(), kind: .call)
        try await capture.tick(state(0), schedule: nil)
        for second in stride(from: 1.0, through: 60, by: 1) {
            try await capture.tick(AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(second)), defaultInput: 0), schedule: nil)
        }
        #expect(!capture.micDown)
        await capture.stopSources()
    }
    @Test func anInPersonRecordingWithNoInputDeviceIsReportedDown() async throws {
        let mic = DeviceMic(broken: [])
        let capture = session(mic: mic, transcriber: QuietTranscriber())
        for second in stride(from: 0.0, through: 30, by: 1) {
            try await capture.tick(AudioState(snapshot: ProcessSnapshot(procs: [], ts: epoch.addingTimeInterval(second)), defaultInput: 0), schedule: nil)
        }
        #expect(capture.micDown)
        await capture.stopSources()
    }
    @Test func genuineTranscriberFailureStillFailsCapture() async throws {
        let mic = ReconfiguringMic(failures: 0)
        let capture = session(mic: mic, transcriber: BrokenTranscriber())
        await capture.stopSources()
        await #expect(throws: (any Error).self) { try await capture.finishAnalyzers(discard: false) }
        #expect(capture.failure)
    }
}

struct SuppressionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func aFailedCaptureReArmsDuringTheSameMeeting() {
        let held = Suppression.until(now.addingTimeInterval(Suppression.rearmAfterFailure))
        #expect(!held.lifts(at: now.addingTimeInterval(29), meetingSignal: true))
        #expect(held.lifts(at: now.addingTimeInterval(30), meetingSignal: true))
    }
    @Test func aMeetingCountsAsOverOnlyAfterItsSignalIsGoneTwoMinutes() {
        var presence = MeetingPresence()
        let seen = [(true, 0.0), (false, 1), (false, 120), (true, 121), (false, 122), (false, 242)].map { signal, at in
            presence.isOn(signal: signal, at: now.addingTimeInterval(at))
        }
        #expect(seen == [true, true, true, true, true, false])
    }
    @Test func aStopHoldsUntilTheMeetingEnds() {
        #expect(!Suppression.untilMeetingEnds.lifts(at: now.addingTimeInterval(86_400), meetingSignal: true))
        #expect(Suppression.untilMeetingEnds.lifts(at: now, meetingSignal: false))
    }
}
