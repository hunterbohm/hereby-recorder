import Foundation
import Synchronization

/// The recorder loop's current step and when it entered it, readable from a thread outside the main actor.
/// Time is uptime, which stops while the Mac sleeps, so a sleep never reads as a stall.
public final class LoopWatch: Sendable {
    public struct Stall: Equatable, Sendable {
        public var step: String
        public var seconds: Double
    }
    public let limit: Double
    private let entered: Mutex<(step: String, at: UInt64)>
    public init(limit: Double, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.limit = limit; entered = Mutex(("start", now))
    }
    public func enter(_ step: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        entered.withLock { $0 = (step, now) }
    }
    public func stall(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Stall? {
        let (step, at) = entered.withLock { $0 }
        let seconds = Double(now &- at) / 1e9
        return now > at && seconds >= limit ? Stall(step: step, seconds: seconds) : nil
    }
}
