import Foundation
import Synchronization
import LMLCore

/// An `UpdateActions` for the panel's tests and snapshots: the release, the refusal and the job's outcome are set by
/// hand, and every start records whether a call was on.
public final class FakeUpdates: UpdateActions {
    private struct State {
        var newer: ReleaseVersion?
        var refusal: UpdateRefusal?
        var startFails = false
        var progress: [UpdateProgress] = []
        var starts: [(ReleaseVersion, Bool)] = []
        var checks = 0
    }

    private let state: Mutex<State>
    public let logPath = "~/Library/Application Support/LiveMeetingListener/update/update.log"

    public init(newer: ReleaseVersion? = ReleaseVersion(2, 14, 0)) { state = Mutex(State(newer: newer)) }

    public func set(newer: ReleaseVersion?) { state.withLock { $0.newer = newer } }
    public func refuse(_ refusal: UpdateRefusal?) { state.withLock { $0.refusal = refusal } }
    public func failStart() { state.withLock { $0.startFails = true } }
    /// What each progress poll returns, in order; the last one repeats.
    public func progress(_ steps: UpdateProgress...) { state.withLock { $0.progress = steps } }
    public var starts: [(version: ReleaseVersion, inCall: Bool)] { state.withLock { $0.starts.map { (version: $0.0, inCall: $0.1) } } }
    public var checks: Int { state.withLock { $0.checks } }

    public func newerRelease(now: Date) async -> ReleaseVersion? {
        state.withLock { $0.checks += 1; return $0.newer }
    }

    public func startUpdate(to version: ReleaseVersion, inCall: Bool) async throws {
        let (refusal, fails) = state.withLock { state -> (UpdateRefusal?, Bool) in
            state.starts.append((version, inCall))
            return (inCall ? .inCall : state.refusal, state.startFails)
        }
        if let refusal { throw refusal }
        if fails { throw FakeFailure() }
    }

    public func updateProgress() async -> UpdateProgress {
        state.withLock { state in
            guard let first = state.progress.first else { return .running }
            if state.progress.count > 1 { state.progress.removeFirst() }
            return first
        }
    }
}
