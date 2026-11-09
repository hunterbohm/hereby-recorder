import Foundation

/// Folds a burst of change events into one refresh and spaces refreshes at least `interval` apart, so a storm of
/// CoreAudio notifications costs a bounded number of reads however many arrive.
public struct RefreshGate: Sendable {
    public let interval: Double
    private var scheduled = false
    private var restart = false
    private var lastRead: Double?
    public init(interval: Double) { self.interval = interval }
    /// Records an event. Returns how long to wait before refreshing, or nil when a refresh is already scheduled.
    public mutating func request(restart: Bool, now: Double) -> Double? {
        self.restart = self.restart || restart
        guard !scheduled else { return nil }
        scheduled = true
        return lastRead.map { max(0, interval - (now - $0)) } ?? 0
    }
    /// Starts the scheduled refresh. True when any event folded into it asked for a restart.
    public mutating func begin() -> Bool {
        scheduled = false
        defer { restart = false }
        return restart
    }
    /// Notes that a read of the audio state finished, whether a refresh or the loop's own.
    public mutating func finishedRead(at now: Double) { lastRead = now }
}
