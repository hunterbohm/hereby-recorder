import CoreAudio
import Foundation

public struct MicDeviceSelector: Sendable {
    public let ownPID: Int32
    public let clients: MeetingClients
    public init(ownPID: Int32, clients: MeetingClients) { self.ownPID = ownPID; self.clients = clients }
    public func eligible(_ snapshot: ProcessSnapshot, defaultInput: AudioDeviceID) -> AudioDeviceID? {
        let external = snapshot.procs.filter { $0.pid != ownPID && $0.input }
        let meeting = external.filter { clients.allowed($0.bundle) }
            .flatMap { $0.inputDevices ?? [] }.filter { $0 != kAudioObjectUnknown }
        let micOnly = external.filter { clients.micOnly($0.bundle) }
            .flatMap { $0.inputDevices ?? [] }.filter { $0 != kAudioObjectUnknown }
        let candidates = meeting.isEmpty ? micOnly : meeting
        if candidates.contains(defaultInput) { return defaultInput }
        return candidates.min()
    }
}

public struct MicCaptureState: Sendable {
    public private(set) var device: AudioDeviceID?
    public private(set) var runID: UUID?
    public init() {}
    @discardableResult public mutating func update(device: AudioDeviceID?, restart: Bool = false) -> Bool {
        guard self.device != device || (restart && device != nil) else { return false }
        self.device = device
        runID = device.map { _ in UUID() }
        return true
    }
}

/// The `mic_order` setting: microphone name fragments, most wanted first, matched without case.
public enum MicOrder {
    /// The index of the first name the earliest matching fragment picks.
    public static func pick(_ names: [String], order: [String]) -> Int? {
        for fragment in order {
            if let index = names.firstIndex(where: { $0.localizedCaseInsensitiveContains(fragment) }) { return index }
        }
        return nil
    }
}

/// Limits how often lml-mic takes the default input back. With AirPods in the ears, macOS can take it again right after
/// each switch back, and the two would trade it back and forth. After `limit` switches back within `window` seconds,
/// lml-mic leaves the default alone for `pause` seconds.
public struct MicSwitchGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case switchBack
        /// The pause began at this call.
        case pauseStarted
        case paused
    }

    public let limit: Int
    public let window: Double
    public let pause: Double
    private var recent: [Double] = []
    private var pausedUntil = -Double.infinity

    public init(limit: Int = 3, window: Double = 10, pause: Double = 60) {
        self.limit = limit
        self.window = window
        self.pause = pause
    }

    /// Whether to switch back at `now`, in seconds on a steady clock. Every `.switchBack` counts toward the limit.
    public mutating func verdict(at now: Double) -> Verdict {
        if now < pausedUntil { return .paused }
        recent.removeAll { $0 <= now - window }
        guard recent.count < limit else {
            recent.removeAll()
            pausedUntil = now + pause
            return .pauseStarted
        }
        recent.append(now)
        return .switchBack
    }
}
