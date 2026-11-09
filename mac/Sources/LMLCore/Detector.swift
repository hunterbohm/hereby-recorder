import Foundation

/// The apps whose calls are recorded, by bundle id prefix, from the `meeting_apps` setting, and the apps that count
/// only while they hold the microphone, from `mic_apps`.
public struct MeetingClients: Sendable {
    public let prefixes: [String]
    public let micPrefixes: [String]
    public init(prefixes: [String] = Settings.defaultMeetingApps, micPrefixes: [String] = Settings.defaultMicApps) {
        self.prefixes = prefixes; self.micPrefixes = micPrefixes
    }
    public func allowed(_ bundle: String) -> Bool { prefixes.contains { bundle.hasPrefix($0) } }
    public func micOnly(_ bundle: String) -> Bool { micPrefixes.contains { bundle.hasPrefix($0) } }
    /// The meeting apps in `snapshot` that are using audio, other than `ownPID`: the apps a session records as its own.
    public func callApps(_ snapshot: ProcessSnapshot, ownPID: Int32) -> [String] {
        snapshot.procs.filter { $0.pid != ownPID && ($0.input || $0.output) && (allowed($0.bundle) || micOnly($0.bundle)) }.map(\.bundle)
    }
}

/// A call whose meeting signal went away. Capture stops, and the session waits `window` before it files, so a call
/// that drops and comes back keeps one transcript instead of being filed in two halves.
public struct CallHold: Equatable, Sendable {
    public static let window: TimeInterval = 300
    /// When the call counted as ended, the time the session files with if it does not come back.
    public let endedAt: Date
    public let apps: Set<String>
    public let calKeys: Set<String>
    public init(endedAt: Date, apps: [String], calKeys: [String]) {
        self.endedAt = endedAt; self.apps = Set(apps); self.calKeys = Set(calKeys)
    }
    /// When the held call files if it does not come back.
    public var until: Date { endedAt.addingTimeInterval(Self.window) }
    public func expired(at now: Date) -> Bool { now >= until }
    /// The returning call is the held one: a meeting app the held call used, and no calendar meeting it did not
    /// have. A meeting that starts on the calendar in the meantime is a new call, even in the same app.
    public func continues(apps: [String], calKeys: [String]) -> Bool {
        !self.apps.isDisjoint(with: apps) && Set(calKeys).isSubset(of: self.calKeys)
    }
}

public struct Detector: Sendable {
    public enum State: Equatable, Sendable { case idle, arming(Date), active, closing }
    public enum Transition: Equatable, Sendable { case arm, activate, discard, close }
    public private(set) var state: State = .idle
    private var lostAt: Date?
    public let ownPID: Int32
    public let clients: MeetingClients
    public init(ownPID: Int32, clients: MeetingClients) { self.ownPID = ownPID; self.clients = clients }
    public func signal(_ snapshot: ProcessSnapshot, schedule: Schedule?) -> Bool {
        let external = snapshot.procs.filter { $0.pid != ownPID }
        if external.contains(where: { $0.input && (clients.allowed($0.bundle) || clients.micOnly($0.bundle)) }) { return true }
        return !(schedule?.current(at: snapshot.ts).isEmpty ?? true) && external.contains { $0.output && clients.allowed($0.bundle) }
    }
    public mutating func update(_ snapshot: ProcessSnapshot, schedule: Schedule?) -> Transition? {
        let on = signal(snapshot, schedule: schedule)
        switch state {
        case .idle:
            guard on else { return nil }
            state = .arming(snapshot.ts); return .arm
        case .arming(let since):
            guard on else { state = .idle; return .discard }
            if snapshot.ts.timeIntervalSince(since) >= 10 { state = .active; lostAt = nil; return .activate }
        case .active:
            if on { lostAt = nil }
            else {
                if lostAt == nil { lostAt = snapshot.ts }
                if snapshot.ts.timeIntervalSince(lostAt!) >= 120 { state = .closing; return .close }
            }
        case .closing: break
        }
        return nil
    }
    public mutating func forceActive() { state = .active; lostAt = nil }
    public mutating func reset() { state = .idle; lostAt = nil }
}

public struct SilenceGuard: Sendable {
    private var zeroSince: Date?
    // A blocked tap delivers only zeros, and so does a call nobody speaks in (a waiting room). One
    // non-zero sample proves access for the rest of the capture.
    private var heard = false
    public private(set) var warning = false
    public init() {}
    public mutating func update(peak: Float, sampleCount: Int, outputRunning: Bool, at now: Date) {
        if peak > 0 { heard = true }
        guard !heard && outputRunning && sampleCount > 0 && peak == 0 else { zeroSince = nil; warning = false; return }
        if zeroSince == nil { zeroSince = now }
        warning = now.timeIntervalSince(zeroSince!) >= 60
    }
}
