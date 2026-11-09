import Foundation

/// Paces microphone restarts after a failed start. A device switch can leave Core Audio mid-reconfiguration for a
/// few seconds, so each failure waits longer, then keeps retrying at the last delay. A mic that never comes back
/// must not end the call: the other side is still being captured.
public struct MicRetry: Sendable, Equatable {
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 15]
    public private(set) var failures = 0
    public private(set) var retryAt: Date?
    public init() {}
    public func allows(at now: Date) -> Bool { retryAt.map { now >= $0 } ?? true }
    /// Records a failed start and returns when the next attempt may run.
    public mutating func failed(at now: Date) -> Date {
        failures += 1
        let at = now.addingTimeInterval(Self.delays[min(failures, Self.delays.count) - 1])
        retryAt = at
        return at
    }
    public mutating func succeeded() { failures = 0; retryAt = nil }
}
